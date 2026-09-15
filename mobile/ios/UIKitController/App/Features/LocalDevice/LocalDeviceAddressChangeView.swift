import UIKit

/// Shows exactly what "Replace address and connect" changes: the saved
/// device, its current address (struck through) and the discovered address
/// that replaces it, joined by a change badge on the divider.
@MainActor
final class LocalDeviceAddressChangeView: RCSurfaceView {
    private let change: LocalDeviceEditorContent.AddressChange

    private let tile = RCIconTile(glyph: .repeat, tone: .accent, side: 32)
    private let titleLabel = RCLabel(style: .calloutStrong, lines: 0)
    private let well = UIView()
    private let divider = CALayer()
    private let currentCaption = RCLabel("Current", style: .caption, color: RCColor.textTertiary, lines: 0)
    private let currentValue = UILabel()
    private let foundCaption = RCLabel(style: .caption, color: RCColor.accent, lines: 0)
    private let foundValue = UILabel()
    private let badge = UIView()
    private let badgeIcon = RCIconView(.arrowDown, pointSize: 14, strokeWidth: 2.25)
    private let footnote = RCLabel(LocalDeviceEditorContent.addressChangeFootnote, style: .footnote, color: RCColor.textTertiary, lines: 0)

    private static let padding: CGFloat = RCSpace.lg
    private static let wellPadding = UIEdgeInsets(top: RCSpace.md, left: 14, bottom: RCSpace.md, right: 14)
    private static let badgeSide: CGFloat = 28
    /// Space above and below the divider; clears the badge so rows keep the full width.
    private static let dividerGap: CGFloat = RCSpace.lg

    init(change: LocalDeviceEditorContent.AddressChange) {
        self.change = change
        super.init(style: .card, cornerRadius: RCRadius.lg)
        contentInsets = UIEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        titleLabel.text = "Saved device “\(change.deviceName)”"
        foundCaption.text = "Found as “\(change.discoveredName)”"
        isAccessibilityElement = true
        accessibilityLabel = [
            "Saved device “\(change.deviceName)”",
            "Current address \(change.currentAddress)",
            "Found as “\(change.discoveredName)” at \(change.newAddress)",
            LocalDeviceEditorContent.addressChangeFootnote,
        ].joined(separator: ". ")
    }

    override func setUp() {
        super.setUp()
        well.isUserInteractionEnabled = false
        well.layer.cornerRadius = RCRadius.md
        well.layer.cornerCurve = .continuous
        well.layer.addSublayer(divider)
        currentValue.numberOfLines = 0
        foundValue.numberOfLines = 0
        [currentCaption, currentValue, foundCaption, foundValue].forEach(well.addSubview)
        badge.isUserInteractionEnabled = false
        badge.layer.cornerRadius = Self.badgeSide / 2
        badge.addSubview(badgeIcon)
        well.addSubview(badge)
        [tile, titleLabel, well, footnote].forEach(contentView.addSubview)
    }

    override func updateAppearance() {
        super.updateAppearance()
        withoutImplicitAnimations {
            well.layer.backgroundColor = RCColor.surfaceSunken.cgColor(for: self)
            divider.backgroundColor = RCColor.line.cgColor(for: self)
            badge.layer.backgroundColor = RCColor.elevated.cgColor(for: self)
            badge.layer.borderColor = RCColor.lineStrong.cgColor(for: self)
            badge.layer.borderWidth = RCLayout.hairline
        }
        badgeIcon.tintColor = RCColor.accent
        rebuildAddresses()
    }

    override func updateTypography() {
        super.updateTypography()
        rebuildAddresses()
        setNeedsLayout()
    }

    /// Attributed addresses (strikethrough, emphasized weight) depend on both
    /// Dynamic Type and appearance, so they are rebuilt for either change.
    private func rebuildAddresses() {
        let traits = traitCollection
        var current = RCTypography.attributes(.mono, color: RCColor.textSecondary, lineBreakMode: .byCharWrapping, compatibleWith: traits)
        current[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        current[.strikethroughColor] = RCColor.textTertiary
        currentValue.attributedText = NSAttributedString(string: change.currentAddress, attributes: current)
        var found = RCTypography.attributes(.mono, color: RCColor.accent, lineBreakMode: .byCharWrapping, compatibleWith: traits)
        // Same scaled size as the `.mono` token, emphasized.
        let size = RCTypography.font(.mono, compatibleWith: traits).pointSize
        found[.font] = UIFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        foundValue.attributedText = NSAttributedString(string: change.newAddress, attributes: found)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = max(0, size.width - Self.padding * 2)
        return CGSize(width: size.width, height: ceil(layout(width: inner, apply: false) + Self.padding * 2))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = layout(width: contentView.bounds.width, apply: true)
    }

    /// One pass for measuring and placing, in `contentView` coordinates. Returns the content height.
    private func layout(width: CGFloat, apply: Bool) -> CGFloat {
        let titleX = tile.side + RCSpace.md
        let titleWidth = max(0, width - titleX)
        let titleHeight = ceil(titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        let headerHeight = max(tile.side, titleHeight)
        if apply {
            tile.frame = CGRect(x: 0, y: (headerHeight - tile.side) / 2, width: tile.side, height: tile.side)
            titleLabel.frame = CGRect(x: titleX, y: (headerHeight - titleHeight) / 2, width: titleWidth, height: titleHeight)
        }
        var y = headerHeight + RCSpace.md + 2

        let insets = Self.wellPadding
        let side = Self.badgeSide
        let textWidth = max(0, width - insets.left - insets.right)
        func place(_ view: UIView, at wellY: inout CGFloat, gap: CGFloat) {
            let height = ceil(view.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
            if apply { view.frame = CGRect(x: insets.left, y: wellY, width: textWidth, height: height) }
            wellY += height + gap
        }
        var wellY = insets.top
        place(currentCaption, at: &wellY, gap: RCSpace.xxs)
        place(currentValue, at: &wellY, gap: Self.dividerGap)
        let dividerY = RCLayout.pixelAligned(wellY)
        wellY += Self.dividerGap
        place(foundCaption, at: &wellY, gap: RCSpace.xxs)
        place(foundValue, at: &wellY, gap: insets.bottom)
        if apply {
            well.frame = CGRect(x: 0, y: y, width: width, height: wellY)
            withoutImplicitAnimations {
                divider.frame = CGRect(x: 0, y: dividerY, width: width, height: RCLayout.hairline)
            }
            badge.frame = RCLayout.pixelAligned(CGRect(x: width - insets.right - side, y: dividerY - side / 2, width: side, height: side))
            badgeIcon.frame = badge.bounds
        }
        y += wellY + RCSpace.md

        let footnoteHeight = ceil(footnote.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        if apply { footnote.frame = CGRect(x: 0, y: y, width: width, height: footnoteHeight) }
        return y + footnoteHeight
    }
}
