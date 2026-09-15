import UIKit

/// Card container: elevated fill, hairline border, two-layer shadow.
/// Add content to `contentView`; it is laid out inside `contentInsets`.
///
/// Layers, back to front: the root layer carries only the contact (or
/// floating) shadow, which renders beneath all of its sublayers; an
/// ambient-shadow view (shadow only); the fill view (color, border); and
/// `contentView`. Keeping the fill in its own view puts both shadows *under*
/// it — a sublayer's shadow drawn above the fill would darken the card itself —
/// and lets UIKit animate the fill with the frame. Shadows come from explicit
/// paths rebuilt only when the size or radius changes, animated alongside
/// UIKit resize animations. Nothing clips, so there are no offscreen passes.
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
    var style: Style { didSet { if style != oldValue { invalidateShadowPaths(); updateAppearance(); setNeedsLayout() } } }
    var cornerRadius: CGFloat { didSet { if cornerRadius != oldValue { invalidateShadowPaths(); setNeedsLayout() } } }
    var contentInsets: UIEdgeInsets = .zero { didSet { setNeedsLayout() } }

    private let ambientView = UIView()
    private let fillView = UIView()
    private var shadowGeometry: (size: CGSize, radius: CGFloat)?

    init(style: Style = .card, cornerRadius: CGFloat = RCRadius.lg) {
        self.style = style
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
    }

    override func setUp() {
        ambientView.isUserInteractionEnabled = false
        fillView.isUserInteractionEnabled = false
        contentView.backgroundColor = .clear
        addSubview(ambientView)
        addSubview(fillView)
        addSubview(contentView)
    }

    /// Colors resolve with Console tokens for `.floating`.
    private var colorTraits: UITraitCollection {
        guard style == .floating else { return traitCollection }
        return UITraitCollection(traitsFrom: [traitCollection, UITraitCollection(userInterfaceStyle: .dark)])
    }

    override func updateAppearance() {
        let traits = colorTraits
        let fill = fillView.layer
        let ambient = ambientView.layer
        withoutImplicitAnimations {
            switch style {
            case .card:
                fill.backgroundColor = RCColor.elevated.resolvedColor(with: traits).cgColor
                fill.borderColor = RCColor.line.resolvedColor(with: traits).cgColor
                fill.borderWidth = RCLayout.hairline
                applyShadow(RCShadow.contact, to: layer, traits: traits)
                applyShadow(RCShadow.card, to: ambient, traits: traits)
            case .inset:
                fill.backgroundColor = RCColor.surfaceSunken.resolvedColor(with: traits).cgColor
                fill.borderWidth = 0
                RCShadow.clear(layer)
                RCShadow.clear(ambient)
                shadowGeometry = nil
            case .floating:
                // Opaque: chrome over live video must not blend every frame.
                fill.backgroundColor = RCColor.surface.resolvedColor(with: traits).cgColor
                fill.borderColor = RCColor.line.resolvedColor(with: traits).cgColor
                fill.borderWidth = RCLayout.hairline
                applyShadow(RCShadow.floating, to: layer, traits: traits)
                RCShadow.clear(ambient)
            }
        }
    }

    /// Color and opacity only; the path is owned by `updateShadowPaths`.
    private func applyShadow(_ shadow: RCShadow, to layer: CALayer, traits: UITraitCollection) {
        layer.shadowColor = RCColor.shadow.resolvedColor(with: traits).cgColor
        layer.shadowOpacity = traits.userInterfaceStyle == .dark ? shadow.opacityDark : shadow.opacityLight
        layer.shadowRadius = shadow.radius
        layer.shadowOffset = shadow.offset
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitAnimations {
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
            for view in [ambientView, fillView] {
                view.layer.cornerRadius = cornerRadius
                view.layer.cornerCurve = .continuous
            }
        }
        ambientView.frame = bounds
        fillView.frame = bounds
        updateShadowPaths()
        contentView.frame = bounds.inset(by: contentInsets)
    }

    private func invalidateShadowPaths() {
        shadowGeometry = nil
    }

    private func updateShadowPaths() {
        let size = bounds.size
        guard style != .inset, size.width > 0, size.height > 0 else { return }
        if let shadowGeometry, shadowGeometry.size == size, shadowGeometry.radius == cornerRadius { return }
        let path = UIBezierPath.continuousRoundedRect(CGRect(origin: .zero, size: size), radius: cornerRadius).cgPath
        let layers = style == .card ? [layer, ambientView.layer] : [layer]
        for target in layers {
            let old = target.shadowPath
            withoutImplicitAnimations { target.shadowPath = path }
            if shadowGeometry != nil, let old {
                // Inside a UIKit animation the fill's bounds are animating; keep the shadow on it.
                RCLayerAnimation.follow(boundsAnimationOf: fillView.layer, on: target, keyPath: "shadowPath", from: old, to: path)
            }
        }
        if style != .card { ambientView.layer.shadowPath = nil }
        shadowGeometry = (size, cornerRadius)
    }

