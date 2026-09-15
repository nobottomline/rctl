import UIKit

/// Non-blocking notification (sonner-style): stacked cards, swipe to dismiss,
/// auto-hide. Lives in a pass-through overlay above all content.
///
/// Each window scene gets one overlay window above the app window (never key,
/// never first responder, touches pass through everywhere except on toasts).
/// Up to three toasts per edge are visible; older ones tuck behind the newest.
/// Timers pause while a toast is touched and while the scene is inactive.
/// `duration <= 0` or `.infinity` keeps a toast until it is dismissed.
@MainActor
enum RCToast {
    enum Tone: Sendable { case info, success, warning, error }
    enum Position: Sendable { case top, bottom }

    static func show(
        _ title: String,
        message: String? = nil,
        tone: Tone = .info,
        icon: RCIconGlyph? = nil,
        duration: TimeInterval = 4,
        position: Position = .top,
        in window: UIWindow? = nil
    ) {
        guard let source = window ?? UIApplication.shared.activeKeyWindow, let scene = source.windowScene else { return }
        let toast = RCToastView(title: title, message: message, tone: tone, icon: icon, duration: duration, position: position)
        RCToastHost.host(for: scene).show(toast, from: source)
        let spoken = [RCToastView.tonePrefix(for: tone).map { "\($0): \(title)" } ?? title, message].compactMap { $0 }.joined(separator: ". ")
        UIAccessibility.post(notification: .announcement, argument: spoken)
    }

    static func dismissAll() {
        RCToastHost.allHosts.forEach { $0.dismissAll() }
    }
}

// MARK: - Host

@MainActor
final class RCToastHost: NSObject, UIGestureRecognizerDelegate {
    static let maximumVisible = 3
    private static let scales: [CGFloat] = [1, 0.94, 0.88]
    /// Visible strip of each tucked card beyond the one in front of it.
    private static let peek: CGFloat = 9
    private static var hosts: [ObjectIdentifier: RCToastHost] = [:]

    static var allHosts: [RCToastHost] { Array(hosts.values) }

    static func host(for scene: UIWindowScene) -> RCToastHost {
        let key = ObjectIdentifier(scene)
        if let host = hosts[key], host.scene != nil { return host }
        let host = RCToastHost(scene: scene)
        hosts[key] = host
        return host
    }

    private weak var scene: UIWindowScene?
    weak var sourceWindow: UIWindow?
    let window: RCToastWindow
    private let root: RCToastRootViewController
    /// Oldest first.
    private(set) var toasts: [RCToastView] = []
    private var pauseReasons: Set<String> = []
    private let clock: RCModalClock = RCSystemModalClock.shared
    nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []

