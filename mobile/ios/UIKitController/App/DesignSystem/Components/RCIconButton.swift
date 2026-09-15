import UIKit

/// Square or circular icon-only button. Always provide an accessibility label.
///
/// The visual body can be smaller than 44 pt; the hit area never is. Press
/// feedback (spring to 0.92 plus a state overlay) and selection changes run on
/// the body view and animate from whatever is on screen, so rapid toggles stay
/// continuous. `isSpinning` rotates the glyph on the render server, pauses
/// off-window, resumes in phase and eases to rest when it stops.
@MainActor
final class RCIconButton: RCControl {
    enum Variant: Sendable {
        /// Elevated surface with hairline border (default toolbar button).
        case plain
        /// Filled with `text` color.
        case primary
        /// Filled accent.
        case accent
        /// No chrome, wash on press.
        case ghost
        /// Translucent white on the black stage (camera, video chrome).
        case overlay
        /// Solid white on the stage with a black glyph (active/prominent state).
        case overlayProminent
        /// Console-styled raised button for the remote dock (always dark tokens).
        case stage
    }

    enum Shape: Sendable { case circle, rounded }

    var icon: RCIconGlyph {
        didSet { if icon != oldValue { iconView.setGlyph(icon, animated: false) } }
    }

    var variant: Variant {
        didSet { if variant != oldValue { applyColors(animated: false) } }
    }

    var shape: Shape {
        didSet { if shape != oldValue { setNeedsLayout() } }
    }

