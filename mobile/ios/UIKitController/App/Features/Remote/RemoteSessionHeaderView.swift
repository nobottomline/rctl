import UIKit

extension RemoteTone {
    var color: UIColor {
        switch self {
        case .success: RCColor.success
        case .accent: RCColor.accent
        case .danger: RCColor.danger
        case .text: RCColor.text
        case .secondary: RCColor.textSecondary
        case .tertiary: RCColor.textTertiary
        }
    }
}

/// Neutral LAN / Relay pill. Never colored by trust: LAN is a trusted
/// network, not a pairing, and Relay is only a route.
@MainActor
final class RemoteAccessPathBadge: RCView {
    /// Icon-only circle for the landscape rail.
    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            label.isHidden = isCompact
            iconView.pointSize = isCompact ? 14 : 11
            updateAppearance()
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    private let iconView = RCIconView(pointSize: 11, strokeWidth: 2.4)
    private let label = RCLabel(style: .overline, color: RCColor.text)
    private var path: RemoteAccessPathPresentation?

    override func setUp() {
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        addSubview(iconView)
        addSubview(label)
    }

    func configure(_ path: RemoteAccessPathPresentation) {
        guard path != self.path else { return }
        self.path = path
        iconView.glyph = path.isLocal ? .wifi : .globe
        label.text = path.badgeText
        accessibilityLabel = path.accessibilityLabel
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func updateAppearance() {
        layer.backgroundColor = RCColor.elevated.cgColor(for: self)
        layer.borderColor = RCColor.line.cgColor(for: self)
        layer.borderWidth = RCLayout.hairline
        iconView.tintColor = isCompact ? RCColor.textSecondary : RCColor.text
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        if isCompact { return CGSize(width: 28, height: 28) }
        let labelSize = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 40))
        return CGSize(width: ceil(7 + 11 + 4 + labelSize.width + 8), height: max(20, ceil(labelSize.height + 4)))
    }

    override var intrinsicContentSize: CGSize { sizeThatFits(.zero) }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitAnimations {
            layer.cornerRadius = bounds.height / 2
            layer.cornerCurve = .continuous
        }
        if isCompact {
            iconView.frame = bounds
            return
        }
        iconView.frame = CGRect(x: 7, y: (bounds.height - 11) / 2, width: 11, height: 11)
        let labelSize = label.sizeThatFits(bounds.size)
        label.frame = CGRect(x: 7 + 11 + 4, y: (bounds.height - labelSize.height) / 2, width: max(0, bounds.width - 22 - 8), height: labelSize.height)
    }
}

/// Connection status dot. A soft ring pulses on the render server only while
/// the session is live and the view is on screen (static under Reduce Motion).
@MainActor
final class RemoteStatusDot: RCView {
    static let diameter: CGFloat = 7

    private let dot = CALayer()
    private let ring = CALayer()
    private var tone: RemoteTone = .tertiary
    private(set) var isPulsing = false
    private static let pulseKey = "rc.remote.pulse"

    override func setUp() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        ring.opacity = 0
        layer.addSublayer(ring)
        layer.addSublayer(dot)
    }

    func configure(tone: RemoteTone, pulsing: Bool) {
        if tone != self.tone {
            self.tone = tone
            withoutImplicitAnimations { updateAppearance() }
        }
        guard pulsing != isPulsing else { return }
        isPulsing = pulsing
        updatePulse()
    }

    override func updateAppearance() {
        let color = tone.color.cgColor(for: self)
        dot.backgroundColor = color
        ring.backgroundColor = color
    }

    override var intrinsicContentSize: CGSize { CGSize(width: Self.diameter, height: Self.diameter) }
    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = Self.diameter
        let rect = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        withoutImplicitAnimations {
            dot.frame = rect
            dot.cornerRadius = side / 2
            ring.frame = rect
            ring.cornerRadius = side / 2
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePulse()
    }

    private func updatePulse() {
        let shouldAnimate = isPulsing && window != nil && !RCMotion.reduceMotion
        if shouldAnimate {
            guard ring.animation(forKey: Self.pulseKey) == nil else { return }
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 2.8
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.55
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = 1.8
            group.timingFunction = RCMotion.easeOut
            group.repeatCount = .infinity
            group.isRemovedOnCompletion = false
            ring.add(group, forKey: Self.pulseKey)
        } else {
            ring.removeAnimation(forKey: Self.pulseKey)
        }
    }
}

