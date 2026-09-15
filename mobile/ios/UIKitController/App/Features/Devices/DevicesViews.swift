import UIKit

// Building blocks private to the Devices screen. All use frame layout with
// accurate `sizeThatFits`, never rebuild subviews on reconfiguration, and take
// colors, type and spacing from the design-system tokens.

/// Brand mark and wordmark at the leading edge of the top bar.
@MainActor
final class DevicesBrandView: RCView {
    private let mark = RCBrandMark(side: 28)
    private let wordmark = RCLabel("rctl", style: .headline)

    override func setUp() {
        isAccessibilityElement = true
        accessibilityLabel = "rctl"
        accessibilityTraits = .staticText
        addSubview(mark)
        addSubview(wordmark)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let label = wordmark.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: size.height))
        return CGSize(width: ceil(mark.side + RCSpace.sm + label.width), height: max(mark.side, ceil(label.height)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        mark.frame = CGRect(x: 0, y: (bounds.height - mark.side) / 2, width: mark.side, height: mark.side)
        let label = wordmark.sizeThatFits(bounds.size)
        let x = mark.side + RCSpace.sm
        wordmark.frame = RCLayout.pixelAligned(CGRect(x: x, y: (bounds.height - label.height) / 2, width: bounds.width - x, height: label.height))
    }
}

/// "2 online · 5 devices" under the large title, with a success dot while
/// anything is online. Text changes crossfade.
@MainActor
final class DevicesSummaryView: RCView {
    private let label = RCLabel(style: .callout, color: RCColor.textSecondary, lines: 0)
    private let dot = CALayer()
    private(set) var showsDot = false
    private static let dotSide: CGFloat = 7

    override func setUp() {
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        dot.opacity = 0
        layer.addSublayer(dot)
        addSubview(label)
    }

    override func updateAppearance() {
        dot.backgroundColor = RCColor.success.cgColor(for: self)
    }

    func configure(text: String, showsDot: Bool, animated: Bool) {
        let changed = text != label.text || showsDot != self.showsDot
        guard changed else { return }
        if animated, label.text != nil {
            UIView.transition(with: label, duration: RCMotion.quickDuration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
                self.label.text = text
            }
        } else {
            label.text = text
        }
        accessibilityLabel = text
        if showsDot != self.showsDot {
            self.showsDot = showsDot
            let opacity: Float = showsDot ? 1 : 0
            if animated {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = dot.presentation()?.opacity ?? dot.opacity
                fade.duration = RCMotion.quickDuration
                dot.add(fade, forKey: "opacity")
            }
            withoutImplicitAnimations { dot.opacity = opacity }
        }
        setNeedsLayout()
    }

    private var textInset: CGFloat { showsDot ? Self.dotSide + RCSpace.sm : 0 }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let height = label.sizeThatFits(CGSize(width: max(0, size.width - textInset), height: .greatestFiniteMagnitude)).height
        return CGSize(width: size.width, height: ceil(height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let lineHeight = RCTypography.lineHeight(.callout, compatibleWith: traitCollection)
        withoutImplicitAnimations {
            dot.frame = CGRect(x: 0, y: (lineHeight - Self.dotSide) / 2, width: Self.dotSide, height: Self.dotSide)
            dot.cornerRadius = Self.dotSide / 2
        }
        let width = bounds.width - textInset
        let height = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        label.frame = CGRect(x: textInset, y: 0, width: width, height: height)
    }
}

/// Horizontal run of small views (section header accessories). Hidden views
/// take no space.
@MainActor
final class DevicesAccessoryStack: UIView {
    var spacing: CGFloat = RCSpace.xxs
    var arrangedViews: [UIView] = [] {
        didSet {
            oldValue.filter { old in !arrangedViews.contains { $0 === old } }.forEach { $0.removeFromSuperview() }
            arrangedViews.forEach(addSubview)
            setNeedsLayout()
        }
    }

