import UIKit

/// Detents for `RCSheet` (iOS 13 has no `UISheetPresentationController`).
enum RCSheetDetent: Equatable, Sendable {
    /// Height of the content's `preferredContentSize` (capped at `large`).
    case fitting
    /// About half the container height.
    case medium
    /// Full height below the top safe area with a small gap.
    case large
    /// Fixed content height in points.
    case height(CGFloat)
}

/// Implemented by sheet content that scrolls, so the sheet can hand the pan
/// gesture over to the scroll view at the top edge.
@MainActor
protocol RCSheetScrollable: AnyObject {
    var sheetScrollView: UIScrollView? { get }
}

/// Custom bottom sheet: dimmed backdrop, grabber, continuous top corners,
/// spring presentation, interactive drag between detents and to dismiss,
/// keyboard avoidance. Content controllers size themselves via
/// `preferredContentSize` (call `RCSheet.contentSizeDidChange(for:)` after changes).
///
/// Content contract:
/// - The grabber floats over the top 20 pt of the content; start content at
///   `RCSpace.xl` or lower. The sheet's surface is `RCColor.surface`; content
///   may draw its own background on its root view, which takes the sheet's
///   corners. The sheet does not mask its content (no offscreen passes while
///   it moves), so nested full-width backgrounds must stay clear of the
///   rounded corners.
/// - `.fitting` and `.height(_:)` describe the content height; the sheet adds
///   the bottom safe area when it rests on the bottom edge. Lay out bottom
///   content against `view.safeAreaInsets.bottom`.
/// - On regular-width iPads the sheet becomes a centered card (≤ 540 × 80 %).
/// - `onDismiss` runs exactly once per presentation, after the sheet is gone,
///   whatever dismissed it (drag, backdrop tap, VoiceOver escape,
///   `RCSheet.dismiss`, or the content calling `dismiss(animated:)`).
@MainActor
enum RCSheet {
    static func present(
        _ content: UIViewController,
        from presenter: UIViewController,
        detents: [RCSheetDetent] = [.fitting],
        isDismissible: Bool = true,
        onDismiss: (@MainActor () -> Void)? = nil
    ) {
        if let existing = RCSheetSession.session(for: content), existing.state == .dismissing {
            // Re-presenting while the previous sheet is still leaving: wait for it to finish.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated {
                    present(content, from: presenter, detents: detents, isDismissible: isDismissible, onDismiss: onDismiss)
                }
            }
            return
        }
        guard content.presentingViewController == nil, content.parent == nil, RCSheetSession.session(for: content) == nil else {
            assertionFailure("RCSheet: the content controller is already presented")
            return
        }
        let session = RCSheetSession(
            content: content,
            detents: detents.isEmpty ? [.fitting] : detents,
            isDismissible: isDismissible,
            interfaceStyle: RCModalSupport.inheritedInterfaceStyle(from: presenter),
            onDismiss: onDismiss
        )
        session.start(from: presenter)
    }

    /// Re-measures `.fitting` detents after the content changed size.
    /// (Assigning a new `preferredContentSize` while presented also triggers this.)
    static func contentSizeDidChange(for content: UIViewController, animated: Bool = true) {
        RCSheetSession.session(for: content)?.presentationController?.contentSizeDidChange(animated: animated)
    }

    /// Dismisses the sheet hosting `content`.
    static func dismiss(_ content: UIViewController, animated: Bool = true, completion: (@MainActor () -> Void)? = nil) {
        guard let session = RCSheetSession.hosting(content) else {
            // Not an RCSheet: fall back to a plain dismissal of its presentation.
            if content.presentingViewController != nil {
                content.dismiss(animated: animated) { MainActor.assumeIsolated { completion?() } }
            } else {
                completion?()
            }
            return
        }
        session.dismiss(animated: animated, completion: completion)
    }
}

/// One sheet presentation: owns the configuration, the transitioning delegate
/// role and the exactly-once dismissal bookkeeping. Retained by the content
/// controller for the lifetime of the presentation.
@MainActor
final class RCSheetSession: NSObject, UIViewControllerTransitioningDelegate {
    enum State: Equatable { case idle, waiting, presented, dismissing, finished }

    private nonisolated(unsafe) static var key: UInt8 = 0

    let detents: [RCSheetDetent]
    let isDismissible: Bool
    let interfaceStyle: UIUserInterfaceStyle
    private(set) var state: State = .idle
    private(set) weak var content: UIViewController?
    private(set) weak var presentationController: RCSheetPresentationController?
    private var onDismiss: (@MainActor () -> Void)?
    private var completions: [@MainActor () -> Void] = []
    /// Downward velocity handed from a released drag to the dismissal animation.
    var dismissalVelocity: CGFloat = 0

