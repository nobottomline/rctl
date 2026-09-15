import UIKit

// Shared infrastructure for the modal overlays: `RCSheet` (RCSheet*.swift),
// `RCDialog` and its progress card (RCDialog*.swift) and `RCToast`
// (RCToast*.swift).
//
// Presentation model. Sheets and dialogs are real UIKit presentations
// (`modalPresentationStyle = .custom` with our own presentation controllers),
// so first responder handling, trait propagation, rotation and
// `dismiss(animated:)` from content keep working. The *presentation*
// transition completes immediately and the entrance motion runs as an
// ordinary interruptible animation afterwards: the user can grab a sheet
// mid-spring, and code may present or dismiss again right away without
// hitting UIKit's "presentation in progress" failures. Dismissal is a real
// transition that completes when the exit animation ends.

extension UIApplication {
    /// Key window of the foreground-active scene (iOS 13 compatible).
    var activeKeyWindow: UIWindow? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = scenes.filter { $0.activationState == .foregroundActive }
            + scenes.filter { $0.activationState != .foregroundActive }
        for scene in ordered {
            if let key = scene.windows.first(where: \.isKeyWindow) { return key }
        }
        return nil
    }
}

// MARK: - Overlay activity

/// Holds one `RCOverlayActivity` token while an overlay's root view is in a
/// window. Driving it from `didMoveToWindow` covers every way an overlay
/// leaves the screen — dismissal, cancelled presentation, teardown together
/// with its presenter — with exactly one `end()`.
@MainActor
final class RCOverlayVisibility {
    private var token: RCOverlayToken?

    var isVisible: Bool { token != nil }

    func update(inWindow: Bool) {
        if inWindow {
            if token == nil { token = RCOverlayActivity.begin() }
        } else {
            token?.end()
            token = nil
        }
    }
}

// MARK: - Clock

/// Time source for modal timing rules (progress minimum display time).
/// Injected in tests; production uses `RCSystemModalClock`.
@MainActor
protocol RCModalClock: AnyObject {
    /// Monotonic seconds.
    var now: TimeInterval { get }
    /// Runs `work` on the main actor after `delay` seconds (next turn when `delay <= 0`).
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void)
}

@MainActor
final class RCSystemModalClock: RCModalClock {
    static let shared = RCSystemModalClock()

    var now: TimeInterval { CACurrentMediaTime() }

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) {
            MainActor.assumeIsolated { work() }
        }
    }
}

// MARK: - Presentation helpers

@MainActor
enum RCModalSupport {
    /// Test hook: `false` presents and dismisses sheets and dialogs without
    /// animation so lifecycle tests are deterministic.
    static var animationsEnabled = true

    /// Appearance a modal must adopt so it matches its presenter.
    ///
    /// UIKit presents `.custom` controllers from the presentation context
    /// (usually the navigation controller), whose traits do not include an
    /// override set on the screen that asked for the modal (e.g. the always-dark
    /// remote session). Returns the first explicit override found on the
    /// presenter, a navigation controller's visible child, the presenter's
    /// ancestors, or the controllers presenting them; `.unspecified` when the
    /// modal can simply follow the window.
    static func inheritedInterfaceStyle(from presenter: UIViewController?) -> UIUserInterfaceStyle {
        var visited = 0
        var node = presenter
        while let current = node, visited < 64 {
            visited += 1
            if let navigation = current as? UINavigationController,
               let top = navigation.topViewController,
               top.overrideUserInterfaceStyle != .unspecified {
                return top.overrideUserInterfaceStyle
            }
            if current.overrideUserInterfaceStyle != .unspecified {
                return current.overrideUserInterfaceStyle
            }
            node = current.parent ?? current.presentingViewController
        }
        return .unspecified
    }

    /// Controller to present from: the top of the presentation chain of
    /// `presenter` (or of the window's root when `presenter` left the window).
    /// Stops below a controller that is being dismissed.
    static func presentationBase(for presenter: UIViewController?, window: UIWindow?) -> UIViewController? {
        let base: UIViewController?
        if let presenter, presenter.viewIfLoaded?.window != nil {
            base = presenter
        } else {
            base = (window?.windowScene != nil ? window : nil)?.rootViewController
                ?? UIApplication.shared.activeKeyWindow?.rootViewController
        }
        guard var current = base else { return nil }
        while let presented = current.presentedViewController, !presented.isBeingDismissed {
            current = presented
        }
        return current
    }

    /// Presents `controller` on top of the presenter's chain. When another
    /// presentation or dismissal is still in flight, retries on the next
    /// frames until UIKit can accept it, so a request is never dropped.
    /// `completion(false)` means there is no window to present in or the
    /// request was cancelled while waiting.
    static func present(
        _ controller: UIViewController,
        from presenter: UIViewController?,
        window: UIWindow?,
        animated: Bool,
        waitsForDialogs: Bool = false,
        isCancelled: @escaping @MainActor () -> Bool = { false },
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        attemptPresent(controller, presenter: presenter, window: window, animated: animated, waitsForDialogs: waitsForDialogs, isCancelled: isCancelled, attempt: 0, completion: completion)
    }