    private var visible: [UIView] { arrangedViews.filter { !$0.isHidden } }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let sizes = visible.map { $0.sizeThatFits(size) }
        guard !sizes.isEmpty else { return .zero }
        let width = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(sizes.count - 1)
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        for view in visible {
            let size = view.sizeThatFits(bounds.size)
            view.frame = CGRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            x += size.width + spacing
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Small buttons extend their hit areas to 44 pt beyond this container.
        visible.contains { $0.point(inside: convert(point, to: $0), with: event) } || super.point(inside: point, with: event)
    }
}

/// Status or notice row inside a list group: quiet tile (glyph or spinner),
/// title, message and optional small actions. Used for discovery notices,
/// the searching row and the relay placeholder.
@MainActor
final class DevicesStatusRowView: RCView {
    struct Action {
        let title: String
        let isProminent: Bool
        let identifier: String?
        let handler: @MainActor () -> Void

        init(_ title: String, prominent: Bool = false, identifier: String? = nil, handler: @escaping @MainActor () -> Void) {
            self.title = title
            isProminent = prominent
            self.identifier = identifier
            self.handler = handler
        }
    }

    private let tile = UIView()
    private let iconView = RCIconView(pointSize: 18)
    private let spinner = RCSpinner(diameter: 18, lineWidth: 2)
    private let titleLabel = RCLabel(style: .bodyStrong, lines: 0)
    private let messageLabel = RCLabel(style: .footnote, color: RCColor.textTertiary, lines: 0)
    private var buttons: [RCButton] = []
    private var handlers: [@MainActor () -> Void] = []

    private static let insets = UIEdgeInsets(top: 12, left: 12, bottom: 14, right: 14)
    private static let tileSide: CGFloat = 40
    private static let buttonSpacing: CGFloat = RCSpace.sm

    override func setUp() {
        tile.isUserInteractionEnabled = false
        tile.addSubview(iconView)
        spinner.hidesWhenStopped = true
        tile.addSubview(spinner)
        addSubview(tile)
        titleLabel.isAccessibilityElement = true
        messageLabel.isAccessibilityElement = false
        addSubview(titleLabel)
        addSubview(messageLabel)
    }

    override func updateAppearance() {
        tile.layer.backgroundColor = RCColor.surfaceSunken.cgColor(for: self)
        iconView.tintColor = RCColor.textTertiary
        spinner.tintColor = RCColor.accent
    }

    func configure(glyph: RCIconGlyph?, busy: Bool, title: String, message: String, actions: [Action] = []) {
        iconView.glyph = glyph
        iconView.isHidden = busy
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        titleLabel.text = title
        messageLabel.text = message
        titleLabel.accessibilityLabel = "\(title), \(message)"
        titleLabel.accessibilityTraits = busy ? [.staticText, .updatesFrequently] : .staticText
        if buttons.map({ $0.title ?? "" }) != actions.map(\.title) || buttons.map(\.variant) != actions.map(Self.variant(for:)) {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = actions.enumerated().map { index, action in
                let button = RCButton(title: action.title, variant: Self.variant(for: action), size: .small)
                button.onTap = { [weak self] in
                    guard let self, index < self.handlers.count else { return }
                    self.handlers[index]()
                }
                addSubview(button)
                return button
            }
        }
        for (button, action) in zip(buttons, actions) { button.accessibilityIdentifier = action.identifier }
        handlers = actions.map(\.handler)
        accessibilityElements = [titleLabel] + buttons
        setNeedsLayout()
    }

    private static func variant(for action: Action) -> RCButton.Variant {
        action.isProminent ? .primary : .secondary
    }

    private func textWidth(for width: CGFloat) -> CGFloat {
        max(0, width - Self.insets.left - Self.tileSide - RCSpace.md - Self.insets.right)
    }

