import UIKit
import UIKit.UIGestureRecognizerSubclass

/// One visible menu: a full-window overlay view added to the anchor's window
/// (no view-controller presentation), the panel, and — for context menus —
/// the scrim and lifted preview.
///
/// Lifecycle: `opening` → `open` → `dismissing` → `finished`. At most one
/// presentation exists (`current`); presenting another finishes the previous
/// one first. A selected item's action runs from `finish()`, after the
/// overlay has left the window, so pushes and sheets never fight the menu.
///
/// Automatic dismissal: container size change (rotation, split view),
/// content-size-category change, app backgrounding, keyboard frame change,
/// the anchor leaving the window (observed by a hidden sentinel subview), and
/// `RCMenu.dismissAll`.
@MainActor
final class RCMenuPresentation: NSObject {
    enum Style {
        case dropdown(direction: RCMenu.Direction, alignment: RCMenu.Alignment)
        case context(RCContextMenuPreview)
    }

    enum Phase: Equatable { case opening, open, dismissing, finished }
    enum TouchPhase { case began, moved, ended, cancelled }

    static let dismissDuration: TimeInterval = 0.14
    static let flashDelay: TimeInterval = 0.07

    private(set) static var current: RCMenuPresentation?

    private(set) weak var anchor: UIView?
    let style: Style
    let overlay: RCMenuOverlayView
    let panel: RCMenuPanelView
    private(set) var phase: Phase = .opening
    private(set) var placement: RCMenuPlacement?
    /// True once an item was chosen; its action runs when the menu is gone.
    private(set) var hasCommitted = false

    var isOpen: Bool { phase == .opening || phase == .open }
    /// Called after the overlay is removed and before the item action runs.
    var onFinish: (() -> Void)?

    private weak var window: UIWindow?
    private var limits: CGRect = .zero
    private var pendingAction: (@MainActor () -> Void)?
    private var animators: [UIViewPropertyAnimator] = []
    private var observers: [NSObjectProtocol] = []
    private var sentinel: RCMenuWindowSentinel?
    private var touchStartedInPanel = false
    private var scrollInterrupted = false

    // MARK: Presenting

    @discardableResult
    static func present(_ sections: [RCMenuSection], anchor: UIView, style: Style) -> RCMenuPresentation? {
        RCKeyboardFrameTracker.shared.start()
        let visible = sections.filter { !$0.items.isEmpty }
        guard !visible.isEmpty, anchor.window != nil else { return nil }
        // Finishing may run a committed action, which may present again.
        while let previous = current { previous.finishImmediately() }
        guard let window = anchor.window else { return nil }
        let presentation = RCMenuPresentation(sections: visible, anchor: anchor, style: style, window: window)
        current = presentation
        presentation.show()
        return presentation
    }

    private init(sections: [RCMenuSection], anchor: UIView, style: Style, window: UIWindow) {
        self.anchor = anchor
        self.style = style
        self.window = window
        overlay = RCMenuOverlayView(frame: window.bounds)
        panel = RCMenuPanelView(sections: sections)
        super.init()
    }

    private func show() {
        guard let window, let anchor else { return finish() }
        overlay.presentation = self
        overlay.overrideUserInterfaceStyle = anchor.traitCollection.userInterfaceStyle
        overlay.semanticContentAttribute = anchor.effectiveUserInterfaceLayoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        window.addSubview(overlay)
        overlay.presentedSize = overlay.bounds.size

        if case let .context(preview) = style {
            guard preview.install(in: overlay) else { return finish() }
        }
        panel.onActivate = { [weak self] row in self?.activate(row) }
        panel.onEscape = { [weak self] in self?.dismiss(animated: true) }
        overlay.addSubview(panel)
        overlay.panel = panel

        guard let placement = place() else { return finish() }
        self.placement = placement
        apply(placement)
        installObservers(anchor: anchor)
        animateIn(placement)

        if UIAccessibility.isVoiceOverRunning, let first = panel.currentPage?.firstAccessibleRow {
            UIAccessibility.post(notification: .screenChanged, argument: first)
        }
    }