    private static func attemptPresent(
        _ controller: UIViewController,
        presenter: UIViewController?,
        window: UIWindow?,
        animated: Bool,
        waitsForDialogs: Bool,
        isCancelled: @escaping @MainActor () -> Bool,
        attempt: Int,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard !isCancelled() else { completion(false); return }
        guard let base = presentationBase(for: presenter, window: window) else {
            completion(false)
            return
        }
        let busy = base.presentedViewController != nil
            || base.transitionCoordinator != nil
            || base.isBeingPresented
            || base.isBeingDismissed
            // A sheet must never cover a dialog or progress card: its actions
            // would then close the sheet instead of the card.
            || (waitsForDialogs && !RCModalQueue.shared.isIdle)
        // Give in-flight transitions time to finish (≈ 3 s), then keep polling
        // slowly: a dialog carrying an error must still appear eventually.
        if busy {
            let delay: TimeInterval = attempt < 60 ? 0.05 : 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    attemptPresent(controller, presenter: presenter, window: window, animated: animated, waitsForDialogs: waitsForDialogs, isCancelled: isCancelled, attempt: attempt + 1, completion: completion)
                }
            }
            return
        }
        base.present(controller, animated: animated) {
            MainActor.assumeIsolated { completion(true) }
        }
    }

    /// First responder inside `view`, if any (searches the subtree).
    static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let responder = firstResponder(in: subview) { return responder }
        }
        return nil
    }

    /// Sets `path` as the layer's shadow path; if the layer's bounds are being
    /// animated right now (inside a UIView/property-animator block), animates
    /// the path with the same timing so the shadow tracks the shape.
    static func setShadowPath(_ path: CGPath, on layer: CALayer) {
        let old = layer.shadowPath
        withoutImplicitAnimations { layer.shadowPath = path }
        guard let old, old != path else { return }
        let running = layer.animation(forKey: "bounds.size") ?? layer.animation(forKey: "bounds")
        guard let running else { return }
        let animation: CABasicAnimation
        if let spring = running as? CASpringAnimation {
            let copy = CASpringAnimation(keyPath: "shadowPath")
            copy.mass = spring.mass
            copy.stiffness = spring.stiffness
            copy.damping = spring.damping
            copy.initialVelocity = spring.initialVelocity
            animation = copy
        } else {
            animation = CABasicAnimation(keyPath: "shadowPath")
            animation.timingFunction = (running as? CABasicAnimation)?.timingFunction
        }
        animation.fromValue = old
        animation.toValue = path
        animation.duration = running.duration
        animation.beginTime = running.beginTime
        animation.fillMode = .backwards
        layer.add(animation, forKey: "rc.shadowPath")
    }

    /// iOS scroll-view style resistance past a limit: grows ever slower and
    /// never exceeds `dimension`.
    nonisolated static func rubberBand(_ offset: CGFloat, dimension: CGFloat, coefficient: CGFloat = 0.55) -> CGFloat {
        guard offset > 0, dimension > 0 else { return 0 }
        return (1 - 1 / (offset * coefficient / dimension + 1)) * dimension
    }

    /// Distance a flick at `velocity` (pt/s) would travel with normal scroll
    /// deceleration (UIKit's projection formula).
    nonisolated static func projectedDistance(velocity: CGFloat) -> CGFloat {
        let rate = UIScrollView.DecelerationRate.normal.rawValue
        return velocity / 1000 * rate / (1 - rate)
    }
}

// MARK: - Keyboard

/// Observes keyboard frame changes (iOS 13 notifications) and reports the
/// animation parameters to use for lifting content.
@MainActor
final class RCKeyboardObserver {
    struct Change {
        /// End frame in screen coordinates; `.zero` when the keyboard hides.
        let frameInScreen: CGRect
        let duration: TimeInterval
        let curve: UIView.AnimationOptions
    }

    var onChange: ((Change) -> Void)?
    /// Last reported end frame (screen coordinates).
    private(set) var frameInScreen: CGRect = .zero
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let names = [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification]
        tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let hides = note.name == UIResponder.keyboardWillHideNotification
                let frame = hides ? .zero : ((note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero)
                let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
                let rawCurve = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.frameInScreen = frame
                    self.onChange?(Change(frameInScreen: frame, duration: duration, curve: UIView.AnimationOptions(rawValue: rawCurve << 16)))
                }
            }
        }
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    /// Height of `view` covered by a docked keyboard (0 for hidden, floating
    /// or undocked keyboards).
    static func overlap(of frameInScreen: CGRect, in view: UIView) -> CGFloat {
        guard !frameInScreen.isEmpty, let window = view.window else { return 0 }
        let local = view.convert(frameInScreen, from: window.screen.coordinateSpace)
        guard local.maxY >= view.bounds.maxY - 1, local.minX <= view.bounds.minX + 1, local.maxX >= view.bounds.maxX - 1 else { return 0 }
        return max(0, min(view.bounds.height, view.bounds.maxY - local.minY))
    }
}