#if DEBUG
    /// Contact (root) and ambient shadow layers, then the fill (tests).
    var shadowLayersForTesting: [CALayer] { [layer, ambientView.layer] }
    var fillLayerForTesting: CALayer { fillView.layer }
#endif

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = CGSize(width: size.width - contentInsets.left - contentInsets.right, height: size.height - contentInsets.top - contentInsets.bottom)
        let fitted = contentView.subviews.first?.sizeThatFits(inner) ?? .zero
        return CGSize(width: size.width, height: fitted.height + contentInsets.top + contentInsets.bottom)
    }
}

/// Inline note, warning or error with a leading icon (shadcn `Alert`), with an
/// optional trailing action. Text wraps; the icon stays centered on the first
/// line. `shake()` draws attention to a new error and announces it to VoiceOver.
@MainActor
final class RCCallout: RCView {
    enum Tone: Sendable { case neutral, accent, success, danger }

    var text: String {
        didSet {
            guard text != oldValue else { return }
            label.text = text
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    var icon: RCIconGlyph { didSet { iconView.glyph = icon } }
    var tone: Tone { didSet { if tone != oldValue { updateAppearance() } } }

    private let label = RCLabel(style: .footnote, lines: 0)
    private let iconView = RCIconView(pointSize: 16)
    private var actionButton: RCButton?

    private static let insets = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    private static let iconGap: CGFloat = 10
    private static let actionGap: CGFloat = 12

    init(text: String, icon: RCIconGlyph = .info, tone: Tone = .neutral) {
        self.text = text
        self.icon = icon
        self.tone = tone
        super.init(frame: .zero)
        label.text = text
        iconView.glyph = icon
        updateAppearance()
        updateTypography()
    }

    override func setUp() {
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        addSubview(iconView)
        addSubview(label)
    }

    override var accessibilityLabel: String? {
        get { text }
        set {}
    }

    /// Adds, replaces (or with a nil title removes) a compact trailing action.
    func setAction(title: String?, handler: (() -> Void)?) {
        guard let title, !title.isEmpty else {
            actionButton?.removeFromSuperview()
            actionButton = nil
            isAccessibilityElement = true
            accessibilityElements = nil
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            return
        }
        let button = actionButton ?? RCButton(variant: .secondary, size: .small)
        button.title = title
        button.onTap = handler
        if actionButton == nil {
            addSubview(button)
            actionButton = button
        }
        // The container stops being one element so the action stays reachable.
        isAccessibilityElement = false
        label.isAccessibilityElement = true
        accessibilityElements = [label, button]
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func updateAppearance() {
        let foreground: UIColor
        let background: UIColor
        let toneColor: UIColor
        switch tone {
        case .neutral: foreground = RCColor.textTertiary; background = RCColor.elevated; toneColor = RCColor.textTertiary
        case .accent: foreground = RCColor.accentText; background = RCColor.accentSoft; toneColor = RCColor.accent
        case .success: foreground = RCColor.successText; background = RCColor.successSoft; toneColor = RCColor.success
        case .danger: foreground = RCColor.dangerText; background = RCColor.dangerSoft; toneColor = RCColor.danger
        }
        // Body copy stays ink; the icon (AA tone text token), wash and border
        // (the web tone color) carry the tone.
        label.color = tone == .neutral ? RCColor.textSecondary : RCColor.text
        iconView.tintColor = foreground
        let border = tone == .neutral ? RCColor.line.resolved(for: self) : toneColor.resolved(for: self).withAlphaComponent(0.22)
        withoutImplicitAnimations {
            layer.backgroundColor = background.cgColor(for: self)
            layer.borderColor = border.cgColor
            layer.borderWidth = RCLayout.hairline
        }
    }

    override func updateTypography() {
        let scale = min(RCTypography.scale(for: .footnote, compatibleWith: traitCollection), 1.5)
        iconView.pointSize = (16 * scale).rounded()
    }

#if DEBUG
    /// Icon tint and text color for the current tone (tests).
    var colorsForTesting: (icon: UIColor?, text: UIColor) { (iconView.tintColor, label.color) }
#endif

    /// Horizontal shake to draw attention to a new error. Plays the warning
    /// haptic unless `playsHaptic` is false (e.g. the caller already played
    /// one); under Reduce Motion the movement is skipped but the haptic still
    /// plays. VoiceOver users hear the message.
    func shake(playsHaptic: Bool = true) {
        if !RCMotion.reduceMotion {
            let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
            animation.values = [0, -8, 7, -5, 3, -1, 0]
            animation.keyTimes = [0, 0.16, 0.34, 0.52, 0.7, 0.86, 1]
            animation.duration = 0.42
            animation.isAdditive = true
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "rc.shake")
        }
        if playsHaptic { RCHaptics.play(.warning) }
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }

    // MARK: Layout

    private struct Layout {
        var icon: CGRect
        var label: CGRect
        var action: CGRect?
        var height: CGFloat
    }

    private func makeLayout(width: CGFloat) -> Layout {
        let insets = Self.insets
        let iconSize = iconView.pointSize
        let firstLine = RCTypography.lineHeight(.footnote, compatibleWith: traitCollection)
        let textX = insets.left + iconSize + Self.iconGap
        let fullTextWidth = max(0, width - textX - insets.right)
        let actionSize = actionButton?.sizeThatFits(CGSize(width: fullTextWidth, height: .greatestFiniteMagnitude))

        var textWidth = fullTextWidth
        var actionBelow = false
        if let actionSize {
            let besideWidth = fullTextWidth - actionSize.width - Self.actionGap
            let oneLine = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: firstLine)).width
            if besideWidth > 0, oneLine <= besideWidth {
                textWidth = besideWidth
            } else {
                actionBelow = true
            }
        }
        let textHeight = max(firstLine, label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)

        if let actionSize, !actionBelow {
            // One row: text, icon and action share a vertical center.
            let rowHeight = max(textHeight, actionSize.height)
            let top: CGFloat = 8
            let midY = top + rowHeight / 2
            return Layout(
                icon: CGRect(x: insets.left, y: midY - iconSize / 2, width: iconSize, height: iconSize),
                label: CGRect(x: textX, y: midY - textHeight / 2, width: textWidth, height: textHeight),
                action: CGRect(x: width - insets.right - actionSize.width + 4, y: midY - actionSize.height / 2, width: actionSize.width, height: actionSize.height),
                height: rowHeight + top * 2
            )
        }
        var height = insets.top + textHeight
        var action: CGRect?
        if let actionSize {
            action = CGRect(x: textX, y: height + 10, width: actionSize.width, height: actionSize.height)
            height += 10 + actionSize.height
        }
        return Layout(
            icon: CGRect(x: insets.left, y: insets.top + (firstLine - iconSize) / 2, width: iconSize, height: iconSize),
            label: CGRect(x: textX, y: insets.top, width: textWidth, height: textHeight),
            action: action,
            height: height + insets.bottom
        )
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: RCPixelSnap.ceil(makeLayout(width: size.width).height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCornerRadius(RCRadius.md)
        let layout = makeLayout(width: bounds.width)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func place(_ rect: CGRect) -> CGRect {
            RCLayout.pixelAligned(rtl ? CGRect(x: bounds.width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect)
        }
        iconView.frame = place(layout.icon)
        label.frame = place(layout.label)
        if let action = layout.action { actionButton?.frame = place(action) }
    }
}

/// Section title row: overline label, optional quiet subtitle on the same
/// baseline (wrapping below when there is no room), trailing accessory.
@MainActor
final class RCSectionHeader: RCView {
    var title: String { didSet { if title != oldValue { titleLabel.text = title; setNeedsLayout() } } }
    var subtitle: String? { didSet { if subtitle != oldValue { subtitleLabel.text = subtitle; subtitleLabel.isHidden = subtitle?.isEmpty != false; setNeedsLayout() } } }
    /// Trailing view (icon buttons, spinner). Sized with `sizeThatFits`.
    var accessoryView: UIView? {
        didSet {
            guard accessoryView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let accessoryView { addSubview(accessoryView) }
            setNeedsLayout()
        }
    }
    /// Leading/trailing inset of the text and accessory.
    var horizontalInset: CGFloat = 4 { didSet { setNeedsLayout() } }

    private let titleLabel = RCLabel(style: .overline, color: RCColor.textTertiary)
    /// Tertiary rather than quaternary (~2.3:1 on the canvas); the lighter
    /// style keeps it subordinate to the overline.
    private let subtitleLabel = RCLabel(style: .caption, color: RCColor.textTertiary, lines: 2)

    private static let minimumHeight: CGFloat = 32
    private static let subtitleGap: CGFloat = 8

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        super.init(frame: .zero)
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = subtitle?.isEmpty != false
    }

    override func setUp() {
        titleLabel.accessibilityTraits = .header
        addSubview(titleLabel)
        addSubview(subtitleLabel)
    }

    private struct Layout {
        var title: CGRect
        var subtitle: CGRect
        var accessory: CGRect
        var height: CGFloat
    }

    private func makeLayout(width: CGFloat) -> Layout {
        let accessorySize = accessoryView.map { $0.sizeThatFits(CGSize(width: width / 2, height: .greatestFiniteMagnitude)) } ?? .zero
        let textRight = width - horizontalInset - (accessorySize.width > 0 ? accessorySize.width + RCSpace.sm : 0)
        let available = max(0, textRight - horizontalInset)
        let titleLine = RCTypography.lineHeight(.overline, compatibleWith: traitCollection)
        let subtitleLine = RCTypography.lineHeight(.caption, compatibleWith: traitCollection)
        let titleWidth = min(available, titleLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: titleLine)).width)
        let hasSubtitle = !subtitleLabel.isHidden
        let subtitleNatural = hasSubtitle ? subtitleLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: subtitleLine)).width : 0
        let inline = !hasSubtitle || titleWidth + Self.subtitleGap + subtitleNatural <= available

        let textHeight: CGFloat
        var titleRect: CGRect
        var subtitleRect: CGRect
        if inline {
            // Shared baseline: offset each line box by the difference of their baselines.
            let titleBaseline = RCTypography.firstBaseline(.overline, compatibleWith: traitCollection)
            let subtitleBaseline = RCTypography.firstBaseline(.caption, compatibleWith: traitCollection)
            let baseline = max(titleBaseline, hasSubtitle ? subtitleBaseline : 0)
            let bottom = max(titleLine - titleBaseline, hasSubtitle ? subtitleLine - subtitleBaseline : 0)
            textHeight = baseline + bottom
            titleRect = CGRect(x: horizontalInset, y: baseline - titleBaseline, width: titleWidth, height: titleLine)
            let subtitleX = titleRect.maxX + Self.subtitleGap
            subtitleRect = CGRect(x: subtitleX, y: baseline - subtitleBaseline, width: max(0, min(subtitleNatural, textRight - subtitleX)), height: subtitleLine)
        } else {
            titleRect = CGRect(x: horizontalInset, y: 0, width: titleWidth, height: titleLine)
            let subtitleHeight = subtitleLabel.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height
            subtitleRect = CGRect(x: horizontalInset, y: titleLine + 2, width: available, height: subtitleHeight)
            textHeight = subtitleRect.maxY
        }
        let height = max(Self.minimumHeight, accessorySize.height, textHeight + 8)
        let textTop = ((height - textHeight) / 2)
        titleRect.origin.y += textTop
        subtitleRect.origin.y += textTop
        let accessory = CGRect(x: width - horizontalInset - accessorySize.width, y: (height - accessorySize.height) / 2, width: accessorySize.width, height: accessorySize.height)
        return Layout(title: titleRect, subtitle: subtitleRect, accessory: accessory, height: height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: RCPixelSnap.ceil(makeLayout(width: size.width).height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = makeLayout(width: bounds.width)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func place(_ rect: CGRect) -> CGRect {
            RCLayout.pixelAligned(rtl ? CGRect(x: bounds.width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect)
        }
        titleLabel.frame = place(layout.title)
        subtitleLabel.frame = place(layout.subtitle)
        accessoryView?.frame = place(layout.accessory)
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
    var tone: Tone { didSet { if tone != oldValue { updateAppearance() } } }
    let side: CGFloat
    private let iconView: RCIconView
    private let dash = CAShapeLayer()
    private var dashSize: CGSize = .zero

    init(glyph: RCIconGlyph, tone: Tone = .accent, side: CGFloat = 40) {
        self.glyph = glyph
        self.tone = tone
        self.side = side
        iconView = RCIconView(glyph, pointSize: (side * 0.45).rounded())
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        addSubview(iconView)
        updateAppearance()
    }

    override func setUp() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        dash.fillColor = nil
        dash.lineDashPattern = [4, 3]
        dash.lineWidth = 1
        dash.lineCap = .round
        layer.addSublayer(dash)
    }

    override func updateAppearance() {
        let fill: UIColor?
        let tint: UIColor
        switch tone {
        case .accent: fill = RCColor.accentSoft; tint = RCColor.accent
        case .neutral: fill = RCColor.surfaceSunken; tint = RCColor.textSecondary
        // Sage on its wash is under the 3:1 non-text minimum in Warm.
        case .success: fill = RCColor.successSoft; tint = RCColor.successText
        case .danger: fill = RCColor.dangerSoft; tint = RCColor.danger
        case .dashed: fill = nil; tint = RCColor.accent
        case .muted: fill = RCColor.surfaceSunken; tint = RCColor.textQuaternary
        }
        withoutImplicitAnimations {
            layer.backgroundColor = fill?.cgColor(for: self)
            dash.strokeColor = tone == .dashed ? RCColor.lineStrong.cgColor(for: self) : nil
            dash.isHidden = tone != .dashed
        }
        iconView.tintColor = tint
    }

    override var intrinsicContentSize: CGSize { CGSize(width: side, height: side) }
    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = (side * 0.28).rounded()
        applyCornerRadius(radius)
        if bounds.size != dashSize {
            dashSize = bounds.size
            withoutImplicitAnimations {
                dash.frame = bounds
                dash.path = UIBezierPath.continuousRoundedRect(bounds.insetBy(dx: 0.5, dy: 0.5), radius: radius - 0.5).cgPath
            }
        }
        iconView.frame = bounds
    }
}

