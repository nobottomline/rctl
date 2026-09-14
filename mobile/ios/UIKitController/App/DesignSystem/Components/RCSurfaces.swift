import UIKit

/// Card container: elevated fill, hairline border, cached two-layer shadow.
/// Add content to `contentView`; it is laid out inside `contentInsets`.
@MainActor
class RCSurfaceView: RCView {
    enum Style: Sendable {
        /// Elevated card with border and soft shadow.
        case card
        /// Flat sunken well without shadow.
        case inset
        /// Floating chrome over the media stage (dark tokens, stronger shadow).
        case floating
    }

    let contentView = UIView()
    var style: Style { didSet { updateAppearance(); setNeedsLayout() } }
    var cornerRadius: CGFloat { didSet { setNeedsLayout() } }
    var contentInsets: UIEdgeInsets = .zero { didSet { setNeedsLayout() } }

    private let ambientShadow = CALayer()

    init(style: Style = .card, cornerRadius: CGFloat = RCRadius.lg) {
        self.style = style
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
    }

    override func setUp() {
        layer.insertSublayer(ambientShadow, at: 0)
        contentView.backgroundColor = .clear
        addSubview(contentView)
    }

    override func updateAppearance() {
        switch style {
        case .card:
            layer.backgroundColor = RCColor.elevated.cgColor(for: self)
            layer.borderColor = RCColor.line.cgColor(for: self)
            layer.borderWidth = RCLayout.hairline
        case .inset:
            layer.backgroundColor = RCColor.surfaceSunken.cgColor(for: self)
            layer.borderColor = RCColor.line.cgColor(for: self)
            layer.borderWidth = 0
        case .floating:
            layer.backgroundColor = RCColor.surface.resolved(for: self).withAlphaComponent(0.96).cgColor
            layer.borderColor = RCColor.line.cgColor(for: self)
            layer.borderWidth = RCLayout.hairline
        }
        applyShadows()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitAnimations {
            applyCornerRadius(cornerRadius)
            ambientShadow.frame = bounds
            applyShadows()
        }
        contentView.frame = bounds.inset(by: contentInsets)
    }

    private func applyShadows() {
        guard bounds.width > 0 else { return }
        let path = UIBezierPath.continuousRoundedRect(bounds, radius: cornerRadius).cgPath
        switch style {
        case .card:
            RCShadow.contact.apply(to: layer, path: path, traits: traitCollection)
            RCShadow.card.apply(to: ambientShadow, path: path, traits: traitCollection)
        case .inset:
            RCShadow.clear(layer)
            RCShadow.clear(ambientShadow)
        case .floating:
            RCShadow.floating.apply(to: layer, path: path, traits: traitCollection)
            RCShadow.clear(ambientShadow)
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = CGSize(width: size.width - contentInsets.left - contentInsets.right, height: size.height - contentInsets.top - contentInsets.bottom)
        let fitted = contentView.subviews.first?.sizeThatFits(inner) ?? .zero
        return CGSize(width: size.width, height: fitted.height + contentInsets.top + contentInsets.bottom)
    }
}

/// Inline note, warning or error with a leading icon (shadcn `Alert`).
@MainActor
final class RCCallout: RCView {
    enum Tone: Sendable { case neutral, accent, success, danger }

    var text: String { didSet { label.text = text; invalidateIntrinsicContentSize(); setNeedsLayout() } }
    var icon: RCIconGlyph { didSet { iconView.glyph = icon } }
    var tone: Tone { didSet { updateAppearance() } }

    private let label = RCLabel(style: .footnote, lines: 0)
    private let iconView = RCIconView(pointSize: 16)
    private static let insets = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

    init(text: String, icon: RCIconGlyph = .info, tone: Tone = .neutral) {
        self.text = text
        self.icon = icon
        self.tone = tone
        super.init(frame: .zero)
        label.text = text
        iconView.glyph = icon
        updateAppearance()
    }

    override func setUp() {
        isAccessibilityElement = true
        addSubview(iconView)
        addSubview(label)
    }

    override var accessibilityLabel: String? {
        get { text }
        set {}
    }

