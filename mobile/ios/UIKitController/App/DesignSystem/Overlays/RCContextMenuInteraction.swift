import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Long-press context menu with a lifted preview of the pressed view
/// (dimmed backdrop, preview scales up, menu attaches below or above).
///
/// Holding shrinks the view slightly; moving more than 10 pt or a parent
/// scroll view taking the touch cancels cleanly. A completed long press
/// cancels a `UIControl`'s tracking on the same view (no tap fires); a normal
/// tap is untouched. After the lift the same finger can slide into the menu
/// and release over an item. The interaction retains itself on the view it
/// is attached to.
@MainActor
final class RCContextMenuInteraction: NSObject {
    /// Return nil to not show a menu for the current state.
    let provider: @MainActor () -> [RCMenuSection]?
    /// Corner radius of the lifted preview snapshot.
    var previewCornerRadius: CGFloat = RCRadius.lg
    /// Platter behind the snapshot, so views without their own background
    /// lift as a solid card. Nil keeps the snapshot's own transparency.
    var previewBackgroundColor: UIColor? = RCColor.elevated
    /// Called when the menu lifts (e.g. to cancel a pending tap highlight).
    var onWillPresent: (() -> Void)?
    private weak var view: UIView?

    private static var associationKey: UInt8 = 0
    private static let pressedScale: CGFloat = 0.97
    private static let shrinkDelay: TimeInterval = 0.1