/// Centered icon, title, message and optional actions for empty and error
/// states. Content is centered vertically when given more room than it needs.
@MainActor
final class RCEmptyStateView: RCView {
    private let tile: RCIconTile
    private let titleLabel = RCLabel(style: .headline, lines: 0, alignment: .center)
    private let messageLabel = RCLabel(style: .subheadline, color: RCColor.textSecondary, lines: 0, alignment: .center)
    private var buttons: [RCButton] = []

    private static let tileSide: CGFloat = 52
    private static let textWidth: CGFloat = 340
    private static let actionWidth: CGFloat = 300

    init(icon: RCIconGlyph, title: String, message: String, actions: [RCButton] = []) {
        tile = RCIconTile(glyph: icon, tone: .neutral, side: Self.tileSide)
        super.init(frame: .zero)
        titleLabel.text = title
        messageLabel.text = message
        addSubview(tile)
        setActions(actions)
    }

    override func setUp() {
        titleLabel.accessibilityTraits = .header
        addSubview(titleLabel)
        addSubview(messageLabel)
    }

    func update(title: String, message: String) {
        titleLabel.text = title
        messageLabel.text = message
        setNeedsLayout()
    }

    /// Replaces the stacked actions (first is the primary one). Buttons use the
    /// medium size and span the action column.
    func setActions(_ actions: [RCButton]) {
        buttons.filter { button in !actions.contains { $0 === button } }.forEach { $0.removeFromSuperview() }
        buttons = actions
        for button in actions {
            button.size = .medium
            if button.superview !== self { addSubview(button) }
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private struct Layout {
        var tile: CGRect
        var title: CGRect
        var message: CGRect
        var buttons: [CGRect]
        var height: CGFloat
    }

    private func makeLayout(width: CGFloat) -> Layout {
        let textWidth = min(width, Self.textWidth)
        let textX = (width - textWidth) / 2
        var y: CGFloat = 0
        let tile = CGRect(x: (width - Self.tileSide) / 2, y: y, width: Self.tileSide, height: Self.tileSide)
        y = tile.maxY + RCSpace.lg
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let title = CGRect(x: textX, y: y, width: textWidth, height: titleHeight)
        y = title.maxY + 6
        let messageHeight = messageLabel.text?.isEmpty == false ? messageLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height : 0
        let message = CGRect(x: textX, y: y, width: textWidth, height: messageHeight)
        y = message.maxY
        var frames: [CGRect] = []
        if !buttons.isEmpty {
            y += RCSpace.xxl
            let actionWidth = min(width, Self.actionWidth)
            for (index, button) in buttons.enumerated() {
                if index > 0 { y += 10 }
                let height = button.sizeThatFits(CGSize(width: actionWidth, height: .greatestFiniteMagnitude)).height
                frames.append(CGRect(x: (width - actionWidth) / 2, y: y, width: actionWidth, height: height))
                y += height
            }
        }
        return Layout(tile: tile, title: title, message: message, buttons: frames, height: y)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: RCPixelSnap.ceil(makeLayout(width: size.width).height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = makeLayout(width: bounds.width)
        let offset = max(0, (bounds.height - layout.height) / 2)
        func place(_ rect: CGRect) -> CGRect { RCLayout.pixelAligned(rect.offsetBy(dx: 0, dy: offset)) }
        tile.frame = place(layout.tile)
        titleLabel.frame = place(layout.title)
        messageLabel.frame = place(layout.message)
        for (button, frame) in zip(buttons, layout.buttons) {
            button.frame = place(frame)
        }
    }
}
