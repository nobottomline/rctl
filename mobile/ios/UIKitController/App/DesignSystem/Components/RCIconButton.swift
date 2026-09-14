import UIKit

/// Square or circular icon-only button. Always provide an accessibility label.
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

    var icon: RCIconGlyph { didSet { iconView.setGlyph(icon, animated: false) } }
    var variant: Variant { didSet { updateAppearance() } }
    var shape: Shape { didSet { setNeedsLayout() } }
    var diameter: CGFloat { didSet { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    /// Continuous rotation of the glyph (e.g. refresh in progress).
    var isSpinning = false { didSet { updateSpinning() } }
    var onTap: (() -> Void)?
    var haptic: RCHaptics.Kind? = .light

    private let backgroundLayer = CALayer()
    private let iconView: RCIconView

    init(icon: RCIconGlyph, variant: Variant = .plain, shape: Shape = .circle, diameter: CGFloat = 40, iconSize: CGFloat = 18, accessibilityLabel: String) {
        self.icon = icon
        self.variant = variant
        self.shape = shape
        self.diameter = diameter
        iconView = RCIconView(icon, pointSize: iconSize)
        super.init(frame: .zero)
        addSubview(iconView)
        self.accessibilityLabel = accessibilityLabel
        updateAppearance()
    }

    override func setUp() {
        isAccessibilityElement = true
        accessibilityTraits = .button
        layer.addSublayer(backgroundLayer)
        addTarget(self, action: #selector(handleTap), for: .primaryActionTriggered)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            let highlighted = isHighlighted
            RCMotion.animate(duration: highlighted ? RCMotion.pressDuration : RCMotion.releaseDuration) {
                self.transform = highlighted && !RCMotion.reduceMotion ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
                self.alpha = highlighted ? 0.8 : 1
            }
        }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.4 }
    }

    override var isSelected: Bool {
        didSet { updateAppearance() }
    }

    override func updateAppearance() {
        let fill: UIColor?
        let border: UIColor?
        let tint: UIColor
        switch variant {
        case .plain:
            fill = isSelected ? RCColor.text : RCColor.elevated
            border = isSelected ? nil : RCColor.line
            tint = isSelected ? RCColor.onPrimary : RCColor.text
        case .primary: fill = RCColor.text; border = nil; tint = RCColor.onPrimary
        case .accent: fill = RCColor.accent; border = nil; tint = RCColor.onAccent
        case .ghost: fill = nil; border = nil; tint = isSelected ? RCColor.accent : RCColor.textSecondary
        case .overlay: fill = UIColor(white: 1, alpha: 0.16); border = UIColor(white: 1, alpha: 0.22); tint = .white
        case .overlayProminent: fill = .white; border = nil; tint = .black
        case .stage:
            fill = isSelected ? RCColor.accent : RCColor.elevated
            border = isSelected ? nil : RCColor.line
            tint = isSelected ? RCColor.onAccent : RCColor.text
        }
        withoutImplicitAnimations {
            backgroundLayer.backgroundColor = fill?.cgColor(for: self)
            backgroundLayer.borderColor = border?.cgColor(for: self)
            backgroundLayer.borderWidth = border == nil ? 0 : 1
        }
        iconView.tintColor = tint
    }

    override var intrinsicContentSize: CGSize { CGSize(width: diameter, height: diameter) }

    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        withoutImplicitAnimations {
            backgroundLayer.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            backgroundLayer.cornerRadius = shape == .circle ? side / 2 : RCRadius.md
            backgroundLayer.cornerCurve = .continuous
        }
        iconView.frame = bounds
    }

    private func updateSpinning() {
        let key = "rc.spin"
        if isSpinning, iconView.layer.animation(forKey: key) == nil, !RCMotion.reduceMotion {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = CGFloat.pi * 2
            rotation.duration = 0.9
            rotation.repeatCount = .infinity
            rotation.isRemovedOnCompletion = false
            iconView.layer.add(rotation, forKey: key)
        } else if !isSpinning {
            iconView.layer.removeAnimation(forKey: key)
        }
    }

    @objc private func handleTap() {
        if let haptic { RCHaptics.play(haptic) }
        onTap?()
    }
}