/// Interaction mode chip ("VIEW ONLY" / "CONTROL" / "CAMERA"), or a glyph in
/// the compact rail. Crossfades when the mode changes.
@MainActor
final class RemoteModeChip: RCView {
    var isCompact = false { didSet { if isCompact != oldValue { applyContent(); invalidateIntrinsicContentSize(); setNeedsLayout() } } }

    private let label = RCLabel(style: .overline)
    private let iconView = RCIconView(pointSize: 15)
    private var text = ""
    private var tone: RemoteTone = .secondary
    private var glyph: Glyph = .view

    private enum Glyph { case view, control, camera }

    override func setUp() {
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Interaction mode"
        addSubview(label)
        addSubview(iconView)
        applyContent()
    }

    /// Returns true when the chip's size may have changed.
    @discardableResult
    func configure(_ presentation: RemoteSessionPresentation, animated: Bool) -> Bool {
        let glyph: Glyph = presentation.media == .camera ? .camera : (presentation.isControlMode ? .control : .view)
        guard presentation.modeLabel != text || presentation.modeTone != tone || glyph != self.glyph else { return false }
        let update = {
            self.text = presentation.modeLabel
            self.tone = presentation.modeTone
            self.glyph = glyph
            self.accessibilityValue = presentation.modeAccessibilityValue
            self.applyContent()
        }
        if animated, window != nil {
            UIView.transition(with: self, duration: RCMotion.quickDuration, options: [.transitionCrossDissolve, .allowUserInteraction], animations: update)
        } else {
            update()
        }
        invalidateIntrinsicContentSize()
        return true
    }

    private func applyContent() {
        label.text = text
        label.color = tone.color
        label.isHidden = isCompact
        iconView.isHidden = !isCompact
        iconView.glyph = switch glyph {
        case .view: .eye
        case .control: .pointer
        case .camera: .camera
        }
        iconView.tintColor = tone.color
        withoutImplicitAnimations { updateAppearance() }
    }

    override func updateAppearance() {
        let color = tone.color.resolved(for: self)
        layer.backgroundColor = color.withAlphaComponent(0.12).cgColor
        layer.borderColor = color.withAlphaComponent(0.32).cgColor
        layer.borderWidth = 1
    }

    override var intrinsicContentSize: CGSize { sizeThatFits(.zero) }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        if isCompact { return CGSize(width: 28, height: 28) }
        let labelSize = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 40))
        return CGSize(width: ceil(labelSize.width + 20), height: max(26, ceil(labelSize.height + 10)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitAnimations {
            layer.cornerRadius = bounds.height / 2
            layer.cornerCurve = .continuous
        }
        iconView.frame = bounds
        let labelSize = label.sizeThatFits(bounds.size)
        label.frame = CGRect(x: 10, y: (bounds.height - labelSize.height) / 2, width: max(0, bounds.width - 20), height: labelSize.height)
    }
}

/// Session header. `bar`: full-bleed opaque bar under the status bar with the
/// device name, route badge, live status and mode chip. `rail`: a slim
/// vertical pill for landscape phones (back, route, status, mode glyphs); the
/// textual status then lives in the centered overlay whenever video is not live.
@MainActor
final class RemoteSessionHeaderView: RCView {
    enum Style { case bar, rail }

    var style: Style = .bar { didSet { if style != oldValue { applyStyle() } } }
    var onBack: (() -> Void)?

    let backButton = RCIconButton(icon: .chevronLeft, variant: .stage, diameter: 40, iconSize: 18, accessibilityLabel: "Back to devices")
    private let nameLabel = RCLabel(style: .headline)
    private let pathBadge = RemoteAccessPathBadge()
    private let statusDot = RemoteStatusDot()
    private let statusLabel = RCLabel(style: .caption, color: RCColor.textSecondary)
    private let modeChip = RemoteModeChip()
    private let railDivider = CALayer()
    private let hairline = CALayer()
    private lazy var railStatusElement = UIAccessibilityElement(accessibilityContainer: self)
    private var connectionLabel = ""
    private var modeValue = ""
    private var pathLabel = ""