    var diameter: CGFloat {
        didSet { if diameter != oldValue { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    }

    /// Glyph point size.
    var iconSize: CGFloat {
        get { iconView.pointSize }
        set { iconView.pointSize = newValue }
    }

    /// Continuous rotation of the glyph (e.g. refresh in progress).
    var isSpinning = false {
        didSet {
            guard isSpinning != oldValue else { return }
            updateSpinning(stopping: !isSpinning)
            updateRasterization()
        }
    }

    var onTap: (() -> Void)?
    var haptic: RCHaptics.Kind? = .light

    private let body = UIView()
    private let pressOverlay = UIView()
    private let iconView: RCIconView
    private var lastActionTimestamp: TimeInterval = -1

    private static let spinKey = "rc.iconButton.spin"
    private static let settleKey = "rc.iconButton.settle"

    init(icon: RCIconGlyph, variant: Variant = .plain, shape: Shape = .circle, diameter: CGFloat = 40, iconSize: CGFloat = 18, accessibilityLabel: String) {
        self.icon = icon
        self.variant = variant
        self.shape = shape
        self.diameter = diameter
        iconView = RCIconView(icon, pointSize: iconSize)
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        body.addSubview(iconView)
        self.accessibilityLabel = accessibilityLabel
        applyColors(animated: false)
    }

    override func setUp() {
        isAccessibilityElement = true
        accessibilityTraits = .button
        body.isUserInteractionEnabled = false
        pressOverlay.isUserInteractionEnabled = false
        pressOverlay.alpha = 0
        body.addSubview(pressOverlay)
        addSubview(body)
        addTarget(self, action: #selector(handleAction(_:event:)), for: [.touchUpInside, .primaryActionTriggered])
        if #available(iOS 13.4, *) {
            addInteraction(UIPointerInteraction(delegate: self))
        }
    }

    // MARK: Accessibility

    override var accessibilityTraits: UIAccessibilityTraits {
        get {
            var traits = super.accessibilityTraits.union(.button)
            if isSelected { traits.insert(.selected) }
            if !isEnabled { traits.insert(.notEnabled) }
            return traits
        }
        set { super.accessibilityTraits = newValue }
    }

    override var accessibilityValue: String? {
        get { super.accessibilityValue ?? (isSpinning ? "In progress" : nil) }
        set { super.accessibilityValue = newValue }
    }

    // MARK: State

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            let pressed = isHighlighted && isEnabled
            let reduceMotion = RCMotion.reduceMotion
            RCMotion.animate(pressed ? RCMotion.snappy : RCMotion.bouncy) {
                self.body.transform = pressed && !reduceMotion ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
            }
            RCMotion.animate(duration: pressed ? RCMotion.pressDuration : RCMotion.releaseDuration) {
                self.pressOverlay.alpha = pressed ? 1 : 0
            }
        }
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            let alpha: CGFloat = isEnabled ? 1 : 0.45
            if window != nil {
                RCMotion.animate(duration: RCMotion.quickDuration) { self.body.alpha = alpha }
            } else {
                body.alpha = alpha
            }
            updateRasterization()
        }
    }

    /// A disabled, still button is flattened once instead of compositing its
    /// group opacity offscreen every frame it moves.
    private func updateRasterization() {
        let rasterize = !isEnabled && !isSpinning
        body.layer.shouldRasterize = rasterize
        if rasterize { body.layer.rasterizationScale = window?.screen.scale ?? UIScreen.main.scale }
    }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            applyColors(animated: window != nil)
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if let haptic { RCHaptics.prepare(haptic) }
        return super.beginTracking(touch, with: event)
    }

    @objc private func handleAction(_ sender: Any?, event: UIEvent?) {
        if let event {
            guard event.timestamp != lastActionTimestamp else { return }
            lastActionTimestamp = event.timestamp
        }
        guard isEnabled else { return }
        if let haptic { RCHaptics.play(haptic) }
        onTap?()
    }

    // MARK: Colors

    private struct Palette {
        let fill: UIColor?
        let border: UIColor?
        let tint: UIColor
        let press: UIColor
    }

    private var palette: Palette {
        let onStage = RCColor.onStage
        switch variant {
        case .plain:
            return isSelected
                ? Palette(fill: RCColor.text, border: nil, tint: RCColor.onPrimary, press: Self.alpha(RCColor.onPrimary, 0.14))
                : Palette(fill: RCColor.elevated, border: RCColor.line, tint: RCColor.text, press: RCColor.pressWash)
        case .primary:
            return Palette(fill: RCColor.text, border: nil, tint: RCColor.onPrimary, press: Self.alpha(RCColor.onPrimary, 0.14))
        case .accent:
            return Palette(fill: RCColor.accent, border: nil, tint: RCColor.onAccent, press: Self.alpha(RCColor.onAccent, 0.14))
        case .ghost:
            return isSelected
                ? Palette(fill: RCColor.accentSoft, border: nil, tint: RCColor.accent, press: RCColor.pressWash)
                : Palette(fill: nil, border: nil, tint: RCColor.textSecondary, press: RCColor.pressWash)
        case .overlay:
            return isSelected
                ? Palette(fill: onStage, border: nil, tint: RCColor.stage, press: Self.alpha(RCColor.stage, 0.12))
                : Palette(fill: onStage.withAlphaComponent(0.16), border: onStage.withAlphaComponent(0.2), tint: onStage, press: onStage.withAlphaComponent(0.14))
        case .overlayProminent:
            return Palette(fill: onStage, border: nil, tint: RCColor.stage, press: Self.alpha(RCColor.stage, 0.12))
        case .stage:
            return isSelected
                ? Palette(fill: RCColor.accent, border: nil, tint: RCColor.onAccent, press: Self.alpha(RCColor.onAccent, 0.14))
                : Palette(fill: RCColor.elevated, border: RCColor.line, tint: RCColor.text, press: RCColor.pressWash)
        }
    }

    private static func alpha(_ color: UIColor, _ alpha: CGFloat) -> UIColor {
        UIColor { color.resolvedColor(with: $0).withAlphaComponent(alpha) }
    }

    /// `.stage` always uses Console tokens, whatever the surrounding appearance.
    private var colorTraits: UITraitCollection {
        guard variant == .stage else { return traitCollection }
        return UITraitCollection(traitsFrom: [traitCollection, UITraitCollection(userInterfaceStyle: .dark)])
    }

    override func updateAppearance() {
        applyColors(animated: false)
    }

    private func applyColors(animated: Bool) {
        let palette = palette
        let traits = colorTraits
        let duration = animated ? RCMotion.quickDuration : 0
        RCLayerAnimation.set(body.layer, "backgroundColor", to: palette.fill?.resolvedColor(with: traits).cgColor, duration: duration)
        RCLayerAnimation.set(body.layer, "borderColor", to: palette.border?.resolvedColor(with: traits).cgColor, duration: duration)
        withoutImplicitAnimations {
            body.layer.borderWidth = palette.border == nil ? 0 : 1
            pressOverlay.layer.backgroundColor = palette.press.resolvedColor(with: traits).cgColor
        }
        let tint = palette.tint.resolvedColor(with: traits)
        if animated, let shape = iconView.layer as? CAShapeLayer {
            let from = (shape.presentation() ?? shape).strokeColor
            iconView.tintColor = tint
            let fade = CABasicAnimation(keyPath: "strokeColor")
            fade.fromValue = from
            fade.toValue = shape.strokeColor
            fade.duration = duration
            fade.timingFunction = RCMotion.easeOut
            shape.add(fade, forKey: "rc.iconButton.tint")
        } else {
            iconView.tintColor = tint
        }
    }

    // MARK: Layout

    override var intrinsicContentSize: CGSize { CGSize(width: diameter, height: diameter) }

    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        body.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        body.center = CGPoint(x: RCLayout.pixelAligned(bounds.midX), y: RCLayout.pixelAligned(bounds.midY))
        let radius = shape == .circle ? side / 2 : min(RCRadius.md, side / 2)
        withoutImplicitAnimations {
            body.layer.cornerRadius = radius
            body.layer.cornerCurve = shape == .circle ? .circular : .continuous
            pressOverlay.layer.cornerRadius = radius
            pressOverlay.layer.cornerCurve = body.layer.cornerCurve
        }
        pressOverlay.frame = body.bounds
        iconView.frame = body.bounds
    }

    // MARK: Spinning

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateSpinning(stopping: false)
        updateRasterization()
    }