    /// Button frames relative to the text column; wraps to one button per line when they do not fit.
    private func buttonFrames(width: CGFloat) -> [CGRect] {
        let sizes = buttons.map { $0.sizeThatFits(CGSize(width: width, height: RCButton.Size.small.height)) }
        let total = sizes.reduce(0) { $0 + $1.width } + Self.buttonSpacing * CGFloat(max(0, sizes.count - 1))
        var frames: [CGRect] = []
        if total <= width {
            var x: CGFloat = 0
            for size in sizes {
                frames.append(CGRect(x: x, y: 0, width: size.width, height: size.height))
                x += size.width + Self.buttonSpacing
            }
        } else {
            // Stacked buttons share one width so their edges line up.
            let stackedWidth = min(width, sizes.map(\.width).max() ?? 0)
            var y: CGFloat = 0
            for size in sizes {
                frames.append(CGRect(x: 0, y: y, width: stackedWidth, height: size.height))
                y += size.height + Self.buttonSpacing
            }
        }
        return frames
    }

    private func textHeights(width: CGFloat) -> (title: CGFloat, message: CGFloat) {
        let fit = CGSize(width: width, height: .greatestFiniteMagnitude)
        return (titleLabel.sizeThatFits(fit).height, messageLabel.sizeThatFits(fit).height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = textWidth(for: size.width)
        let text = textHeights(width: width)
        var height = text.title + RCSpace.xxs + text.message
        if let last = buttonFrames(width: width).last { height += RCSpace.md + last.maxY }
        return CGSize(width: size.width, height: ceil(max(Self.tileSide, height) + Self.insets.top + Self.insets.bottom))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = textWidth(for: bounds.width)
        let text = textHeights(width: width)
        let buttonFrames = buttonFrames(width: width)
        let textBlock = text.title + RCSpace.xxs + text.message
        let contentHeight = textBlock + (buttonFrames.last.map { RCSpace.md + $0.maxY } ?? 0)
        let x = Self.insets.left + Self.tileSide + RCSpace.md
        // Short content centers on the tile; taller notices align to the top.
        var y = contentHeight < Self.tileSide ? Self.insets.top + (Self.tileSide - textBlock) / 2 : Self.insets.top
        tile.frame = CGRect(x: Self.insets.left, y: Self.insets.top, width: Self.tileSide, height: Self.tileSide)
        tile.applyCornerRadius(Self.tileSide * 0.28)
        iconView.frame = tile.bounds
        spinner.frame = tile.bounds
        titleLabel.frame = CGRect(x: x, y: y, width: width, height: text.title)
        y += text.title + RCSpace.xxs
        messageLabel.frame = CGRect(x: x, y: y, width: width, height: text.message)
        y += text.message + RCSpace.md
        for (button, frame) in zip(buttons, buttonFrames) {
            button.frame = frame.offsetBy(dx: x, dy: y)
        }
    }
}

/// Small print under a group: optional leading glyph and wrapping text.
@MainActor
final class DevicesFootnoteView: RCView {
    var glyph: RCIconGlyph? { didSet { iconView.glyph = glyph; iconView.isHidden = glyph == nil; setNeedsLayout() } }
    var text: String? { didSet { label.text = text; label.accessibilityLabel = text; setNeedsLayout() } }
    var style: RCTextStyle = .caption { didSet { label.style = style; setNeedsLayout() } }
    var color: UIColor = RCColor.textTertiary { didSet { label.color = color; updateAppearance() } }
    var truncatesMiddle = false { didSet { label.numberOfLines = truncatesMiddle ? 1 : 0; label.lineBreakMode = truncatesMiddle ? .byTruncatingMiddle : .byWordWrapping } }

    private let iconView = RCIconView(pointSize: 12, strokeWidth: 2.25)
    private let label = RCLabel(style: .caption, color: RCColor.textTertiary, lines: 0)
    private static let horizontalInset: CGFloat = 6
    private static let iconGap: CGFloat = 6

    override func setUp() {
        iconView.isHidden = true
        iconView.isAccessibilityElement = false
        addSubview(iconView)
        addSubview(label)
    }

    override func updateAppearance() {
        iconView.tintColor = color
    }