    private init(scene: UIWindowScene) {
        self.scene = scene
        window = RCToastWindow(windowScene: scene)
        root = RCToastRootViewController()
        super.init()
        root.host = self
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.backgroundColor = .clear
        window.rootViewController = root
        window.isHidden = true
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause("inactive") }
            },
            center.addObserver(forName: UIScene.didActivateNotification, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume("inactive") }
            },
            center.addObserver(forName: UIScene.didDisconnectNotification, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tearDown() }
            },
        ]
        if scene.activationState != .foregroundActive { pauseReasons.insert("inactive") }
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    private func tearDown() {
        toasts.forEach { $0.removeFromSuperview() }
        toasts.removeAll()
        window.isHidden = true
        if let scene { Self.hosts[ObjectIdentifier(scene)] = nil }
    }

    // MARK: Showing

    func show(_ toast: RCToastView, from source: UIWindow) {
        if !(source is RCToastWindow) { sourceWindow = source }
        window.overrideUserInterfaceStyle = interfaceStyle(for: sourceWindow)
        if window.isHidden {
            window.frame = scene?.coordinateSpace.bounds ?? source.bounds
            window.isHidden = false
            root.view.frame = window.bounds
        }
        root.setNeedsStatusBarAppearanceUpdate()
        toast.onDismissRequest = { [weak self] toast in self?.dismiss(toast) }
        attachGestures(to: toast)
        root.view.addSubview(toast)
        toasts.append(toast)

        // Place the newcomer just beyond its edge, then spring everything into place.
        let slots = targetSlots()
        if let slot = slots[ObjectIdentifier(toast)] {
            toast.bounds = CGRect(origin: .zero, size: slot.size)
            toast.center = slot.center
            toast.layoutIfNeeded()
            if RCMotion.reduceMotion {
                toast.alpha = 0
            } else {
                let safe = root.view.safeAreaInsets
                let distance = toast.position == .top
                    ? -(slot.center.y + slot.size.height / 2 + 24)
                    : (root.view.bounds.height - (slot.center.y - slot.size.height / 2) + safe.bottom + 24)
                toast.transform = CGAffineTransform(translationX: 0, y: distance)
            }
        }
        let overflow = toasts.filter { $0.position == toast.position && !$0.isDismissing }.dropLast(Self.maximumVisible)
        overflow.forEach { dismiss($0) }
        layout(animated: true)
        startTimer(for: toast)
    }

    func dismissAll() {
        toasts.filter { !$0.isDismissing }.forEach { dismiss($0) }
    }

    /// Top controller of the app window, its effective appearance forced onto toasts.
    private func interfaceStyle(for source: UIWindow?) -> UIUserInterfaceStyle {
        guard let source else { return .unspecified }
        let top = RCToastRootViewController.visibleController(in: source)
        let inherited = RCModalSupport.inheritedInterfaceStyle(from: top)
        return inherited != .unspecified ? inherited : source.overrideUserInterfaceStyle
    }

    // MARK: Layout

    private struct Slot {
        var size: CGSize
        var center: CGPoint
        var transform: CGAffineTransform
        var depth: Int
    }

    private func targetSlots() -> [ObjectIdentifier: Slot] {
        let bounds = root.view.bounds
        let safe = root.view.safeAreaInsets
        let width = max(0, min(RCToastView.maximumWidth, bounds.width - 32 - safe.left - safe.right))
        var slots: [ObjectIdentifier: Slot] = [:]
        for position in [RCToast.Position.top, .bottom] {
            let stack = toasts.filter { $0.position == position && !$0.isDismissing }.reversed()
            guard let front = stack.first else { continue }
            let frontHeight = front.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            let y = position == .top ? safe.top + RCSpace.sm : bounds.height - safe.bottom - RCSpace.md - frontHeight
            let center = CGPoint(x: bounds.midX, y: y + frontHeight / 2)
            let lift: CGFloat = position == .top ? 1 : -1
            for (depth, toast) in stack.enumerated() {
                let scale = Self.scales[min(depth, Self.scales.count - 1)]
                let offset = depth == 0 ? 0 : CGFloat(depth) * Self.peek + (1 - scale) * frontHeight / 2
                let transform = CGAffineTransform(translationX: 0, y: lift * offset).scaledBy(x: scale, y: scale)
                slots[ObjectIdentifier(toast)] = Slot(size: CGSize(width: width, height: frontHeight), center: center, transform: transform, depth: depth)
            }
        }
        return slots
    }

    func layout(animated: Bool) {
        let slots = targetSlots()
        // Newest cards draw on top.
        for toast in toasts where !toast.isDismissing {
            root.view.bringSubviewToFront(toast)
        }
        let apply: @MainActor () -> Void = {
            for toast in self.toasts where !toast.isDismissing {
                guard let slot = slots[ObjectIdentifier(toast)] else { continue }
                toast.bounds = CGRect(origin: .zero, size: slot.size)
                toast.center = slot.center
                toast.transform = slot.transform
                toast.alpha = 1
                toast.contentView.alpha = slot.depth == 0 ? 1 : 0
                toast.accessibilityElementsHidden = false
                toast.layoutIfNeeded()
            }
        }
        if animated, root.view.window != nil {
            RCMotion.animate(RCMotion.snappy, animations: apply)
        } else {
            withoutImplicitAnimations { apply() }
        }
    }

    fileprivate func rootDidLayout() {
        layout(animated: false)
    }

    // MARK: Dismissal

    func dismiss(_ toast: RCToastView, velocity: CGFloat = 0) {
        guard !toast.isDismissing, toast.superview != nil else { return }
        let wasFront = targetSlots()[ObjectIdentifier(toast)]?.depth == 0
        toast.isDismissing = true
        toast.timerGeneration += 1
        toast.timerStartedAt = nil
        toast.isUserInteractionEnabled = false
        toast.accessibilityElementsHidden = true
        let reduce = RCMotion.reduceMotion
        let finish: @MainActor (Bool) -> Void = { [weak self, weak toast] _ in
            guard let self, let toast else { return }
            toast.removeFromSuperview()
            self.toasts.removeAll { $0 === toast }
            if self.toasts.isEmpty { self.window.isHidden = true }
        }
        if reduce {
            RCMotion.animate(duration: RCMotion.reducedDuration, animations: { toast.alpha = 0 }, completion: finish)
        } else if wasFront {
            let lift: CGFloat = toast.position == .top ? -1 : 1
            let distance = toast.bounds.height + 40
            let current = toast.transform.ty
            let travel = abs(lift * distance - current)
            let relative = travel > 1 ? min(abs(velocity) / travel, 10) : 0
            let timing = UISpringTimingParameters(dampingRatio: 1, initialVelocity: CGVector(dx: 0, dy: relative))
            let animator = UIViewPropertyAnimator(duration: 0.34, timingParameters: timing)
            animator.addAnimations {
                toast.transform = CGAffineTransform(translationX: 0, y: lift * distance)
            }
            animator.addAnimations({ toast.alpha = 0 }, delayFactor: 0.25)
            animator.addCompletion { _ in MainActor.assumeIsolated { finish(true) } }
            animator.startAnimation()
        } else {
            RCMotion.animate(duration: 0.2, curve: RCMotion.easeIn, animations: {
                toast.alpha = 0
                toast.transform = toast.transform.scaledBy(x: 0.96, y: 0.96)
            }, completion: finish)
        }
        layout(animated: true)
    }

    // MARK: Timers

    private func startTimer(for toast: RCToastView) {
        guard pauseReasons.isEmpty, !toast.isDismissing, toast.duration > 0, toast.duration.isFinite else { return }
        toast.timerGeneration += 1
        let generation = toast.timerGeneration
        toast.timerStartedAt = clock.now
        clock.schedule(after: toast.remaining) { [weak self, weak toast] in
            guard let self, let toast, toast.timerGeneration == generation, toast.timerStartedAt != nil else { return }
            self.dismiss(toast)
        }
    }

    private func pause(_ reason: String) {
        let wasRunning = pauseReasons.isEmpty
        pauseReasons.insert(reason)
        guard wasRunning else { return }
        let now = clock.now
        for toast in toasts {
            if let started = toast.timerStartedAt {
                toast.remaining = max(0.6, toast.remaining - (now - started))
            }
            toast.timerStartedAt = nil
            toast.timerGeneration += 1
        }
    }

    private func resume(_ reason: String) {
        guard pauseReasons.remove(reason) != nil, pauseReasons.isEmpty else { return }
        toasts.forEach(startTimer(for:))
    }

    // MARK: Gestures

    private func attachGestures(to toast: RCToastView) {
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0
        hold.allowableMovement = .greatestFiniteMagnitude
        hold.cancelsTouchesInView = false
        hold.delaysTouchesBegan = false
        hold.delegate = self
        toast.addGestureRecognizer(hold)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        toast.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        toast.addGestureRecognizer(pan)
        tap.require(toFail: pan)
    }

    @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began: pause("touch")
        case .ended, .cancelled, .failed: resume("touch")
        default: break
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let toast = gesture.view as? RCToastView else { return }
        RCHaptics.play(.light)
        dismiss(toast)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let toast = gesture.view as? RCToastView, !toast.isDismissing else { return }
        let base = targetSlots()[ObjectIdentifier(toast)]?.transform ?? .identity
        let towardEdge: CGFloat = toast.position == .top ? -1 : 1
        let translation = gesture.translation(in: root.view).y
        switch gesture.state {
        case .began:
            pause("drag")
        case .changed:
            let along = translation * towardEdge
            let offset = along >= 0 ? along : -RCModalSupport.rubberBand(-along, dimension: 36)
            toast.transform = base.concatenating(CGAffineTransform(translationX: 0, y: offset * towardEdge))
        case .ended, .cancelled, .failed:
            let velocity = gesture.state == .ended ? gesture.velocity(in: root.view).y : 0
            let along = translation * towardEdge
            let alongVelocity = velocity * towardEdge
            if gesture.state == .ended, along > toast.bounds.height * 0.35 || alongVelocity > 450 {
                RCHaptics.play(.light)
                dismiss(toast, velocity: velocity)
            } else {
                layout(animated: true)
            }
            resume("drag")
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: root.view)
        return abs(velocity.y) >= abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UILongPressGestureRecognizer || otherGestureRecognizer is UILongPressGestureRecognizer
    }
}