    static let barContentMinimumHeight: CGFloat = 56
    static let railWidth: CGFloat = 52

    init(deviceName: String, path: RemoteAccessPathPresentation) {
        super.init(frame: .zero)
        nameLabel.text = deviceName
        nameLabel.accessibilityTraits = .header
        pathBadge.configure(path)
        pathLabel = path.accessibilityLabel
        applyStyle()
    }

    override func setUp() {
        layer.addSublayer(hairline)
        layer.addSublayer(railDivider)
        backButton.haptic = .selection
        backButton.onTap = { [weak self] in self?.onBack?() }
        // Dense chrome: shrink slightly before truncating at large text sizes.
        for label in [nameLabel, statusLabel] {
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.78
        }
        [backButton, nameLabel, pathBadge, statusDot, statusLabel, modeChip].forEach(addSubview)
    }

    func apply(_ presentation: RemoteSessionPresentation, animated: Bool) {
        statusDot.configure(tone: presentation.connectionTone, pulsing: presentation.isLive)
        connectionLabel = presentation.connectionLabel
        // Fixed-width frame: a new status text needs no layout pass at regular sizes.
        if statusLabel.text != presentation.connectionLabel {
            statusLabel.text = presentation.connectionLabel
            // Relayout only when the chip placement could change (large text sizes).
            if style == .bar, traitCollection.preferredContentSizeCategory >= .extraExtraLarge { setNeedsLayout() }
        }
        statusLabel.accessibilityLabel = "Status: \(presentation.connectionLabel)"
        modeValue = presentation.modeAccessibilityValue
        if modeChip.configure(presentation, animated: animated), style == .bar {
            setNeedsLayout()
        }
        updateRailAccessibility()
    }