    private func environment() -> RCMenuLayout.Environment {
        let bounds = overlay.bounds
        let insets = window?.safeAreaInsets ?? .zero
        return RCMenuLayout.Environment(
            bounds: bounds,
            safeArea: bounds.inset(by: insets),
            keyboard: RCKeyboardFrameTracker.shared.frame(in: overlay),
            isRightToLeft: overlay.effectiveUserInterfaceLayoutDirection == .rightToLeft
        )
    }

    private func place() -> RCMenuPlacement? {
        guard let anchor, let page = panel.currentPage else { return nil }
        let environment = environment()
        limits = RCMenuLayout.limits(in: environment)
        let naturalWidth = RCMenuPanelView.naturalWidth(for: panel.rootSections, traits: overlay.traitCollection)
        switch style {
        case let .dropdown(direction, alignment):
            let anchorRect = anchor.convert(anchor.bounds, to: overlay)
            let width = RCMenuLayout.panelWidth(contentWidth: naturalWidth, anchorWidth: anchorRect.width, available: limits.width, metrics: environment.metrics)
            let size = CGSize(width: naturalWidth, height: page.contentHeight(for: width))
            return RCMenuLayout.place(contentSize: size, anchor: anchorRect, direction: direction, alignment: alignment, in: environment)
        case let .context(preview):
            guard let source = preview.sourceRect(in: overlay) else { return nil }
            let width = RCMenuLayout.panelWidth(contentWidth: naturalWidth, anchorWidth: nil, available: limits.width, metrics: environment.metrics)
            let size = CGSize(width: naturalWidth, height: page.contentHeight(for: width))
            let context = RCMenuLayout.placeContextMenu(contentSize: size, source: source, in: environment)
            preview.targetPlacement = context
            return context.menu
        }
    }

    private func apply(_ placement: RCMenuPlacement) {
        let frame = RCLayout.pixelAligned(placement.frame)
        withoutImplicitAnimations {
            panel.layer.anchorPoint = placement.transformOrigin
            panel.bounds = CGRect(origin: .zero, size: frame.size)
            panel.center = CGPoint(
                x: frame.minX + placement.transformOrigin.x * frame.width,
                y: frame.minY + placement.transformOrigin.y * frame.height
            )
            panel.layoutIfNeeded()
        }
        if placement.scrolls {
            panel.currentPage?.flashScrollIndicators()
        }
    }

    private func animateIn(_ placement: RCMenuPlacement) {
        let reduceMotion = RCMotion.reduceMotion
        let delay: TimeInterval
        if case let .context(preview) = style {
            animators += preview.lift()
            delay = reduceMotion ? 0 : 0.03
        } else {
            delay = 0
        }
        panel.alpha = 0
        if !reduceMotion {
            let lift: CGFloat = placement.edge == .below ? -6 : 6
            panel.transform = CGAffineTransform(translationX: 0, y: lift).scaledBy(x: 0.92, y: 0.92)
        }
        let spring = RCMotion.animate(RCMotion.snappy, delay: delay, animations: { [panel] in
            panel.transform = .identity
        }, completion: { [weak self] _ in
            guard let self, self.phase == .opening else { return }
            self.phase = .open
        })
        let fade = RCMotion.animate(duration: 0.12, curve: RCMotion.easeOut, delay: delay) { [panel] in
            panel.alpha = 1
        }
        animators += [spring, fade]
    }

    // MARK: Dismissing

