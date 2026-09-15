import UIKit

/// Presentation controller behind `RCSheet`.
///
/// Geometry: the chrome view's bounds/center hold the resting (or dragged)
/// sheet frame; its `transform` only carries transient vertical offsets
/// (entrance, exit, dragging below the smallest detent). On a phone the sheet
/// is resized while dragging between detents so bottom-pinned content stays on
/// the bottom edge; a card (iPad) only translates while dragging.
@MainActor
final class RCSheetPresentationController: UIPresentationController, UIGestureRecognizerDelegate {
    private weak var session: RCSheetSession?
    private let detents: [RCSheetDetent]
    let isDismissible: Bool
    private let interfaceStyle: UIUserInterfaceStyle

    private let dimmingView = UIView()
    let chromeView = RCSheetChromeView()
    private let keyboard = RCKeyboardObserver()
    private var panGesture: UIPanGestureRecognizer?

    private var geometry: RCSheetGeometry?
    private(set) var detentHeights: [CGFloat] = []
    private(set) var selectedIndex = 0
    private var selectedDetent: RCSheetDetent
    private var keyboardHeight: CGFloat = 0

    private struct Drag {
        var baseVisible: CGFloat
        var translation: CGFloat = 0
        var lastFingerY: CGFloat = 0
        weak var scrollView: UIScrollView?
        var sheetDriving = false
        var pinnedOffset: CGPoint?
        var drove = false
    }

    private var drag: Drag?
    private var pinnedScrollView: UIScrollView?
    private var pinnedOffset: CGPoint?
    private var scrollObservation: NSKeyValueObservation?
    private var motion: UIViewPropertyAnimator?
    private var isInstalled = false
    private var isInstalling = false
    private(set) var isExiting = false
    private var animatesEntrance = false

    init(presentedViewController: UIViewController, presenting: UIViewController?, session: RCSheetSession) {
        self.session = session
        detents = session.detents
        isDismissible = session.isDismissible
        interfaceStyle = session.interfaceStyle
        selectedDetent = session.detents.min { lhs, rhs in
            // Start at the smallest detent (like UISheetPresentationController).
            RCSheetPresentationController.order(lhs) < RCSheetPresentationController.order(rhs)
        } ?? .fitting
        super.init(presentedViewController: presentedViewController, presenting: presenting)
        keyboard.onChange = { [weak self] change in self?.keyboardDidChange(change) }
    }

    /// Rough ordering used only to pick the starting detent before geometry exists.
    private static func order(_ detent: RCSheetDetent) -> CGFloat {
        switch detent {
        case .fitting: 0
        case let .height(value): value
        case .medium: 10_000
        case .large: 20_000
        }
    }