    private var textX: CGFloat {
        Self.horizontalInset + (glyph == nil ? 0 : iconView.pointSize + Self.iconGap)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        guard text?.isEmpty == false else { return CGSize(width: size.width, height: 0) }
        let width = max(0, size.width - textX - Self.horizontalInset)
        return CGSize(width: size.width, height: ceil(label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, bounds.width - textX - Self.horizontalInset)
        let height = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        label.frame = CGRect(x: textX, y: 0, width: width, height: height)
        let lineHeight = RCTypography.lineHeight(style, compatibleWith: traitCollection)
        let side = iconView.pointSize
        iconView.frame = RCLayout.pixelAligned(CGRect(x: Self.horizontalInset, y: (lineHeight - side) / 2, width: side, height: side))
    }
}

/// One screen section: overline header, grouped rows, optional footnote.
/// Rows are keyed; reused views keep identity so state changes animate in place.
@MainActor
final class DevicesSectionView: RCView {
    let header: RCSectionHeader
    let group = RCListGroupView()
    let footnote = DevicesFootnoteView()

    private static let headerGap: CGFloat = RCSpace.sm
    private static let footnoteGap: CGFloat = RCSpace.sm + 2

    init(title: String) {
        header = RCSectionHeader(title: title)
        super.init(frame: .zero)
        addSubview(header)
        addSubview(group)
        addSubview(footnote)
        footnote.alpha = 0
        footnote.accessibilityElementsHidden = true
    }

    private(set) var showsFootnote = false

    /// Replaces the rows; the group animates insertions, removals and its height.
    func setRows(_ items: [RCListGroupView.Item], animated: Bool) {
        guard group.isShowingPlaceholder || group.items.map(\.id) != items.map(\.id) else { return }
        group.setItems(items, animated: animated)
    }

    /// Shows or hides the footnote. Hidden text is kept so it can fade out in place.
    func setFootnote(_ text: String?, glyph: RCIconGlyph? = nil, animated: Bool) {
        let visible = text?.isEmpty == false
        if visible {
            footnote.glyph = glyph
            footnote.text = text
        }
        guard visible != showsFootnote else { return }
        showsFootnote = visible
        footnote.accessibilityElementsHidden = !visible
        if animated {
            if visible { footnote.alpha = 0 }
            RCMotion.animate(duration: RCMotion.quickDuration, delay: visible ? 0.08 : 0) {
                self.footnote.alpha = visible ? 1 : 0
            }
        } else {
            footnote.alpha = visible ? 1 : 0
        }
        setNeedsLayout()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || header.frame.contains(point)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        var height = header.sizeThatFits(size).height + Self.headerGap
        height += group.sizeThatFits(size).height
        if showsFootnote { height += Self.footnoteGap + footnote.sizeThatFits(size).height }
        return CGSize(width: size.width, height: ceil(height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let headerHeight = header.sizeThatFits(bounds.size).height
        // The header draws in its measured height, but its frame grows to a
        // 44 pt band so small accessory buttons keep full-size hit targets.
        let headerOutset = max(0, (RCLayout.minimumHitTarget - headerHeight) / 2)
        header.frame = CGRect(x: 0, y: -headerOutset, width: width, height: headerHeight + headerOutset * 2)
        let groupHeight = group.sizeThatFits(bounds.size).height
        group.frame = CGRect(x: 0, y: headerHeight + Self.headerGap, width: width, height: groupHeight)
        let footnoteHeight = footnote.sizeThatFits(bounds.size).height
        footnote.frame = CGRect(x: 0, y: group.frame.maxY + Self.footnoteGap, width: width, height: footnoteHeight)
        header.layoutIfNeeded()
        group.layoutIfNeeded()
        footnote.layoutIfNeeded()
    }
}

/// Page scroll view. Rows are controls: without this a drag that begins after
/// a finger rests on a row would not scroll (`UIScrollView` refuses to cancel
/// touches in `UIControl`s by default).
@MainActor
final class DevicesScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        true
    }
}