// MARK: - Overlay window

/// Pass-through window: only toast cards receive touches; it never becomes key.
@MainActor
final class RCToastWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        var node = super.hitTest(point, with: event)
        let hit = node
        while let view = node {
            if view is RCToastView { return hit }
            node = view.superview
        }
        return nil
    }

    @available(iOS 15.0, *)
    override var canBecomeKey: Bool { false }

    override func makeKey() {}

    override var canBecomeFirstResponder: Bool { false }
}

/// Root of the overlay window: transparent, and defers status bar, home
/// indicator and rotation decisions to the app window's visible controller.
@MainActor
final class RCToastRootViewController: UIViewController {
    fileprivate weak var host: RCToastHost?

    override func loadView() {
        let view = RCToastRootView()
        view.backgroundColor = .clear
        view.onLayout = { [weak self] in self?.host?.rootDidLayout() }
        self.view = view
    }

    private var deferred: UIViewController? {
        guard let source = host?.sourceWindow else { return nil }
        return Self.visibleController(in: source)
    }

    /// The controller that decides status bar appearance in `window`.
    static func visibleController(in window: UIWindow) -> UIViewController? {
        guard var current = window.rootViewController else { return nil }
        for _ in 0..<32 {
            if let presented = current.presentedViewController, !presented.isBeingDismissed,
               presented.modalPresentationCapturesStatusBarAppearance || presented.modalPresentationStyle == .fullScreen || presented.modalPresentationStyle == .overFullScreen {
                current = presented
            } else if let child = current.childForStatusBarStyle, child !== current {
                current = child
            } else {
                break
            }
        }
        return current
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { deferred?.preferredStatusBarStyle ?? .default }
    override var prefersStatusBarHidden: Bool { deferred?.prefersStatusBarHidden ?? false }
    override var prefersHomeIndicatorAutoHidden: Bool { deferred?.prefersHomeIndicatorAutoHidden ?? false }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { deferred?.preferredScreenEdgesDeferringSystemGestures ?? [] }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        host?.sourceWindow?.rootViewController?.supportedInterfaceOrientations ?? .all
    }
    override var shouldAutorotate: Bool { true }
}

@MainActor
private final class RCToastRootView: UIView {
    var onLayout: (() -> Void)?
    private var lastSize: CGSize = .zero
    private var lastInsets: UIEdgeInsets = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize || safeAreaInsets != lastInsets else { return }
        lastSize = bounds.size
        lastInsets = safeAreaInsets
        onLayout?()
    }
}