    override func updateAppearance() {
        let foreground: UIColor
        let background: UIColor
        let border: UIColor
        switch tone {
        case .neutral: foreground = RCColor.textSecondary; background = RCColor.elevated; border = RCColor.line
        case .accent: foreground = RCColor.accent; background = RCColor.accentSoft; border = RCColor.accentSoft
        case .success: foreground = RCColor.success; background = RCColor.successSoft; border = RCColor.successSoft
        case .danger: foreground = RCColor.danger; background = RCColor.dangerSoft; border = RCColor.dangerSoft
        }
        label.color = tone == .neutral ? RCColor.textSecondary : foreground
        iconView.tintColor = tone == .neutral ? RCColor.textTertiary : foreground
        layer.backgroundColor = background.cgColor(for: self)
        layer.borderColor = border.cgColor(for: self)
        layer.borderWidth = RCLayout.hairline
    }

    /// Horizontal shake to draw attention to a new error.
    func shake() {
        guard !RCMotion.reduceMotion else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -8, 7, -5, 3, 0]
        animation.duration = 0.36
        layer.add(animation, forKey: "rc.shake")
        RCHaptics.play(.warning)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textWidth = size.width - Self.insets.left - Self.insets.right - 16 - 10
        let labelHeight = label.sizeThatFits(CGSize(width: max(0, textWidth), height: .greatestFiniteMagnitude)).height
        return CGSize(width: size.width, height: ceil(max(labelHeight, 18) + Self.insets.top + Self.insets.bottom))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCornerRadius(RCRadius.md)
        iconView.frame = CGRect(x: Self.insets.left, y: Self.insets.top + 1, width: 16, height: 16)
        let x = Self.insets.left + 16 + 10
        let width = bounds.width - x - Self.insets.right
        let height = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        label.frame = CGRect(x: x, y: Self.insets.top, width: width, height: height)
    }
}

/// Section title row: overline label, optional quiet subtitle, trailing accessory.
@MainActor
final class RCSectionHeader: RCView {
    var title: String { didSet { titleLabel.text = title; setNeedsLayout() } }
    var subtitle: String? { didSet { subtitleLabel.text = subtitle; setNeedsLayout() } }
    /// Trailing view (icon buttons, spinner). Sized with `sizeThatFits`.
    var accessoryView: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let accessoryView { addSubview(accessoryView) }
            setNeedsLayout()
        }
    }

    private let titleLabel = RCLabel(style: .overline, color: RCColor.textTertiary)
    private let subtitleLabel = RCLabel(style: .caption, color: RCColor.textQuaternary)

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        super.init(frame: .zero)
        titleLabel.text = title
        subtitleLabel.text = subtitle
    }

    override func setUp() {
        titleLabel.accessibilityTraits = .header
        addSubview(titleLabel)
        addSubview(subtitleLabel)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let accessoryHeight = accessoryView?.sizeThatFits(size).height ?? 0
        return CGSize(width: size.width, height: max(32, accessoryHeight))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let accessorySize = accessoryView?.sizeThatFits(bounds.size) ?? .zero
        accessoryView?.frame = CGRect(x: bounds.width - accessorySize.width, y: (bounds.height - accessorySize.height) / 2, width: accessorySize.width, height: accessorySize.height)
        let titleSize = titleLabel.sizeThatFits(bounds.size)
        let midY = bounds.height / 2
        titleLabel.frame = CGRect(x: 4, y: midY - titleSize.height / 2, width: titleSize.width, height: titleSize.height)
        let subtitleX = titleLabel.frame.maxX + RCSpace.sm
        let subtitleWidth = max(0, bounds.width - subtitleX - accessorySize.width - RCSpace.sm)
        let subtitleSize = subtitleLabel.sizeThatFits(CGSize(width: subtitleWidth, height: bounds.height))
        subtitleLabel.frame = CGRect(x: subtitleX, y: midY - subtitleSize.height / 2, width: min(subtitleWidth, subtitleSize.width), height: subtitleSize.height)
    }
}

/// Rounded icon tile used as the leading element of rows.
@MainActor
final class RCIconTile: RCView {
    enum Tone: Sendable {
        case accent, neutral, success, danger
        /// Dashed outline "add" tile.
        case dashed
        /// Disabled look.
        case muted
    }

