import UIKit

/// Tappable list row: leading tile, title, detail, trailing badge/accessory.
/// Frame-based layout with a cached height; the row never rebuilds subviews
/// when reconfigured.
@MainActor
final class RCListRow: RCControl {
    enum Trailing: Equatable {
        case none
        case chevron
        case plus
        case badge(text: String, tone: RCStatusBadge.Tone, busy: Bool)
        case badgeAndChevron(text: String, tone: RCStatusBadge.Tone, busy: Bool)
        case check
    }

    struct Content: Equatable {
        var title: String
        var detail: String?
        /// Render the detail in SF Mono (addresses, endpoints).
        var detailIsMonospaced = false
        var glyph: RCIconGlyph?
        var tileTone: RCIconTile.Tone = .accent
        var trailing: Trailing = .chevron
        /// Dimmed look for unavailable items; the row still sends taps.
        var appearsEnabled = true

        init(title: String, detail: String? = nil, detailIsMonospaced: Bool = false, glyph: RCIconGlyph? = nil, tileTone: RCIconTile.Tone = .accent, trailing: Trailing = .chevron, appearsEnabled: Bool = true) {
            self.title = title
            self.detail = detail
            self.detailIsMonospaced = detailIsMonospaced
            self.glyph = glyph
            self.tileTone = tileTone
            self.trailing = trailing
            self.appearsEnabled = appearsEnabled
        }
    }

    private(set) var content: Content
    var onTap: (() -> Void)?
    var haptic: RCHaptics.Kind? = .light

    private let tile: RCIconTile
    private let titleLabel = RCLabel(style: .bodyStrong, lines: 2)
    private let detailLabel = RCLabel(style: .footnote, color: RCColor.textTertiary)
    private let badge = RCStatusBadge()
    private let accessoryIcon = RCIconView(pointSize: 16)
    private let highlightLayer = CALayer()

    private static let insets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 14)

    init(content: Content) {
        self.content = content
        tile = RCIconTile(glyph: content.glyph ?? .tabletSmartphone, tone: content.tileTone)
        super.init(frame: .zero)
        addSubview(tile)
        configure(content)
    }

    override func setUp() {
        isAccessibilityElement = true
        accessibilityTraits = .button
        layer.addSublayer(highlightLayer)
        highlightLayer.opacity = 0
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(badge)
        addSubview(accessoryIcon)
        addTarget(self, action: #selector(handleTap), for: .primaryActionTriggered)
    }

    func configure(_ content: Content, animated: Bool = false) {
        self.content = content
        titleLabel.text = content.title
        detailLabel.text = content.detail
        detailLabel.style = content.detailIsMonospaced ? .monoSmall : .footnote
        tile.isHidden = content.glyph == nil
        if let glyph = content.glyph { tile.glyph = glyph }
        tile.tone = content.appearsEnabled ? content.tileTone : .muted
        titleLabel.color = content.appearsEnabled ? RCColor.text : RCColor.textSecondary
        switch content.trailing {
        case let .badge(text, tone, busy), let .badgeAndChevron(text, tone, busy):
            badge.isHidden = false
            badge.configure(text: text, tone: tone, busy: busy, animated: animated)
        default:
            badge.isHidden = true
        }
        switch content.trailing {
        case .chevron, .badgeAndChevron: accessoryIcon.glyph = .chevronRight; accessoryIcon.isHidden = false
        case .plus: accessoryIcon.glyph = .plus; accessoryIcon.isHidden = false
        case .check: accessoryIcon.glyph = .check; accessoryIcon.isHidden = false
        case .none, .badge: accessoryIcon.isHidden = true
        }
        accessibilityLabel = [content.title, badge.isHidden ? nil : badge.text].compactMap { $0 }.joined(separator: ", ")
        accessibilityValue = content.detail
        setNeedsLayout()
    }

    override func updateAppearance() {
        highlightLayer.backgroundColor = RCColor.pressWash.cgColor(for: self)
        accessoryIcon.tintColor = content.trailing == .check ? RCColor.accent : RCColor.textQuaternary
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            if isHighlighted, let haptic { RCHaptics.prepare(haptic) }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.duration = isHighlighted ? RCMotion.pressDuration : RCMotion.releaseDuration
            highlightLayer.add(fade, forKey: "opacity")
            highlightLayer.opacity = isHighlighted ? 1 : 0
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textWidth = textColumnWidth(for: size.width)
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let detailHeight = content.detail == nil ? 0 : detailLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height + 2
        let textHeight = titleHeight + detailHeight
        return CGSize(width: size.width, height: ceil(max(tile.isHidden ? 44 : tile.side, textHeight) + Self.insets.top + Self.insets.bottom))
    }

    private func trailingWidth() -> CGFloat {
        var width: CGFloat = 0
        if !badge.isHidden { width += badge.sizeThatFits(.zero).width + RCSpace.sm }
        if !accessoryIcon.isHidden { width += 16 + RCSpace.xs }
        return width
    }

    private func textColumnWidth(for width: CGFloat) -> CGFloat {
        let leading = Self.insets.left + (tile.isHidden ? 0 : tile.side + RCSpace.md)
        return max(0, width - leading - trailingWidth() - Self.insets.right)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitAnimations {
            highlightLayer.frame = bounds.insetBy(dx: 4, dy: 2)
            highlightLayer.cornerRadius = RCRadius.md
            highlightLayer.cornerCurve = .continuous
        }
        var x = Self.insets.left
        if !tile.isHidden {
            tile.frame = CGRect(x: x, y: (bounds.height - tile.side) / 2, width: tile.side, height: tile.side)
            x += tile.side + RCSpace.md
        }
        var trailingX = bounds.width - Self.insets.right
        if !accessoryIcon.isHidden {
            trailingX -= 16
            accessoryIcon.frame = CGRect(x: trailingX, y: (bounds.height - 16) / 2, width: 16, height: 16)
            trailingX -= RCSpace.xs
        }
        if !badge.isHidden {
            let badgeSize = badge.sizeThatFits(.zero)
            trailingX -= badgeSize.width
            badge.frame = CGRect(x: trailingX, y: (bounds.height - badgeSize.height) / 2, width: badgeSize.width, height: badgeSize.height)
            trailingX -= RCSpace.sm
        }
        let width = max(0, trailingX - x)
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let detailHeight = content.detail == nil ? 0 : detailLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let total = titleHeight + (content.detail == nil ? 0 : detailHeight + 2)
        var y = (bounds.height - total) / 2
        titleLabel.frame = CGRect(x: x, y: y, width: width, height: titleHeight)
        y += titleHeight + 2
        detailLabel.frame = CGRect(x: x, y: y, width: width, height: detailHeight)
    }

    @objc private func handleTap() {
        if let haptic { RCHaptics.play(haptic) }
        onTap?()
    }
}