    private func applyStyle() {
        let rail = style == .rail
        nameLabel.isHidden = rail
        statusLabel.isHidden = rail
        pathBadge.isCompact = rail
        modeChip.isCompact = rail
        pathBadge.isAccessibilityElement = !rail
        modeChip.isAccessibilityElement = !rail
        withoutImplicitAnimations {
            hairline.isHidden = rail
            railDivider.isHidden = !rail
            updateAppearance()
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func updateRailAccessibility() {
        railStatusElement.accessibilityLabel = "\(pathLabel). Status: \(connectionLabel). Interaction mode: \(modeValue)"
    }

    override var accessibilityElements: [Any]? {
        get {
            style == .rail ? [backButton, railStatusElement] : [backButton, nameLabel, pathBadge, statusLabel, modeChip]
        }
        set {}
    }

    override func updateAppearance() {
        if style == .bar {
            layer.backgroundColor = RCColor.surface.resolved(for: self).withAlphaComponent(0.96).cgColor
            layer.borderWidth = 0
        } else {
            layer.backgroundColor = RCColor.surface.resolved(for: self).withAlphaComponent(0.96).cgColor
            layer.borderColor = RCColor.line.cgColor(for: self)
            layer.borderWidth = RCLayout.hairline
        }
        hairline.backgroundColor = RCColor.line.cgColor(for: self)
        railDivider.backgroundColor = RCColor.line.cgColor(for: self)
        applyShadow()
    }

    /// Only the floating rail pill casts a shadow; the full-bleed bar has nothing beneath it.
    private func applyShadow() {
        guard style == .rail, bounds.width > 0 else {
            RCShadow.clear(layer)
            return
        }
        RCShadow.floating.apply(to: layer, path: UIBezierPath.continuousRoundedRect(bounds, radius: bounds.width / 2).cgPath, traits: traitCollection)
    }

    /// Bars: content height below the top safe area. Rail: pill size.
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        switch style {
        case .bar:
            let name = RCTypography.lineHeight(.headline, compatibleWith: traitCollection)
            let row = max(pathBadge.sizeThatFits(.zero).height, RCTypography.lineHeight(.caption, compatibleWith: traitCollection))
            return CGSize(width: size.width, height: ceil(max(Self.barContentMinimumHeight, name + 3 + row + 16)))
        case .rail:
            // back 40 · divider · badge 28 · dot 20 · chip 28
            return CGSize(width: Self.railWidth, height: 6 + 40 + 8 + 1 + 8 + 28 + 4 + 20 + 4 + 28 + 10)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitAnimations {
            layer.cornerRadius = style == .rail ? bounds.width / 2 : 0
            layer.cornerCurve = .continuous
            applyShadow()
        }
        switch style {
        case .bar: layoutBar()
        case .rail: layoutRail()
        }
    }

    private func layoutBar() {
        let contentTop = safeAreaInsets.top
        let contentHeight = bounds.height - contentTop
        let centerY = contentTop + contentHeight / 2
        withoutImplicitAnimations {
            hairline.frame = CGRect(x: 0, y: bounds.height - RCLayout.hairline, width: bounds.width, height: RCLayout.hairline)
        }
        let leading = safeAreaInsets.left + RemoteSessionLayout.margin
        let trailing = bounds.width - safeAreaInsets.right - RemoteSessionLayout.margin
        backButton.frame = CGRect(x: leading - 2, y: centerY - 20, width: 40, height: 40)
        let textX = backButton.frame.maxX + 10
        let chipSize = modeChip.sizeThatFits(.zero)
        let nameHeight = RCTypography.lineHeight(.headline, compatibleWith: traitCollection)
        let badgeSize = pathBadge.sizeThatFits(.zero)
        let captionHeight = RCTypography.lineHeight(.caption, compatibleWith: traitCollection)
        let rowHeight = max(badgeSize.height, captionHeight)
        let blockHeight = nameHeight + 3 + rowHeight
        let blockTop = centerY - blockHeight / 2

        // The chip is centered on the whole block unless the status row would
        // truncate beside it; then it sits on the name line and the status row
        // runs to the trailing edge (large text sizes).
        let statusX = textX + badgeSize.width + 8 + 12 + 4
        let statusNeeded = statusLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: captionHeight)).width
        let chipBesideStatus = statusX + statusNeeded <= trailing - chipSize.width - 12
        let chipCenterY = chipBesideStatus ? centerY : blockTop + nameHeight / 2
        modeChip.frame = CGRect(x: trailing - chipSize.width, y: chipCenterY - chipSize.height / 2, width: chipSize.width, height: chipSize.height)

        let nameWidth = max(0, modeChip.frame.minX - 12 - textX)
        nameLabel.frame = CGRect(x: textX, y: blockTop, width: nameWidth, height: nameHeight)
        let rowMid = blockTop + nameHeight + 3 + rowHeight / 2
        let rowTrailing = chipBesideStatus ? modeChip.frame.minX - 12 : trailing
        pathBadge.frame = CGRect(x: textX, y: rowMid - badgeSize.height / 2, width: min(badgeSize.width, max(0, rowTrailing - textX)), height: badgeSize.height)
        statusDot.frame = CGRect(x: pathBadge.frame.maxX + 8, y: rowMid - 6, width: 12, height: 12)
        let labelX = statusDot.frame.maxX + 4
        statusLabel.frame = CGRect(x: labelX, y: rowMid - captionHeight / 2, width: max(0, rowTrailing - labelX), height: captionHeight)
    }

    private func layoutRail() {
        let width = bounds.width
        var y: CGFloat = 6
        backButton.frame = CGRect(x: (width - 40) / 2, y: y, width: 40, height: 40)
        y += 40 + 8
        withoutImplicitAnimations {
            railDivider.frame = CGRect(x: 12, y: y, width: width - 24, height: RCLayout.hairline)
        }
        y += 1 + 8
        pathBadge.frame = CGRect(x: (width - 28) / 2, y: y, width: 28, height: 28)
        y += 28 + 4
        statusDot.frame = CGRect(x: (width - 20) / 2, y: y, width: 20, height: 20)
        y += 20 + 4
        modeChip.frame = CGRect(x: (width - 28) / 2, y: y, width: 28, height: 28)
        railStatusElement.accessibilityFrameInContainerSpace = CGRect(x: 0, y: pathBadge.frame.minY, width: width, height: modeChip.frame.maxY - pathBadge.frame.minY)
    }
}
