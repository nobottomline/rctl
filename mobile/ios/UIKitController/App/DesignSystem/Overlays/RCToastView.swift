import UIKit

/// One toast card: tone icon, title, optional message. Frame layout; the host
/// positions and stacks cards.
@MainActor
final class RCToastView: RCView {
    static let maximumWidth: CGFloat = 420
    private static let insets = UIEdgeInsets(top: 13, left: 14, bottom: 13, right: 16)
    private static let iconSide: CGFloat = 20
    private static let iconGap: CGFloat = 12
    static let minimumHeight: CGFloat = 52

    let id = UUID()
    let title: String
    let message: String?
    let tone: RCToast.Tone
    let position: RCToast.Position
    let duration: TimeInterval

    /// Holds icon and text so collapsed (stacked-behind) cards can hide their content.
    let contentView = UIView()
    private let iconView: RCIconView
    private let titleLabel = RCLabel(style: .subheadlineStrong, lines: 2)
    private let messageLabel = RCLabel(style: .footnote, color: RCColor.textSecondary, lines: 3)

    // Host-owned state.
    var remaining: TimeInterval
    var timerStartedAt: TimeInterval?
    var timerGeneration = 0
    var isDismissing = false
    var onDismissRequest: ((RCToastView) -> Void)?

    init(title: String, message: String?, tone: RCToast.Tone, icon: RCIconGlyph?, duration: TimeInterval, position: RCToast.Position) {
        self.title = title
        self.message = message?.isEmpty == true ? nil : message
        self.tone = tone
        self.position = position
        self.duration = duration
        remaining = duration
        iconView = RCIconView(icon ?? Self.defaultGlyph(for: tone), pointSize: Self.iconSide)
        super.init(frame: .zero)
        titleLabel.text = title
        messageLabel.text = self.message
        messageLabel.isHidden = self.message == nil
        contentView.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(messageLabel)
        updateAppearance()
        isAccessibilityElement = true
        accessibilityLabel = [Self.tonePrefix(for: tone), title].compactMap { $0 }.joined(separator: ": ")
        accessibilityValue = self.message
        accessibilityTraits = .staticText
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Dismiss", target: self, selector: #selector(accessibilityDismiss))]
    }

    static func defaultGlyph(for tone: RCToast.Tone) -> RCIconGlyph {
        switch tone {
        case .info: .info
        case .success: .circleCheck
        case .warning: .triangleAlert
        case .error: .circleAlert
        }
    }

    /// Spoken prefix so the tone is not conveyed by icon color alone.
    static func tonePrefix(for tone: RCToast.Tone) -> String? {
        switch tone {
        case .info: nil
        case .success: "Success"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    override func setUp() {
        layer.cornerRadius = RCRadius.xl
        layer.cornerCurve = .continuous
        contentView.isUserInteractionEnabled = false
        addSubview(contentView)
    }

    override func updateAppearance() {
        layer.backgroundColor = RCColor.elevated.cgColor(for: self)
        layer.borderColor = RCColor.line.cgColor(for: self)
        layer.borderWidth = RCLayout.hairline
        let shadow = RCShadow.popover
        layer.shadowColor = RCColor.shadow.cgColor(for: self)
        layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? shadow.opacityDark : shadow.opacityLight
        layer.shadowRadius = shadow.radius
        layer.shadowOffset = position == .top ? CGSize(width: 0, height: shadow.offset.height * 0.6) : CGSize(width: 0, height: shadow.offset.height * 0.4)
        iconView.tintColor = switch tone {
        case .info: RCColor.textSecondary
        case .success: RCColor.success
        case .warning: RCColor.accent
        case .error: RCColor.danger
        }
    }

    private func textWidth(for width: CGFloat) -> CGFloat {
        max(0, width - Self.insets.left - Self.iconSide - Self.iconGap - Self.insets.right)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = textWidth(for: size.width)
        var text = titleLabel.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
        if !messageLabel.isHidden {
            text += 2 + messageLabel.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
        }
        let height = max(Self.minimumHeight, ceil(text + Self.insets.top + Self.insets.bottom))
        return CGSize(width: size.width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        RCModalSupport.setShadowPath(UIBezierPath.continuousRoundedRect(bounds, radius: RCRadius.xl).cgPath, on: layer)
        // Content keeps its natural height; collapsed cards only show their silhouette.
        let natural = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        contentView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: natural)
        let inner = textWidth(for: bounds.width)
        var textHeight = titleLabel.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
        let messageHeight = messageLabel.isHidden ? 0 : messageLabel.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
        if !messageLabel.isHidden { textHeight += 2 + messageHeight }
        let top = (natural - textHeight) / 2
        let x = Self.insets.left + Self.iconSide + Self.iconGap
        titleLabel.frame = CGRect(x: x, y: top, width: inner, height: textHeight - (messageLabel.isHidden ? 0 : 2 + messageHeight))
        messageLabel.frame = CGRect(x: x, y: titleLabel.frame.maxY + 2, width: inner, height: messageHeight)
        let firstLine = RCTypography.lineHeight(.subheadlineStrong, compatibleWith: traitCollection)
        iconView.frame = CGRect(x: Self.insets.left, y: top + (firstLine - Self.iconSide) / 2, width: Self.iconSide, height: Self.iconSide)
    }

    override func accessibilityPerformEscape() -> Bool {
        onDismissRequest?(self)
        return true
    }

    @objc private func accessibilityDismiss() -> Bool {
        onDismissRequest?(self)
        return true
    }
}