    override var presentedView: UIView? { chromeView }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let geometry else { return chromeView.frame }
        return RCSheetLayout.frame(height: restHeight, in: geometry)
    }

    private var restHeight: CGFloat {
        detentHeights.indices.contains(selectedIndex) ? detentHeights[selectedIndex] : 0
    }

    // MARK: Presentation lifecycle

    override func presentationTransitionWillBegin() {
        super.presentationTransitionWillBegin()
        session?.presentationDidBegin(self)
        animatesEntrance = presentedViewController.transitionCoordinator?.isAnimated ?? false
        installChrome()
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        super.presentationTransitionDidEnd(completed)
        if !completed {
            dimmingView.removeFromSuperview()
            session?.finish()
            return
        }
        if !animatesEntrance {
            dimmingView.alpha = 1
            UIAccessibility.post(notification: .screenChanged, argument: presentedViewController.view)
        }
    }

    /// Adds scrim, chrome and content to the container and measures detents.
    /// Idempotent (called from `presentationTransitionWillBegin` and the animator).
    func installChrome() {
        guard !isInstalled, let containerView else { return }
        isInstalled = true
        isInstalling = true
        defer { isInstalling = false }
        if interfaceStyle != .unspecified {
            containerView.overrideUserInterfaceStyle = interfaceStyle
        }
        dimmingView.backgroundColor = RCColor.scrim
        dimmingView.isAccessibilityElement = false
        dimmingView.frame = containerView.bounds
        dimmingView.alpha = animatesEntrance ? 0 : 1
        dimmingView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleScrimTap)))
        containerView.addSubview(dimmingView)

        chromeView.setContent(presentedViewController.view)
        chromeView.onEscape = { [weak self] in self?.performEscape() ?? false }
        chromeView.onWindowChange = { [weak self] window in self?.chromeWindowDidChange(window) }
        chromeView.grabber.owner = self
        containerView.addSubview(chromeView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        chromeView.addGestureRecognizer(pan)
        panGesture = pan

        resolveLayout()
        applyRestFrame()
        // Content often derives preferredContentSize from its width: lay out
        // once at the final width, then measure again.
        presentedViewController.view.layoutIfNeeded()
        resolveLayout()
        applyRestFrame()
        chromeView.layoutIfNeeded()
        if animatesEntrance {
            if RCMotion.reduceMotion {
                chromeView.alpha = 0
            } else {
                chromeView.transform = CGAffineTransform(translationX: 0, y: offscreenDistance)
            }
        }
    }

    func animateEntrance() {
        guard animatesEntrance, chromeView.superview != nil else { return }
        let reduce = RCMotion.reduceMotion
        let animator: UIViewPropertyAnimator
        if reduce {
            animator = UIViewPropertyAnimator(duration: RCMotion.reducedDuration * 1.5, curve: .easeOut) {
                self.chromeView.alpha = 1
                self.dimmingView.alpha = 1
            }
        } else {
            let timing = UISpringTimingParameters(dampingRatio: RCMotion.smooth.damping)
            animator = UIViewPropertyAnimator(duration: RCMotion.smooth.response, timingParameters: timing)
            animator.addAnimations {
                self.chromeView.transform = .identity
                self.dimmingView.alpha = 1
            }
        }
        animator.addCompletion { [weak self, weak animator] position in
            MainActor.assumeIsolated {
                guard let self, position == .end else { return }
                if let animator, self.motion === animator { self.motion = nil }
                UIAccessibility.post(notification: .screenChanged, argument: self.presentedViewController.view)
            }
        }
        motion = animator
        animator.startAnimation()
    }

    override func dismissalTransitionWillBegin() {
        super.dismissalTransitionWillBegin()
        session?.dismissalDidBegin()
        cancelDrag()
        if !(presentedViewController.transitionCoordinator?.isAnimated ?? false) {
            dimmingView.alpha = 0
        }
    }

    /// Exit animation for the dismissal transition; continues with the finger
    /// velocity handed over by a released drag.
    func animateExit(completion: @escaping @MainActor () -> Void) {
        isExiting = true
        panGesture?.isEnabled = false
        let velocity = session?.dismissalVelocity ?? 0
        captureInFlightMotion()
        let animator: UIViewPropertyAnimator
        if RCMotion.reduceMotion {
            animator = UIViewPropertyAnimator(duration: RCMotion.reducedDuration * 1.5, curve: .easeIn) {
                self.chromeView.alpha = 0
                self.dimmingView.alpha = 0
            }
        } else {
            let currentOffset = chromeView.transform.ty
            let target = offscreenDistance
            let distance = max(1, target - currentOffset)
            let relative = min(max(velocity / distance, 0), 12)
            let timing = UISpringTimingParameters(dampingRatio: 1, initialVelocity: CGVector(dx: 0, dy: relative))
            let duration: TimeInterval = velocity > 800 ? 0.3 : 0.38
            animator = UIViewPropertyAnimator(duration: duration, timingParameters: timing)
            animator.addAnimations {
                self.chromeView.transform = CGAffineTransform(translationX: 0, y: target)
                self.dimmingView.alpha = 0
            }
        }
        animator.addCompletion { _ in
            MainActor.assumeIsolated { completion() }
        }
        motion = animator
        animator.startAnimation()
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        super.dismissalTransitionDidEnd(completed)
        if completed {
            unpinScrollView()
            dimmingView.removeFromSuperview()
            // UIKit unlinks the presentation right after this callback; run
            // onDismiss on the next turn so it can present again immediately.
            let session = session
            DispatchQueue.main.async {
                MainActor.assumeIsolated { session?.finish() }
            }
        } else {
            // Defensive: UIKit cancelled the dismissal; restore the resting state.
            isExiting = false
            panGesture?.isEnabled = true
            chromeView.alpha = 1
            chromeView.transform = .identity
            dimmingView.alpha = 1
            applyRestFrame()
        }
    }

    private func chromeWindowDidChange(_ window: UIWindow?) {
        guard window == nil else { return }
        // Safety net for teardown paths that skip dismissal callbacks (e.g. a
        // controller lower in the stack dismissed everything above it).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.chromeView.window == nil, self.presentedViewController.presentingViewController == nil else { return }
                self.session?.finish()
            }
        }
    }

    // MARK: Layout

    private func makeGeometry() -> RCSheetGeometry? {
        guard let containerView, containerView.bounds.width > 0 else { return nil }
        let traits = containerView.traitCollection
        let style: RCSheetGeometry.Style = traits.userInterfaceIdiom == .pad && traits.horizontalSizeClass == .regular ? .card : .bottomSheet
        let preferred = presentedViewController.preferredContentSize.height
        return RCSheetGeometry(
            style: style,
            containerSize: containerView.bounds.size,
            safeAreaInsets: containerView.safeAreaInsets,
            keyboardHeight: keyboardHeight,
            preferredContentHeight: preferred > 0 ? preferred : nil
        )
    }

    @discardableResult
    private func resolveLayout() -> Bool {
        guard let next = makeGeometry() else { return false }
        let changed = next != geometry
        geometry = next
        detentHeights = RCSheetLayout.resolvedHeights(for: detents, in: next)
        selectedIndex = RCSheetLayout.index(of: selectedDetent, in: detentHeights, geometry: next)
        chromeView.style = next.style
        chromeView.grabber.isHidden = next.style == .card && !isDismissible && detentHeights.count < 2
        return changed
    }

    private func applyRestFrame() {
        guard let geometry else { return }
        setChromeFrame(RCSheetLayout.frame(height: restHeight, in: geometry))
        if let containerView { dimmingView.frame = containerView.bounds }
        chromeView.grabber.updateAccessibility()
    }

    /// Frame without touching the transform (setting `frame` under a transform is undefined).
    private func setChromeFrame(_ rect: CGRect) {
        let bounds = CGRect(origin: .zero, size: rect.size)
        if chromeView.bounds != bounds { chromeView.bounds = bounds }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if chromeView.center != center { chromeView.center = center }
    }

    /// Translation that moves the sheet fully below the container edge.
    private var offscreenDistance: CGFloat {
        guard let containerView else { return 1000 }
        let top = chromeView.center.y - chromeView.bounds.height / 2
        return max(0, containerView.bounds.height - top) + RCShadow.modal.radius + 24
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        layoutForContainerChange(animated: false)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            MainActor.assumeIsolated { self.layoutForContainerChange(animated: false) }
        })
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        containerView?.setNeedsLayout()
    }

    private func layoutForContainerChange(animated: Bool) {
        guard isInstalled, !isInstalling, let containerView else { return }
        dimmingView.frame = containerView.bounds
        guard drag == nil, !isExiting else { return }
        guard resolveLayout() else { return }
        motion?.stopAnimation(true)
        motion = nil
        chromeView.transform = .identity
        chromeView.alpha = 1
        applyRestFrame()
        chromeView.layoutIfNeeded()
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        contentSizeDidChange(animated: true)
    }

    /// Re-measures detents (content size changed) and springs to the new height.
    func contentSizeDidChange(animated: Bool) {
        guard isInstalled, !isInstalling, !isExiting, drag == nil else { return }
        guard resolveLayout() else { return }
        guard let geometry else { return }
        let target = RCSheetLayout.frame(height: restHeight, in: geometry)
        let animate = animated && RCModalSupport.animationsEnabled && chromeView.window != nil
        guard animate else {
            applyRestFrame()
            chromeView.layoutIfNeeded()
            return
        }
        RCMotion.animate(RCMotion.smooth, animations: {
            self.setChromeFrame(target)
            self.chromeView.layoutIfNeeded()
        })
        chromeView.grabber.updateAccessibility()
    }

    // MARK: Keyboard

    private func keyboardDidChange(_ change: RCKeyboardObserver.Change) {
        guard isInstalled, !isExiting, let containerView else { return }
        let overlap = RCKeyboardObserver.overlap(of: change.frameInScreen, in: containerView)
        let ownsResponder = RCModalSupport.firstResponder(in: presentedViewController.view) != nil
        let next = overlap > 0 && !ownsResponder ? 0 : overlap
        guard abs(next - keyboardHeight) > 0.5 else { return }
        keyboardHeight = next
        guard drag == nil, resolveLayout(), let geometry else { return }
        let target = RCSheetLayout.frame(height: restHeight, in: geometry)
        guard change.duration > 0, chromeView.window != nil, RCModalSupport.animationsEnabled else {
            applyRestFrame()
            chromeView.layoutIfNeeded()
            return
        }
        UIView.animate(withDuration: change.duration, delay: 0, options: [change.curve, .beginFromCurrentState, .allowUserInteraction]) {
            self.setChromeFrame(target)
            self.chromeView.layoutIfNeeded()
        }
        chromeView.grabber.updateAccessibility()
    }

    // MARK: Dismissal entry points

    @objc private func handleScrimTap() {
        guard isDismissible, !isExiting, drag == nil else { return }
        session?.dismiss(animated: true, completion: nil)
    }

    private func performEscape() -> Bool {
        guard isDismissible, !isExiting else { return false }
        session?.dismiss(animated: true, completion: nil)
        return true
    }

    // MARK: Accessibility detent changes

    func selectDetent(at index: Int, animated: Bool) {
        guard detentHeights.indices.contains(index), !isExiting, drag == nil, let geometry else { return }
        selectedIndex = index
        selectedDetent = detent(forHeightAt: index, in: geometry)
        let target = RCSheetLayout.frame(height: restHeight, in: geometry)
        if animated, RCModalSupport.animationsEnabled {
            motion?.stopAnimation(true)
            motion = RCMotion.animate(RCMotion.smooth, animations: {
                self.chromeView.transform = .identity
                self.setChromeFrame(target)
                self.chromeView.layoutIfNeeded()
            })
        } else {
            applyRestFrame()
        }
        chromeView.grabber.updateAccessibility()
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    func dismissFromAccessibility() {
        guard isDismissible else { return }
        session?.dismiss(animated: true, completion: nil)
    }

    private func detent(forHeightAt index: Int, in geometry: RCSheetGeometry) -> RCSheetDetent {
        let height = detentHeights[index]
        return detents.first { abs(RCSheetLayout.height(for: $0, in: geometry) - height) <= 0.5 } ?? selectedDetent
    }

    // MARK: Dragging

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let containerView else { return }
        let fingerY = gesture.translation(in: containerView).y
        switch gesture.state {
        case .began:
            beginDrag(scrollView: handoffScrollView(at: gesture.location(in: chromeView)))
            drag?.lastFingerY = fingerY
        case .changed:
            updateDrag(fingerY: fingerY)
        case .ended:
            endDrag(velocity: gesture.velocity(in: containerView).y)
        case .cancelled, .failed:
            endDrag(velocity: 0)
        default:
            break
        }
    }

    /// Starts a drag from the current on-screen state (interrupting any spring).
    func beginDrag(scrollView: UIScrollView? = nil) {
        guard isInstalled, !isExiting, let geometry else { return }
        captureInFlightMotion()
        let visible: CGFloat
        switch geometry.style {
        case .bottomSheet:
            let bottom = geometry.containerSize.height - max(0, geometry.keyboardHeight)
            let top = chromeView.center.y - chromeView.bounds.height / 2 + chromeView.transform.ty
            visible = bottom - top
        case .card:
            visible = restHeight - chromeView.transform.ty
        }
        drag = Drag(baseVisible: visible, scrollView: scrollView)
    }

    func updateDrag(fingerY: CGFloat) {
        guard var current = drag else { return }
        let delta = fingerY - current.lastFingerY
        current.lastFingerY = fingerY
        let largest = detentHeights.last ?? restHeight
        var applied = delta
        if let scrollView = current.scrollView {
            let top = -scrollView.adjustedContentInset.top
            let atTop = scrollView.contentOffset.y <= top + 0.5
            let visible = current.baseVisible - current.translation
            let drive: Bool
            if delta > 0 {
                drive = atTop || current.sheetDriving
            } else if delta < 0 {
                if visible < largest - 0.5 {
                    drive = true
                    applied = max(delta, visible - largest)
                } else {
                    let scrollable = scrollView.contentSize.height + scrollView.adjustedContentInset.top + scrollView.adjustedContentInset.bottom > scrollView.bounds.height + 0.5
                    drive = current.sheetDriving && visible > largest + 0.5 || !scrollable
                }
            } else {
                drive = current.sheetDriving
            }
            if drive, !current.sheetDriving {
                pin(scrollView, at: atTop ? CGPoint(x: scrollView.contentOffset.x, y: top) : scrollView.contentOffset)
            } else if !drive, current.sheetDriving {
                unpinScrollView()
            }
            current.sheetDriving = drive
            if !drive { applied = 0 }
        } else {
            current.sheetDriving = true
        }
        if current.sheetDriving { current.drove = true }
        current.translation += applied
        drag = current
        applyDrag()
    }

    private func applyDrag() {
        guard let drag, let geometry else { return }
        let visible = drag.baseVisible - drag.translation
        let resizes = geometry.style == .bottomSheet
        let state = RCSheetLayout.dragState(visibleHeight: visible, detentHeights: detentHeights, isDismissible: isDismissible, resizes: resizes, restHeight: restHeight)
        if resizes {
            setChromeFrame(RCSheetLayout.frame(height: state.height + state.stretch, in: geometry))
        }
        chromeView.transform = state.offset == 0 ? .identity : CGAffineTransform(translationX: 0, y: state.offset)
        if isDismissible, let smallest = detentHeights.first {
            let travel = geometry.style == .bottomSheet ? smallest : geometry.containerSize.height / 2
            let under = max(0, smallest - visible)
            dimmingView.alpha = 1 - min(1, under / max(1, travel)) * 0.9
        }
    }

    func endDrag(velocity: CGFloat) {
        guard let finished = drag else { return }
        drag = nil
        let visible = finished.baseVisible - finished.translation
        if !finished.drove {
            unpinScrollView()
            return
        }
        let effectiveVelocity = finished.sheetDriving || finished.scrollView == nil ? velocity : 0
        let target = RCSheetLayout.snapTarget(visibleHeight: visible, velocity: effectiveVelocity, detentHeights: detentHeights, isDismissible: isDismissible)
        switch target {
        case .dismiss:
            unpinScrollView()
            session?.dismiss(animated: true, velocity: max(0, effectiveVelocity), completion: nil)
        case let .detent(index):
            settle(at: index, velocity: effectiveVelocity)
        }
    }

    /// Abandons a drag without choosing a target (dismissal started elsewhere).
    private func cancelDrag() {
        guard drag != nil else { return }
        drag = nil
        unpinScrollView()
    }

    private func settle(at index: Int, velocity: CGFloat) {
        guard let geometry else { return }
        if detentHeights.indices.contains(index) {
            selectedIndex = index
            selectedDetent = detent(forHeightAt: index, in: geometry)
        }
        // A keyboard change during the drag may have changed the geometry.
        resolveLayout()
        guard let geometry = self.geometry else { return }
        let target = RCSheetLayout.frame(height: restHeight, in: geometry)
        let currentTop = chromeView.center.y - chromeView.bounds.height / 2 + chromeView.transform.ty
        let distance = target.minY - currentTop
        let relative = abs(distance) > 1 ? min(max(velocity / distance, -20), 20) : 0
        chromeView.grabber.updateAccessibility()
        guard RCModalSupport.animationsEnabled else {
            chromeView.transform = .identity
            applyRestFrame()
            dimmingView.alpha = 1
            unpinScrollView()
            return
        }
        let animator = RCMotion.animate(RCMotion.smooth, initialVelocity: CGVector(dx: 0, dy: relative), animations: {
            self.chromeView.transform = .identity
            self.setChromeFrame(target)
            self.chromeView.layoutIfNeeded()
            self.dimmingView.alpha = 1
        }, completion: { [weak self] _ in
            guard let self, self.drag == nil else { return }
            self.unpinScrollView()
        })
        motion = animator
    }

    /// Freezes an in-flight spring at its current on-screen values.
    private func captureInFlightMotion() {
        guard let motion else { return }
        self.motion = nil
        if motion.state == .active {
            motion.stopAnimation(false)
            motion.finishAnimation(at: .current)
        }
    }

    // MARK: Scroll handoff

    private func handoffScrollView(at point: CGPoint) -> UIScrollView? {
        guard let scrollView = sheetScrollView, scrollView.window != nil else { return nil }
        let local = chromeView.convert(point, to: scrollView)
        return scrollView.bounds.contains(local) ? scrollView : nil
    }

    private var sheetScrollView: UIScrollView? {
        Self.scrollable(in: presentedViewController)?.sheetScrollView
    }

    private static func scrollable(in controller: UIViewController) -> RCSheetScrollable? {
        if let scrollable = controller as? RCSheetScrollable { return scrollable }
        for child in controller.children {
            if let scrollable = scrollable(in: child) { return scrollable }
        }
        return nil
    }

    private func pin(_ scrollView: UIScrollView, at offset: CGPoint) {
        if pinnedScrollView !== scrollView {
            unpinScrollView()
            pinnedScrollView = scrollView
            scrollObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                MainActor.assumeIsolated {
                    guard let self, let pinned = self.pinnedOffset, self.pinnedScrollView === scrollView, scrollView.contentOffset != pinned else { return }
                    scrollView.contentOffset = pinned
                }
            }
        }
        pinnedOffset = offset
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
    }

    private func unpinScrollView() {
        scrollObservation?.invalidate()
        scrollObservation = nil
        pinnedScrollView = nil
        pinnedOffset = nil
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan === panGesture else { return true }
        guard !isExiting, let containerView else { return false }
        let velocity = pan.velocity(in: containerView)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        // A scrolling view other than the handoff scroll view keeps its gesture.
        let point = pan.location(in: chromeView)
        let handoff = sheetScrollView
        var node = chromeView.hitTest(point, with: nil)
        while let view = node, view !== chromeView {
            if let scrollView = view as? UIScrollView, scrollView !== handoff, scrollView.isScrollEnabled {
                let insets = scrollView.adjustedContentInset
                if scrollView.contentSize.height + insets.top + insets.bottom > scrollView.bounds.height + 0.5 { return false }
            }
            node = view.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGesture, let scrollView = sheetScrollView else { return false }
        return otherGestureRecognizer === scrollView.panGestureRecognizer
    }
}