    var glyph: RCIconGlyph { didSet { iconView.glyph = glyph } }
    var tone: Tone { didSet { updateAppearance() } }
    let side: CGFloat
    private let iconView: RCIconView
    private let dash = CAShapeLayer()

    init(glyph: RCIconGlyph, tone: Tone = .accent, side: CGFloat = 40) {
        self.glyph = glyph
        self.tone = tone
        self.side = side
        iconView = RCIconView(glyph, pointSize: side * 0.46)
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        addSubview(iconView)
        updateAppearance()
    }

    override func setUp() {
        isUserInteractionEnabled = false
        dash.fillColor = nil
        dash.lineDashPattern = [4, 3]
        dash.lineWidth = 1
        layer.addSublayer(dash)
    }

    override func updateAppearance() {
        let fill: UIColor?
        let tint: UIColor
        switch tone {
        case .accent: fill = RCColor.accentSoft; tint = RCColor.accent
        case .neutral: fill = RCColor.surfaceSunken; tint = RCColor.textSecondary
        case .success: fill = RCColor.successSoft; tint = RCColor.success
        case .danger: fill = RCColor.dangerSoft; tint = RCColor.danger
        case .dashed: fill = nil; tint = RCColor.accent
        case .muted: fill = RCColor.surfaceSunken; tint = RCColor.textQuaternary
        }
        layer.backgroundColor = fill?.cgColor(for: self)
        dash.strokeColor = tone == .dashed ? RCColor.lineStrong.cgColor(for: self) : nil
        iconView.tintColor = tint
    }

    override var intrinsicContentSize: CGSize { CGSize(width: side, height: side) }
    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCornerRadius(side * 0.28)
        withoutImplicitAnimations {
            dash.frame = bounds
            dash.path = UIBezierPath.continuousRoundedRect(bounds.insetBy(dx: 0.5, dy: 0.5), radius: side * 0.28).cgPath
        }
        iconView.frame = bounds
    }
}

/// Centered illustration + title + message + actions for empty and error states.
@MainActor
final class RCEmptyStateView: RCView {
    private let tile: RCIconTile
    private let titleLabel = RCLabel(style: .headline, lines: 0, alignment: .center)
    private let messageLabel = RCLabel(style: .subheadline, color: RCColor.textSecondary, lines: 0, alignment: .center)
    private var buttons: [RCButton] = []

    init(icon: RCIconGlyph, title: String, message: String, actions: [RCButton] = []) {
        tile = RCIconTile(glyph: icon, tone: .neutral, side: 52)
        super.init(frame: .zero)
        titleLabel.text = title
        messageLabel.text = message
        addSubview(tile)
        buttons = actions
        actions.forEach(addSubview)
    }

    override func setUp() {
        addSubview(titleLabel)
        addSubview(messageLabel)
    }

    func update(title: String, message: String) {
        titleLabel.text = title
        messageLabel.text = message
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = min(size.width, 360)
        var height: CGFloat = 52 + RCSpace.lg
        height += titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + RCSpace.xs
        height += messageLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        if !buttons.isEmpty { height += RCSpace.xl + CGFloat(buttons.count) * 44 + CGFloat(buttons.count - 1) * RCSpace.sm }
        return CGSize(width: size.width, height: ceil(height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width, 360)
        let x = (bounds.width - width) / 2
        var y: CGFloat = 0
        tile.frame = CGRect(x: (bounds.width - 52) / 2, y: y, width: 52, height: 52)
        y += 52 + RCSpace.lg
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        titleLabel.frame = CGRect(x: x, y: y, width: width, height: titleHeight)
        y += titleHeight + RCSpace.xs
        let messageHeight = messageLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        messageLabel.frame = CGRect(x: x, y: y, width: width, height: messageHeight)
        y += messageHeight + RCSpace.xl
        for button in buttons {
            button.size = .medium
            button.frame = CGRect(x: x, y: y, width: width, height: 44)
            y += 44 + RCSpace.sm
        }
    }
}