/// Card that stacks arbitrary row views with inset hairline separators and
/// animates insertions, removals and height changes.
@MainActor
final class RCListGroupView: RCSurfaceView {
    struct Item {
        let id: String
        let view: UIView
        init(id: String, view: UIView) {
            self.id = id
            self.view = view
        }
    }

    /// Leading inset of separators (aligns with row text after the tile).
    var separatorInset: CGFloat = 12 + 40 + 12 { didSet { setNeedsLayout() } }
    private(set) var items: [Item] = []
    private var separators: [RCSeparator] = []

    init() {
        super.init(style: .card, cornerRadius: RCRadius.lg)
        contentInsets = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
    }

    /// Replaces the rows. Views are matched by `id`; reused views keep their
    /// identity, new ones fade in, removed ones fade out. Callers should
    /// animate the enclosing layout alongside when `animated` is true.
    func setItems(_ newItems: [Item], animated: Bool) {
        let newIDs = Set(newItems.map(\.id))
        let removed = items.filter { !newIDs.contains($0.id) }
        for item in removed {
            if animated {
                RCMotion.animate(duration: RCMotion.quickDuration, animations: { item.view.alpha = 0 }, completion: { _ in
                    if !newItems.contains(where: { $0.view === item.view }) { item.view.removeFromSuperview() }
                    item.view.alpha = 1
                })
            } else {
                item.view.removeFromSuperview()
            }
        }
        let oldIDs = Set(items.map(\.id))
        for item in newItems where item.view.superview !== contentView {
            contentView.addSubview(item.view)
            if animated, !oldIDs.contains(item.id) {
                item.view.alpha = 0
                RCMotion.animate(duration: RCMotion.quickDuration, delay: 0.05) { item.view.alpha = 1 }
            }
        }
        items = newItems
        while separators.count < max(0, items.count - 1) {
            let separator = RCSeparator()
            contentView.addSubview(separator)
            separators.append(separator)
        }
        for (index, separator) in separators.enumerated() {
            separator.isHidden = index >= items.count - 1
        }
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let height = items.reduce(CGFloat(0)) { $0 + $1.view.sizeThatFits(CGSize(width: size.width, height: .greatestFiniteMagnitude)).height }
        return CGSize(width: size.width, height: ceil(height + contentInsets.top + contentInsets.bottom))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var y: CGFloat = 0
        let width = contentView.bounds.width
        for (index, item) in items.enumerated() {
            let height = item.view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            item.view.frame = CGRect(x: 0, y: y, width: width, height: height)
            y += height
            if index < items.count - 1, index < separators.count {
                separators[index].frame = CGRect(x: separatorInset, y: y - RCLayout.hairline / 2, width: width - separatorInset - 14, height: RCLayout.hairline)
                contentView.bringSubviewToFront(separators[index])
            }
        }
    }
}