// MARK: - Chrome

/// Sheet surface: shadow (explicit path) on the outer view, clipping rounded
/// surface inside, content, and the grabber.
@MainActor
final class RCSheetChromeView: RCView {
    /// Surface continues below the bottom edge so springs and stretches never
    /// reveal a gap under a bottom sheet.
    static let bottomOverflow: CGFloat = 160

    let surfaceView = UIView()
    let grabber = RCSheetGrabberView()
    var style: RCSheetGeometry.Style = .bottomSheet {
        didSet {
            guard style != oldValue else { return }
            applyShadowOffset()
            setNeedsLayout()
        }
    }

    var onEscape: (() -> Bool)?
    var onWindowChange: ((UIWindow?) -> Void)?
    private weak var contentView: UIView?

    override func setUp() {
        accessibilityViewIsModal = true
        surfaceView.clipsToBounds = true
        surfaceView.layer.cornerCurve = .continuous
        surfaceView.layer.cornerRadius = RCRadius.xxl
        addSubview(surfaceView)
        surfaceView.addSubview(grabber)
    }

    func setContent(_ view: UIView) {
        contentView = view
        view.autoresizingMask = []
        surfaceView.insertSubview(view, belowSubview: grabber)
        setNeedsLayout()
    }

    override func updateAppearance() {
        surfaceView.backgroundColor = RCColor.surface
        surfaceView.layer.borderColor = RCColor.line.cgColor(for: self)
        surfaceView.layer.borderWidth = traitCollection.userInterfaceStyle == .dark ? RCLayout.hairline : 0
        let shadow = RCShadow.modal
        layer.shadowColor = RCColor.shadow.cgColor(for: self)
        layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? shadow.opacityDark : shadow.opacityLight
        layer.shadowRadius = shadow.radius
        applyShadowOffset()
    }