    private let press = RCContextPressGestureRecognizer()
    private var pendingSections: [RCMenuSection]?
    private var pressAnimator: UIViewPropertyAnimator?
    private var restingTransform: CGAffineTransform = .identity
    private var isShrunk = false
    private weak var presentation: RCMenuPresentation?
    private lazy var accessibilityAction = UIAccessibilityCustomAction(name: "Show menu", target: self, selector: #selector(performAccessibilityAction))

    init(provider: @escaping @MainActor () -> [RCMenuSection]?) {
        self.provider = provider
        super.init()
    }

    func attach(to view: UIView) {
        RCKeyboardFrameTracker.shared.start()
        if let previous = self.view, previous !== view {
            previous.removeGestureRecognizer(press)
        }
        self.view = view
        press.minimumPressDuration = 0.4
        press.allowableMovement = 10
        press.removeTarget(nil, action: nil)
        press.addTarget(self, action: #selector(handlePress(_:)))
        press.shouldStart = { [weak self] in self?.pressShouldStart() ?? false }
        press.onPossibleEnded = { [weak self] in self?.pressDidEndWithoutLift() }
        view.addGestureRecognizer(press)

        var interactions = objc_getAssociatedObject(view, &Self.associationKey) as? [RCContextMenuInteraction] ?? []
        if !interactions.contains(where: { $0 === self }) {
            interactions.append(self)
            objc_setAssociatedObject(view, &Self.associationKey, interactions, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        var actions = view.accessibilityCustomActions ?? []
        if !actions.contains(accessibilityAction) {
            actions.append(accessibilityAction)
            view.accessibilityCustomActions = actions
        }
    }

    /// Presents the menu without a gesture (VoiceOver action, debug hooks).
    func present() {
        guard let view, view.window != nil, presentation == nil, let sections = provider() else { return }
        lift(view: view, sections: sections)
    }

    // MARK: Gesture

    private func pressShouldStart() -> Bool {
        guard let view, view.window != nil, !RCMenu.isPresented else { return false }
        // A touch that stops a flinging scroll view is not a press.
        var ancestor = view.superview
        while let current = ancestor {
            if let scrollView = current as? UIScrollView, scrollView.isDecelerating || scrollView.isDragging { return false }
            ancestor = current.superview
        }
        guard let sections = provider(), sections.contains(where: { !$0.items.isEmpty }) else { return false }
        pendingSections = sections
        beginShrink(view)
        return true
    }

    @objc private func handlePress(_ gesture: RCContextPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let view, let sections = pendingSections ?? provider() else { return }
            pendingSections = nil
            lift(view: view, sections: sections)
            presentation?.externalTouch(.began, atWindowPoint: gesture.location(in: nil))
        case .changed:
            presentation?.externalTouch(.moved, atWindowPoint: gesture.location(in: nil))
        case .ended:
            presentation?.externalTouch(.ended, atWindowPoint: gesture.location(in: nil))
        case .cancelled, .failed:
            presentation?.externalTouch(.cancelled, atWindowPoint: .zero)
            if presentation == nil { restoreFromShrink(animated: true) }
        default:
            break
        }
    }

    private func pressDidEndWithoutLift() {
        pendingSections = nil
        if presentation == nil { restoreFromShrink(animated: true) }
    }

    @objc private func performAccessibilityAction() -> Bool {
        present()
        return presentation != nil
    }

    // MARK: Press feedback

    private func beginShrink(_ view: UIView) {
        pressAnimator?.stopAnimation(true)
        if !isShrunk { restingTransform = view.transform }
        isShrunk = true
        guard !RCMotion.reduceMotion else { return }
        let target = restingTransform.scaledBy(x: Self.pressedScale, y: Self.pressedScale)
        pressAnimator = RCMotion.animate(RCMotion.smooth, delay: Self.shrinkDelay) {
            view.transform = target
        }
    }

    private func restoreFromShrink(animated: Bool) {
        guard isShrunk, let view else { return }
        isShrunk = false
        pressAnimator?.stopAnimation(true)
        pressAnimator = nil
        let resting = restingTransform
        if animated, !RCMotion.reduceMotion {
            pressAnimator = RCMotion.animate(RCMotion.snappy) { view.transform = resting }
        } else {
            view.transform = resting
        }
    }

    // MARK: Lift

    private func lift(view: UIView, sections: [RCMenuSection]) {
        pressAnimator?.stopAnimation(true)
        pressAnimator = nil
        let transform = view.transform
        let startScale = sqrt(transform.a * transform.a + transform.c * transform.c)
            / max(0.0001, sqrt(restingTransform.a * restingTransform.a + restingTransform.c * restingTransform.c))
        let resting = isShrunk ? restingTransform : view.transform
        isShrunk = false
        onWillPresent?()
        RCHaptics.play(.medium)
        let preview = RCContextMenuPreview(
            source: view,
            cornerRadius: previewCornerRadius,
            backgroundColor: previewBackgroundColor,
            startScale: startScale.isFinite ? startScale : 1,
            restingTransform: resting
        )
        guard let presentation = RCMenuPresentation.present(sections, anchor: view, style: .context(preview)) else {
            view.transform = resting
            return
        }
        self.presentation = presentation
    }
}

/// Long-press recognizer that reports the start of a press (for the shrink
/// feedback) before it recognizes, fails beyond `allowableMovement`, and
/// keeps delivering `.changed` after recognition for press-and-drag.
@MainActor
final class RCContextPressGestureRecognizer: UIGestureRecognizer {
    var minimumPressDuration: TimeInterval = 0.4
    var allowableMovement: CGFloat = 10
    /// Asked on touch down; false fails the press without any feedback.
    var shouldStart: (() -> Bool)?
    /// Called when a press ends before recognition (tap, movement, cancel).
    var onPossibleEnded: (() -> Void)?

    private weak var trackedTouch: UITouch?
    private var startPoint: CGPoint = .zero
    private var didStart = false
    private var timer: Timer?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first else {
            if state == .possible {
                cancelPress()
                state = .failed
            } else {
                touches.forEach { ignore($0, for: event) }
            }
            return
        }
        trackedTouch = touch
        startPoint = touch.location(in: nil)
        guard shouldStart?() ?? true else {
            state = .failed
            return
        }
        didStart = true
        let timer = Timer(timeInterval: minimumPressDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.timerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        switch state {
        case .possible:
            let point = touch.location(in: nil)
            if hypot(point.x - startPoint.x, point.y - startPoint.y) > allowableMovement {
                cancelPress()
                state = .failed
            }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        if state == .possible {
            cancelPress()
            state = .failed
        } else {
            state = .ended
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        if state == .possible {
            cancelPress()
            state = .failed
        } else {
            state = .cancelled
        }
    }

    override func reset() {
        super.reset()
        // Failure caused by another recognizer (a scroll view's pan) lands here.
        if didStart, timer != nil { onPossibleEnded?() }
        timer?.invalidate()
        timer = nil
        trackedTouch = nil
        didStart = false
    }

    private func timerFired() {
        timer = nil
        guard state == .possible, trackedTouch != nil else { return }
        state = .began
    }

    private func cancelPress() {
        guard didStart else { return }
        timer?.invalidate()
        timer = nil
        didStart = false
        onPossibleEnded?()
    }
}

/// Scrim + lifted snapshot of a context menu's source view. The shadow sits
/// on `container` (explicit path), clipping on `clip`; the source view is
/// hidden (alpha) while its snapshot is lifted.
@MainActor
final class RCContextMenuPreview {
    private weak var source: UIView?
    private let cornerRadius: CGFloat
    private let platterColor: UIColor?
    private let startScale: CGFloat
    private let restingTransform: CGAffineTransform
    var targetPlacement: RCContextMenuPlacement?

    let scrim = UIView()
    let container = UIView()
    private let clip = UIView()
    private var sourceAlpha: CGFloat = 1
    private var isSourceHidden = false

    init(source: UIView, cornerRadius: CGFloat, backgroundColor: UIColor?, startScale: CGFloat, restingTransform: CGAffineTransform) {
        self.source = source
        self.cornerRadius = cornerRadius
        platterColor = backgroundColor
        self.startScale = startScale
        self.restingTransform = restingTransform
    }

    /// Source frame without its own (press) transform, in `view` coordinates.
    func sourceRect(in view: UIView) -> CGRect? {
        guard let source, let superview = source.superview, source.window != nil else { return nil }
        let center = superview.convert(source.center, to: view)
        let size = source.bounds.size
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    func install(in overlay: UIView) -> Bool {
        guard let source, let rect = sourceRect(in: overlay) else { return false }
        scrim.frame = overlay.bounds
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrim.backgroundColor = RCColor.scrim
        scrim.alpha = 0
        scrim.isUserInteractionEnabled = false
        overlay.addSubview(scrim)

        container.isUserInteractionEnabled = false
        container.bounds = CGRect(origin: .zero, size: rect.size)
        container.center = CGPoint(x: rect.midX, y: rect.midY)
        container.transform = CGAffineTransform(scaleX: startScale, y: startScale)
        clip.frame = container.bounds
        clip.layer.cornerRadius = min(cornerRadius, min(rect.width, rect.height) / 2)
        clip.layer.cornerCurve = .continuous
        clip.layer.masksToBounds = true
        clip.backgroundColor = platterColor
        container.addSubview(clip)

        let snapshot = source.snapshotView(afterScreenUpdates: false) ?? renderedSnapshot(of: source)
        snapshot.frame = clip.bounds
        clip.addSubview(snapshot)
        overlay.addSubview(container)

        let path = UIBezierPath.continuousRoundedRect(container.bounds, radius: clip.layer.cornerRadius).cgPath
        RCShadow.popover.apply(to: container.layer, path: path, traits: overlay.traitCollection)
        container.layer.shadowOpacity = 0

        sourceAlpha = source.alpha
        source.alpha = 0
        source.transform = restingTransform
        isSourceHidden = true
        return true
    }

    private func renderedSnapshot(of view: UIView) -> UIView {
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.window?.screen.scale ?? UIScreen.main.scale
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        return UIImageView(image: image)
    }

    /// Scrim in, preview springs to its lifted frame with the popover shadow.
    func lift() -> [UIViewPropertyAnimator] {
        guard let target = targetPlacement else { return [] }
        let reduceMotion = RCMotion.reduceMotion
        let scale = reduceMotion ? min(1, target.previewScale) : target.previewScale
        let center = CGPoint(x: target.previewFrame.midX, y: target.previewFrame.midY)
        let container = container
        let scrim = scrim
        let shadow = container.traitCollection.userInterfaceStyle == .dark ? RCShadow.popover.opacityDark : RCShadow.popover.opacityLight
        animateShadow(to: shadow, duration: 0.24)
        let spring = RCMotion.animate(RCMotion.snappy) {
            container.center = center
            container.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        let fade = RCMotion.animate(duration: 0.22, curve: RCMotion.easeOut) {
            scrim.alpha = 1
        }
        return [spring, fade]
    }

    /// Scrim out, preview springs back over the source (or fades if the
    /// source left the window).
    func returnToSource(in overlay: UIView, completion: @escaping @MainActor () -> Void) -> [UIViewPropertyAnimator] {
        let container = container
        let scrim = scrim
        animateShadow(to: 0, duration: 0.2)
        let fade = RCMotion.animate(duration: 0.2, curve: RCMotion.easeOut) {
            scrim.alpha = 0
        }
        let move: UIViewPropertyAnimator
        if let rect = sourceRect(in: overlay) {
            move = RCMotion.animate(RCMotion.snappy, animations: {
                container.center = CGPoint(x: rect.midX, y: rect.midY)
                container.transform = .identity
            }, completion: { _ in completion() })
        } else {
            move = RCMotion.animate(duration: 0.16, curve: RCMotion.easeIn, animations: {
                container.alpha = 0
            }, completion: { _ in completion() })
        }
        return [fade, move]
    }

    func restoreSource() {
        guard isSourceHidden else { return }
        isSourceHidden = false
        source?.alpha = sourceAlpha
    }

    private func animateShadow(to opacity: Float, duration: CFTimeInterval) {
        let layer = container.layer
        let from = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
        layer.shadowOpacity = opacity
        let animation = CABasicAnimation(keyPath: "shadowOpacity")
        animation.fromValue = from
        animation.toValue = opacity
        animation.duration = RCMotion.reduceMotion ? RCMotion.reducedDuration : duration
        animation.timingFunction = RCMotion.easeOut
        layer.add(animation, forKey: "rc.preview.shadowOpacity")
    }
}