#if DEBUG
    var hasSpinAnimation: Bool { iconView.layer.animation(forKey: Self.spinKey) != nil }
#endif

    private func updateSpinning(stopping: Bool) {
        let layer = iconView.layer
        guard isSpinning, window != nil else {
            if stopping, window != nil, !RCMotion.reduceMotion, layer.animation(forKey: Self.spinKey) != nil {
                settleRotation(of: layer)
            }
            layer.removeAnimation(forKey: Self.spinKey)
            return
        }
        guard layer.animation(forKey: Self.spinKey) == nil else { return }
        layer.removeAnimation(forKey: Self.settleKey)
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = RCMotion.reduceMotion ? 2 : 0.9
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        rotation.beginTime = RCLayerAnimation.alignedBeginTime(period: rotation.duration, in: layer)
        layer.add(rotation, forKey: Self.spinKey)
    }

    /// Finishes the current turn with an ease-out instead of snapping upright.
    private func settleRotation(of layer: CALayer) {
        guard let angle = layer.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat else { return }
        let current = angle < 0 ? angle + .pi * 2 : angle
        let remaining = .pi * 2 - current
        guard remaining > 0.05 else { return }
        let settle = CABasicAnimation(keyPath: "transform.rotation.z")
        settle.fromValue = current
        settle.toValue = CGFloat.pi * 2
        settle.duration = max(0.18, 0.9 * Double(remaining / (.pi * 2)) * 1.6)
        settle.timingFunction = RCMotion.easeOut
        layer.add(settle, forKey: Self.settleKey)
    }
}

@available(iOS 13.4, *)
extension RCIconButton: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard isEnabled else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: body.bounds, cornerRadius: body.layer.cornerRadius)
        let preview = UITargetedPreview(view: body, parameters: parameters)
        return UIPointerStyle(effect: variant == .ghost ? .highlight(preview) : .lift(preview))
    }
}