    /// A bottom sheet casts its shadow upward (its lower edge is off screen); a card uses the modal elevation.
    private func applyShadowOffset() {
        layer.shadowOffset = style == .bottomSheet ? CGSize(width: 0, height: -4) : RCShadow.modal.offset
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let overflow = style == .bottomSheet ? Self.bottomOverflow : 0
        let surface = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height + overflow)
        surfaceView.frame = surface
        surfaceView.layer.maskedCorners = style == .bottomSheet
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        contentView?.frame = bounds
        grabber.frame = CGRect(x: (bounds.width - 36) / 2, y: 8, width: 36, height: 5)
        let path: UIBezierPath = style == .bottomSheet
            ? UIBezierPath(roundedRect: surface, byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: RCRadius.xxl, height: RCRadius.xxl))
            : UIBezierPath.continuousRoundedRect(surface, radius: RCRadius.xxl)
        RCModalSupport.setShadowPath(path.cgPath, on: layer)
    }

    override func accessibilityPerformEscape() -> Bool {
        onEscape?() ?? false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }
}

/// 36×5 drag indicator. For VoiceOver it is a button that cycles detents or
/// dismisses, with explicit custom actions.
@MainActor
final class RCSheetGrabberView: RCView {
    weak var owner: RCSheetPresentationController?