    private let originalStyle: UIModalPresentationStyle
    private weak var originalDelegate: UIViewControllerTransitioningDelegate?
    private let originalOverride: UIUserInterfaceStyle
    private var appliedOverride = false

    init(content: UIViewController, detents: [RCSheetDetent], isDismissible: Bool, interfaceStyle: UIUserInterfaceStyle, onDismiss: (@MainActor () -> Void)?) {
        self.content = content
        self.detents = detents
        self.isDismissible = isDismissible
        self.interfaceStyle = interfaceStyle
        self.onDismiss = onDismiss
        originalStyle = content.modalPresentationStyle
        originalDelegate = content.transitioningDelegate
        originalOverride = content.overrideUserInterfaceStyle
        super.init()
    }

    static func session(for content: UIViewController) -> RCSheetSession? {
        objc_getAssociatedObject(content, &key) as? RCSheetSession
    }

    /// Session of the sheet presenting `controller` or one of its ancestors.
    static func hosting(_ controller: UIViewController) -> RCSheetSession? {
        var node: UIViewController? = controller
        while let current = node {
            if let session = session(for: current), session.state != .finished { return session }
            node = current.parent
        }
        return nil
    }

    func start(from presenter: UIViewController) {
        guard let content, state == .idle else { return }
        objc_setAssociatedObject(content, &Self.key, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        content.modalPresentationStyle = .custom
        content.transitioningDelegate = self
        if interfaceStyle != .unspecified, content.overrideUserInterfaceStyle == .unspecified {
            content.overrideUserInterfaceStyle = interfaceStyle
            appliedOverride = true
        }
        state = .waiting
        RCModalSupport.present(
            content,
            from: presenter,
            window: presenter.viewIfLoaded?.window,
            animated: RCModalSupport.animationsEnabled,
            waitsForDialogs: true,
            isCancelled: { [weak self] in self?.state != .waiting }
        ) { [weak self] presented in
            guard let self else { return }
            if presented {
                if self.state == .waiting { self.state = .presented }
            } else {
                self.finish()
            }
        }
    }

    func dismiss(animated: Bool, velocity: CGFloat = 0, completion: (@MainActor () -> Void)?) {
        if let completion { completions.append(completion) }
        switch state {
        case .idle, .waiting:
            // Never made it on screen: cancel the pending presentation.
            finish()
        case .presented:
            guard let content else { finish(); return }
            state = .dismissing
            dismissalVelocity = velocity
            let animated = animated && RCModalSupport.animationsEnabled
            if let presenting = content.presentingViewController {
                presenting.dismiss(animated: animated)
            } else {
                finish()
            }
        case .dismissing:
            break
        case .finished:
            let pending = completions
            completions.removeAll()
            pending.forEach { $0() }
        }
    }

    /// Called by the presentation controller when UIKit starts a dismissal
    /// that did not come through `dismiss` (e.g. content called `dismiss`).
    func dismissalDidBegin() {
        if state == .presented || state == .waiting { state = .dismissing }
    }

    func presentationDidBegin(_ controller: RCSheetPresentationController) {
        presentationController = controller
        if state == .waiting { state = .presented }
    }

    /// Ends the session exactly once: restores the content's configuration,
    /// then runs `onDismiss` and pending dismissal completions.
    func finish() {
        guard state != .finished else { return }
        state = .finished
        if let content {
            if content.transitioningDelegate === self {
                content.transitioningDelegate = originalDelegate
                content.modalPresentationStyle = originalStyle
            }
            if appliedOverride, content.overrideUserInterfaceStyle == interfaceStyle {
                content.overrideUserInterfaceStyle = originalOverride
            }
            objc_setAssociatedObject(content, &Self.key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        let callback = onDismiss
        onDismiss = nil
        let pending = completions
        completions.removeAll()
        callback?()
        pending.forEach { $0() }
    }

    // MARK: UIViewControllerTransitioningDelegate

    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        let controller = RCSheetPresentationController(presentedViewController: presented, presenting: presenting, session: self)
        presentationController = controller
        return controller
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        RCSheetTransitionAnimator(isPresenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        RCSheetTransitionAnimator(isPresenting: false)
    }
}

/// Presentation completes at once (motion continues as an interruptible
/// animation owned by the presentation controller); dismissal lasts until the
/// exit animation ends.
@MainActor
final class RCSheetTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let isPresenting: Bool

    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        isPresenting ? 0 : 0.3
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = isPresenting ? .to : .from
        guard let controller = transitionContext.viewController(forKey: key)?.presentationController as? RCSheetPresentationController else {
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            return
        }
        if isPresenting {
            controller.installChrome()
            transitionContext.completeTransition(true)
            controller.animateEntrance()
        } else {
            controller.animateExit {
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            }
        }
    }
}