    /// Starts the exit motion. Idempotent; a non-animated call during an
    /// animated exit completes it immediately.
    func dismiss(animated: Bool) {
        switch phase {
        case .finished:
            return
        case .dismissing:
            if !animated { finish() }
            return
        case .opening, .open:
            break
        }
        phase = .dismissing
        overlay.isUserInteractionEnabled = false
        panel.setHighlighted(hasCommitted ? panel.highlightedRow : nil)
        removeObservers()
        guard animated, overlay.window != nil else { return finish() }
        stopAnimators()

        let reduceMotion = RCMotion.reduceMotion
        var pending = 1
        let done = { [weak self] in
            pending -= 1
            if pending == 0 { self?.finish() }
        }
        let edge = placement?.edge ?? .below
        let exit = RCMotion.animate(duration: Self.dismissDuration, curve: RCMotion.easeIn, animations: { [panel] in
            panel.alpha = 0
            if !reduceMotion {
                panel.transform = CGAffineTransform(translationX: 0, y: edge == .below ? -4 : 4).scaledBy(x: 0.96, y: 0.96)
            }
        }, completion: { _ in done() })
        animators.append(exit)
        if case let .context(preview) = style {
            pending += 1
            animators += preview.returnToSource(in: overlay) { done() }
        }
    }

    /// Ends the presentation now (no motion), running a committed action.
    func finishImmediately() {
        finish()
    }

    private func finish() {
        guard phase != .finished else { return }
        phase = .finished
        removeObservers()
        stopAnimators()
        if case let .context(preview) = style { preview.restoreSource() }
        overlay.removeFromSuperview()
        overlay.presentation = nil
        if Self.current === self { Self.current = nil }
        let action = pendingAction
        pendingAction = nil
        onFinish?()
        onFinish = nil
        // Focus returns to the anchor; an action that navigates moves it again.
        if UIAccessibility.isVoiceOverRunning, let anchor, anchor.window != nil {
            UIAccessibility.post(notification: .screenChanged, argument: anchor)
        }
        action?()
    }

    private func stopAnimators() {
        for animator in animators where animator.state == .active {
            animator.stopAnimation(true)
        }
        animators.removeAll()
    }

    // MARK: Selection

