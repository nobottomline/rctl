import UIKit

/// Shows exactly what "Replace address and connect" changes: the saved
/// device, its current address (struck through) and the discovered address
/// that replaces it. A quiet inline arrow on the divider reads the change
/// from top to bottom; it is decoration, not a control.
@MainActor
final class LocalDeviceAddressChangeView: RCSurfaceView {
    private let change: LocalDeviceEditorContent.AddressChange

    private let tile = RCIconTile(glyph: .repeat, tone: .accent, side: 32)
    private let titleLabel = RCLabel(style: .calloutStrong, lines: 0)
    private let well = UIView()
    private let divider = CALayer()
    private let currentCaption = RCLabel("Current", style: .caption, color: RCColor.textTertiary, lines: 0)
    private let currentValue = UILabel()
    private let foundCaption = RCLabel(style: .caption, color: RCColor.accentText, lines: 0)
    private let foundValue = UILabel()
    private static let arrowSide: CGFloat = 14
    private let arrow = RCIconView(.arrowDown, pointSize: LocalDeviceAddressChangeView.arrowSide, strokeWidth: 2)
    private let footnote = RCLabel(LocalDeviceEditorContent.addressChangeFootnote, style: .footnote, color: RCColor.textTertiary, lines: 0)

    private static let padding: CGFloat = RCSpace.lg
    private static let wellPadding = UIEdgeInsets(top: RCSpace.md, left: 14, bottom: RCSpace.md, right: 14)
    /// Space above and below the divider; clears the arrow centered on it.
    private var dividerGap: CGFloat { max(RCSpace.md, (arrow.pointSize / 2).rounded(.up) + RCSpace.xs) }
    /// Between the arrow and the start of the divider line.
    private static let arrowGap: CGFloat = RCSpace.sm

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
        arrow.isUserInteractionEnabled = false
        arrow.isAccessibilityElement = false
        well.addSubview(arrow)
        [tile, titleLabel, well, footnote].forEach(contentView.addSubview)
    }

    override func updateAppearance() {
        super.updateAppearance()
        withoutImplicitAnimations {
            well.layer.backgroundColor = RCColor.surfaceSunken.cgColor(for: self)
            divider.backgroundColor = RCColor.line.cgColor(for: self)
        }
        arrow.tintColor = RCColor.textTertiary
        rebuildAddresses()
    }

    override func updateTypography() {
        super.updateTypography()
        // The arrow reads with the captions around it, so it scales with them.
        arrow.pointSize = min(22, (Self.arrowSide * RCTypography.scale(for: .caption, compatibleWith: traitCollection)).rounded())
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
        var found = RCTypography.attributes(.mono, color: RCColor.accentText, lineBreakMode: .byCharWrapping, compatibleWith: traits)
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
        let side = arrow.pointSize
        let textWidth = max(0, width - insets.left - insets.right)
        func place(_ view: UIView, at wellY: inout CGFloat, gap: CGFloat) {
            let height = ceil(view.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
            if apply { view.frame = CGRect(x: insets.left, y: wellY, width: textWidth, height: height) }
            wellY += height + gap
        }
        var wellY = insets.top
        place(currentCaption, at: &wellY, gap: RCSpace.xxs)
        place(currentValue, at: &wellY, gap: dividerGap)
        let dividerY = RCLayout.pixelAligned(wellY)
        wellY += dividerGap
        place(foundCaption, at: &wellY, gap: RCSpace.xxs)
        place(foundValue, at: &wellY, gap: insets.bottom)
        if apply {
            well.frame = CGRect(x: 0, y: y, width: width, height: wellY)
            // "↓ ────": the arrow sits at the text column's leading edge, the line follows it.
            let lineX = insets.left + side + Self.arrowGap
            withoutImplicitAnimations {
                divider.frame = CGRect(x: lineX, y: dividerY, width: max(0, width - lineX), height: RCLayout.hairline)
            }
            arrow.frame = RCLayout.pixelAligned(CGRect(x: insets.left, y: dividerY - side / 2, width: side, height: side))
        }
        y += wellY + RCSpace.md

        let footnoteHeight = ceil(footnote.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        if apply { footnote.frame = CGRect(x: 0, y: y, width: width, height: footnoteHeight) }
        return y + footnoteHeight
    }
}