    override func setUp() {
        isUserInteractionEnabled = false
        layer.cornerRadius = 2.5
        isAccessibilityElement = true
        accessibilityLabel = "Sheet grabber"
        accessibilityTraits = .button
    }

    override func updateAppearance() {
        layer.backgroundColor = RCColor.lineStrong.cgColor(for: self)
    }

    override var accessibilityFrame: CGRect {
        get { UIAccessibility.convertToScreenCoordinates(bounds.insetBy(dx: -40, dy: -14), in: self) }
        set { super.accessibilityFrame = newValue }
    }

    func updateAccessibility() {
        guard let owner else { return }
        let count = owner.detentHeights.count
        let index = owner.selectedIndex
        var actions: [UIAccessibilityCustomAction] = []
        if count > 1, index < count - 1 {
            actions.append(UIAccessibilityCustomAction(name: "Expand", target: self, selector: #selector(expand)))
        }
        if count > 1, index > 0 {
            actions.append(UIAccessibilityCustomAction(name: "Collapse", target: self, selector: #selector(collapse)))
        }
        if owner.isDismissible {
            actions.append(UIAccessibilityCustomAction(name: "Dismiss", target: self, selector: #selector(dismissSheet)))
        }
        accessibilityCustomActions = actions
        if count > 1 {
            accessibilityValue = index == count - 1 ? "Expanded" : "Collapsed"
            accessibilityHint = index == count - 1 ? "Double-tap to collapse." : "Double-tap to expand."
        } else {
            accessibilityValue = nil
            accessibilityHint = owner.isDismissible ? "Double-tap to dismiss." : nil
        }
        isAccessibilityElement = count > 1 || owner.isDismissible
    }

    override func accessibilityActivate() -> Bool {
        guard let owner else { return false }
        let count = owner.detentHeights.count
        if count > 1 {
            owner.selectDetent(at: owner.selectedIndex == count - 1 ? 0 : count - 1, animated: true)
            return true
        }
        guard owner.isDismissible else { return false }
        owner.dismissFromAccessibility()
        return true
    }

    @objc private func expand() -> Bool {
        guard let owner else { return false }
        owner.selectDetent(at: min(owner.selectedIndex + 1, owner.detentHeights.count - 1), animated: true)
        return true
    }

    @objc private func collapse() -> Bool {
        guard let owner else { return false }
        owner.selectDetent(at: max(owner.selectedIndex - 1, 0), animated: true)
        return true
    }

    @objc private func dismissSheet() -> Bool {
        owner?.dismissFromAccessibility()
        return true
    }
}