    func activate(_ row: RCMenuRowView) {
        guard isOpen, !hasCommitted, !panel.isTransitioning, row.isEnabled else { return }
        if row.isBack {
            navigateBack()
            return
        }
        guard let item = row.item else { return }
        if !item.children.isEmpty {
            navigate(into: row, item: item)
            return
        }
        hasCommitted = true
        pendingAction = item.action
        panel.setHighlighted(row)
        row.flash()
        overlay.isUserInteractionEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashDelay) { [weak self] in
            MainActor.assumeIsolated { self?.dismiss(animated: true) }
        }
    }

    private func navigate(into row: RCMenuRowView, item: RCMenuItem) {
        let page = row.childPage ?? RCMenuPageView(sections: item.children.filter { !$0.items.isEmpty }, backTitle: item.title)
        row.childPage = page
        transition(to: page, forward: true)
        announce("\(item.title), submenu")
    }

    private func navigateBack() {
        guard panel.pages.count > 1 else { return }
        let target = panel.pages[panel.pages.count - 2]
        transition(to: target, forward: false)
        announce(target.backTitle.map { "\($0), submenu" } ?? "Menu")
    }

    private func transition(to page: RCMenuPageView, forward: Bool) {
        guard let outgoing = panel.currentPage, let placement else { return }
        panel.setHighlighted(nil)
        let width = panel.bounds.width
        let frame = panel.convert(panel.bounds, to: overlay)
        let available = placement.edge == .below
            ? min(placement.maximumHeight, limits.maxY - frame.minY)
            : min(placement.maximumHeight, frame.maxY - limits.minY)
        let height = RCLayout.pixelAligned(min(page.contentHeight(for: width), max(available, 0)))

        if forward {
            panel.push(page)
        } else {
            panel.popPage()
        }
        let isRightToLeft = overlay.effectiveUserInterfaceLayoutDirection == .rightToLeft
        // +1 = content moves toward the leading edge (entering a submenu).
        let direction: CGFloat = (forward ? 1 : -1) * (isRightToLeft ? -1 : 1)
        let reduceMotion = RCMotion.reduceMotion
        // Push: the child slides in over the parent, which recedes with parallax.
        // Pop: the child slides back out, the parent returns from its parallax offset.
        let incomingStart = reduceMotion ? 0 : (forward ? direction * width : direction * width * 0.3)
        let outgoingEnd = reduceMotion ? 0 : (forward ? -direction * width * 0.3 : -direction * width)
        panel.isTransitioning = true
        withoutImplicitAnimations {
            page.isHidden = false
            page.frame = CGRect(x: incomingStart, y: 0, width: width, height: height)
            page.contentOffset = .zero
            page.alpha = forward && !reduceMotion ? 1 : 0
            page.layoutIfNeeded()
        }
        if forward {
            panel.clipView.bringSubviewToFront(page)
        } else {
            panel.clipView.bringSubviewToFront(outgoing)
        }

        let oldBounds = panel.bounds
        let animator = RCMotion.animate(RCMotion.snappy, animations: { [panel] in
            panel.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            panel.clipView.frame = CGRect(x: 0, y: 0, width: width, height: height)
            page.frame.origin.x = 0
            page.alpha = 1
            outgoing.frame.origin.x = outgoingEnd
            if forward || reduceMotion { outgoing.alpha = 0 }
        }, completion: { [weak self, panel] _ in
            outgoing.alpha = 1
            if !panel.pages.contains(where: { $0 === outgoing }) {
                outgoing.removeFromSuperview()
            } else {
                outgoing.isHidden = true
            }
            page.isHidden = false
            panel.isTransitioning = false
            panel.setNeedsLayout()
            guard let self, self.isOpen else { return }
            if UIAccessibility.isVoiceOverRunning, let first = page.firstAccessibleRow {
                UIAccessibility.post(notification: .layoutChanged, argument: first)
            }
        })
        animators.append(animator)
        animateShadow(from: oldBounds)
    }

    private func animateShadow(from oldBounds: CGRect) {
        let oldPath = UIBezierPath.continuousRoundedRect(oldBounds, radius: RCMenuPanelView.cornerRadius).cgPath
        withoutImplicitAnimations { panel.updateShadow() }
        guard let newPath = panel.layer.shadowPath, !RCMotion.reduceMotion else { return }
        let animation = RCMotion.caSpring(keyPath: "shadowPath", spring: RCMotion.snappy)
        animation.fromValue = oldPath
        animation.toValue = newPath
        panel.layer.add(animation, forKey: "rc.menu.shadowPath")
    }

    private func announce(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let message = NSAttributedString(string: text, attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    // MARK: Touch routing

    /// Touches that landed on the overlay (outside taps, panel rows).
    func overlayTouch(_ phase: TouchPhase, at point: CGPoint) {
        switch phase {
        case .began:
            guard isOpen, !hasCommitted else { return }
            let local = overlay.convert(point, to: panel)
            if panel.bounds.contains(local) {
                touchStartedInPanel = true
                scrollInterrupted = panel.currentPage?.isDecelerating ?? false
                RCHaptics.prepare(.selection)
                if !scrollInterrupted { updateHighlight(at: point, haptic: false) }
            } else {
                touchStartedInPanel = false
                dismiss(animated: true)
            }
        case .moved:
            guard touchStartedInPanel, isOpen, !hasCommitted else { return }
            if let page = panel.currentPage, page.isDragging || page.isDecelerating {
                scrollInterrupted = true
                panel.setHighlighted(nil)
            }
            guard !scrollInterrupted else { return }
            updateHighlight(at: point, haptic: true)
        case .ended:
            guard touchStartedInPanel, isOpen, !hasCommitted else { return }
            touchStartedInPanel = false
            if !scrollInterrupted, let row = panel.row(at: overlay.convert(point, to: panel)), row.isEnabled {
                activate(row)
            } else {
                panel.setHighlighted(nil)
            }
        case .cancelled:
            touchStartedInPanel = false
            panel.setHighlighted(nil)
        }
    }

    /// A touch owned by another view (the attached control or the long-pressed
    /// view) that continues into the menu. `travelled` on `.ended` closes the
    /// menu when the finger is released away from any item.
    func externalTouch(_ phase: TouchPhase, atWindowPoint windowPoint: CGPoint, travelled: Bool = false) {
        guard isOpen, !hasCommitted else { return }
        let point = overlay.convert(windowPoint, from: nil)
        switch phase {
        case .began:
            RCHaptics.prepare(.selection)
        case .moved:
            updateHighlight(at: point, haptic: true)
        case .ended:
            if let row = panel.row(at: overlay.convert(point, to: panel)), row.isEnabled {
                activate(row)
            } else {
                panel.setHighlighted(nil)
                if travelled { dismiss(animated: true) }
            }
        case .cancelled:
            panel.setHighlighted(nil)
        }
    }

    private func updateHighlight(at point: CGPoint, haptic: Bool) {
        let candidate = panel.row(at: overlay.convert(point, to: panel))
        let row = candidate?.isEnabled == true ? candidate : nil
        guard row !== panel.highlightedRow else { return }
        panel.setHighlighted(row)
        if haptic, row != nil { RCHaptics.play(.selection) }
    }

    // MARK: Automatic dismissal

    private func installObservers(anchor: UIView) {
        let center = NotificationCenter.default
        let dismissNow: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(animated: false) }
        }
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: dismissNow))
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] notification in
            let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { self?.keyboardWillChange(toScreenFrame: frame) }
        })

        let sentinel = RCMenuWindowSentinel()
        let host = (anchor as? UIVisualEffectView)?.contentView ?? anchor
        host.addSubview(sentinel)
        sentinel.onWindowChange = { [weak self, weak sentinel] in
            guard let self, let sentinel, sentinel.window !== self.window else { return }
            self.dismissSoon()
        }
        self.sentinel = sentinel
        overlay.onContainerChange = { [weak self] in self?.dismissSoon() }
    }

    /// Dismisses only when the keyboard change affects where the menu may sit
    /// (iPad shortcut bars and offscreen frames produce no-op notifications).
    private func keyboardWillChange(toScreenFrame screenFrame: CGRect?) {
        guard let window else { return }
        var environment = environment()
        environment.keyboard = screenFrame.map { overlay.convert(window.convert($0, from: window.screen.coordinateSpace), from: window) }
        let updated = RCMenuLayout.limits(in: environment)
        if abs(updated.maxY - limits.maxY) > 1 { dismiss(animated: true) }
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        overlay.onContainerChange = nil
        sentinel?.onWindowChange = nil
        sentinel?.removeFromSuperview()
        sentinel = nil
    }

    /// Defers dismissal out of layout / hierarchy callbacks.
    private func dismissSoon() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.dismiss(animated: false) }
        }
    }

    // MARK: Utilities

    static func isInsideScrollableContainer(_ view: UIView) -> Bool {
        var next = view.superview
        while let current = next {
            if let scrollView = current as? UIScrollView, scrollView.isScrollEnabled, scrollView.panGestureRecognizer.isEnabled {
                let visible = scrollView.bounds.inset(by: scrollView.adjustedContentInset).size
                if scrollView.alwaysBounceVertical || scrollView.alwaysBounceHorizontal
                    || scrollView.contentSize.height > visible.height + 0.5
                    || scrollView.contentSize.width > visible.width + 0.5 {
                    return true
                }
            }
            next = current.superview
        }
        return false
    }

    /// Cancels in-flight scroll recognition in ancestors so the finger that
    /// now drives a menu cannot also scroll the content beneath it.
    static func resetScrollGestures(around view: UIView) {
        var next = view.superview
        while let current = next {
            if let scrollView = current as? UIScrollView, scrollView.panGestureRecognizer.isEnabled {
                scrollView.panGestureRecognizer.isEnabled = false
                scrollView.panGestureRecognizer.isEnabled = true
            }
            next = current.superview
        }
    }
}

extension RCMenuPanelView {
    /// Sections of the root page, kept for width measurement.
    var rootSections: [RCMenuSection] { pages.first?.sections ?? [] }
}

/// Full-window container of a presentation. Touches that miss the panel land
/// here (outside tap → dismiss); a tracking recognizer routes every touch,
/// including ones over panel rows, to the presentation for press-and-drag.
@MainActor
final class RCMenuOverlayView: UIView, UIGestureRecognizerDelegate {
    weak var presentation: RCMenuPresentation?
    weak var panel: RCMenuPanelView?
    var presentedSize: CGSize = .zero
    var onContainerChange: (() -> Void)?

    private let tracker = RCMenuTouchTracker()
    private lazy var dismissElement: RCMenuDismissElement = {
        let element = RCMenuDismissElement(accessibilityContainer: self)
        element.accessibilityLabel = "Dismiss menu"
        element.accessibilityTraits = .button
        element.onActivate = { [weak self] in self?.presentation?.dismiss(animated: true) }
        return element
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear
        accessibilityViewIsModal = true
        tracker.cancelsTouchesInView = false
        tracker.delaysTouchesEnded = false
        tracker.delegate = self
        tracker.handler = { [weak self] phase, point in
            self?.presentation?.overlayTouch(phase, at: point)
        }
        addGestureRecognizer(tracker)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if presentedSize != .zero, bounds.size != presentedSize {
            onContainerChange?()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if let previousTraitCollection,
           previousTraitCollection.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection.horizontalSizeClass != traitCollection.horizontalSizeClass {
            onContainerChange?()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        presentation?.dismiss(animated: true)
        return true
    }

    override var accessibilityElements: [Any]? {
        get {
            dismissElement.accessibilityFrameInContainerSpace = bounds
            guard let panel else { return [dismissElement] }
            return [panel, dismissElement]
        }
        set {}
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

/// Invisible full-screen "Dismiss menu" element for VoiceOver.
@MainActor
final class RCMenuDismissElement: UIAccessibilityElement {
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return true
    }
}

/// Continuous single-touch tracker that never blocks other recognizers or
/// the views beneath (scrolling inside the panel keeps working).
@MainActor
final class RCMenuTouchTracker: UIGestureRecognizer {
    var handler: ((RCMenuPresentation.TouchPhase, CGPoint) -> Void)?
    private weak var trackedTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, let touch = touches.first else {
            touches.forEach { ignore($0, for: event) }
            return
        }
        trackedTouch = touch
        state = .began
        handler?(.began, touch.location(in: view))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        state = .changed
        handler?(.moved, touch.location(in: view))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        handler?(.ended, touch.location(in: view))
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        handler?(.cancelled, touch.location(in: view))
        state = .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
    }
}

/// Hidden zero-size subview of the anchor: its `didMoveToWindow` fires when
/// the anchor (or any ancestor) leaves the window, without polling.
@MainActor
final class RCMenuWindowSentinel: UIView {
    var onWindowChange: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
}

/// Last known keyboard frame (screen coordinates). Started lazily by the
/// first menu attachment or presentation.
@MainActor
final class RCKeyboardFrameTracker {
    static let shared = RCKeyboardFrameTracker()
    private(set) var frameInScreen: CGRect?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] notification in
            let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { self?.frameInScreen = frame }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.frameInScreen = nil }
        })
    }

    /// Keyboard frame in `view`'s coordinates, or nil when hidden/unknown.
    func frame(in view: UIView) -> CGRect? {
        guard let frame = frameInScreen, !frame.isEmpty, let window = view.window else { return nil }
        let inWindow = window.convert(frame, from: window.screen.coordinateSpace)
        return view.convert(inWindow, from: window)
    }

    /// Test hook: overrides the stored frame.
    func setFrameForTesting(_ frame: CGRect?) {
        frameInScreen = frame
    }
}
