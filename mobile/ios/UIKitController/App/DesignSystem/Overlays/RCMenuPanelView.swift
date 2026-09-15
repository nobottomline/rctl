import UIKit

/// Menu surface shared by dropdowns and context menus: elevated fill, hairline
/// border, continuous `xl` corners and a popover shadow from a cached path.
/// The shadow lives on this view's layer and the rounded fill on `clipView`.
/// Content is a stack of `RCMenuPageView`s (root list and submenus); only the
/// top page is visible outside transitions.
///
/// No mask at rest: rows sit inside the panel padding, so the rounded fill
/// alone shapes the panel. `clipView` masks to its rounded bounds only while
/// pages slide during a submenu transition, and for a page taller than the
/// panel (rows scroll past the rounded corners), which is rare.
/// Frame layout only; rows are built once per page and reused for the life
/// of the presentation.
@MainActor
final class RCMenuPanelView: RCView {
    static let padding: CGFloat = 4
    static let cornerRadius: CGFloat = RCRadius.xl

    let clipView = UIView()
    private var shadowSize: CGSize = .zero
    private(set) var pages: [RCMenuPageView] = []
    private(set) weak var highlightedRow: RCMenuRowView?
    /// While true, page frames belong to the running transition.
    var isTransitioning = false
    /// Row activation from VoiceOver / keyboard (touches are routed by the presentation).
    var onActivate: ((RCMenuRowView) -> Void)?
    var onEscape: (() -> Void)?

    var currentPage: RCMenuPageView? { pages.last }

    init(sections: [RCMenuSection]) {
        super.init(frame: .zero)
        let root = RCMenuPageView(sections: sections, backTitle: nil)
        push(root)
    }

    override func setUp() {
        accessibilityViewIsModal = true
        clipView.layer.cornerRadius = Self.cornerRadius
        clipView.layer.cornerCurve = .continuous
        addSubview(clipView)
    }

    override func updateAppearance() {
        clipView.layer.backgroundColor = RCColor.elevated.cgColor(for: self)
        clipView.layer.borderColor = RCColor.line.cgColor(for: self)
        clipView.layer.borderWidth = RCLayout.hairline
        shadowSize = .zero
        updateShadow()
    }

    /// Masks pages to the rounded panel only while they can cross its edges:
    /// sliding during a submenu transition, or scrolling.
    func updatePageClipping() {
        let scrolls = currentPage.map { $0.contentHeight(for: bounds.width) > bounds.height + 0.5 } ?? false
        let clips = isTransitioning || scrolls
        guard clipView.layer.masksToBounds != clips else { return }
        clipView.layer.masksToBounds = clips
    }

    var clipsPages: Bool { clipView.layer.masksToBounds }

    /// Flattens the panel (with its shadow) into one cached bitmap while it
    /// fades and scales in or out, so the group opacity is not recomposited
    /// offscreen on every frame. Off at rest: rows highlight and scroll.
    func setRasterizedForFade(_ rasterized: Bool) {
        guard layer.shouldRasterize != rasterized else { return }
        layer.shouldRasterize = rasterized
        if rasterized { layer.rasterizationScale = window?.screen.scale ?? UIScreen.main.scale }
    }

    /// Adds a page to the stack (not yet laid out or animated).
    func push(_ page: RCMenuPageView) {
        page.onActivate = { [weak self] row in self?.onActivate?(row) }
        pages.append(page)
        if page.superview !== clipView { clipView.addSubview(page) }
    }

    /// Removes the top page from the stack; the caller animates it out.
    @discardableResult
    func popPage() -> RCMenuPageView? {
        guard pages.count > 1 else { return nil }
        return pages.removeLast()
    }

    func setHighlighted(_ row: RCMenuRowView?) {
        guard row !== highlightedRow else { return }
        highlightedRow?.isHighlighted = false
        highlightedRow = row
        row?.isHighlighted = true
    }

    /// Row of the visible page under a point in this view's coordinates.
    func row(at point: CGPoint) -> RCMenuRowView? {
        guard !isTransitioning, let page = currentPage, bounds.contains(point) else { return nil }
        return page.row(at: convert(point, to: page))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clipView.frame = bounds
        if !isTransitioning, let page = currentPage {
            page.frame = clipView.bounds
        }
        updatePageClipping()
        if bounds.size != shadowSize {
            withoutImplicitAnimations { updateShadow() }
        }
    }

    /// Shadow from an explicit path, rebuilt only when the size changes.
    func updateShadow() {
        guard bounds.width > 0, bounds.height > 0 else {
            RCShadow.clear(layer)
            shadowSize = .zero
            return
        }
        guard bounds.size != shadowSize else { return }
        shadowSize = bounds.size
        let path = UIBezierPath.continuousRoundedRect(bounds, radius: Self.cornerRadius).cgPath
        RCShadow.popover.apply(to: layer, path: path, traits: traitCollection)
    }

    override func accessibilityPerformEscape() -> Bool {
        onEscape?()
        return true
    }

    // MARK: Measurement

    /// Natural width of every page reachable from `sections` (root and all
    /// submenus), so the panel keeps one width while navigating. Uses text
    /// measurement only; no views are created.
    static func naturalWidth(for sections: [RCMenuSection], backTitle: String? = nil, traits: UITraitCollection) -> CGFloat {
        let reservesIcon = backTitle != nil || sections.contains { $0.items.contains { $0.icon != nil } }
        let iconColumn = reservesIcon ? RCMenuRowView.iconSize(for: traits) + RCMenuRowView.iconSpacing : 0
        let horizontal = RCMenuRowView.horizontalPadding * 2
        var width: CGFloat = 0
        if let backTitle {
            width = horizontal + iconColumn + textWidth(backTitle, style: .bodyStrong, traits: traits)
        }
        for section in sections where !section.items.isEmpty {
            if let title = section.title {
                width = max(width, horizontal + textWidth(title, style: .overline, traits: traits))
            }
            for item in section.items {
                let titleWidth = textWidth(item.title, style: RCMenuRowView.titleStyle(for: item), traits: traits)
                let subtitleWidth = item.subtitle.map { textWidth($0, style: .footnote, traits: traits) } ?? 0
                var itemWidth = horizontal + iconColumn + max(titleWidth, subtitleWidth)
                if item.isChecked || !item.children.isEmpty {
                    itemWidth += RCMenuRowView.iconSpacing + RCMenuRowView.trailingSize(for: traits)
                }
                width = max(width, itemWidth)
                if !item.children.isEmpty {
                    width = max(width, naturalWidth(for: item.children, backTitle: item.title, traits: traits) - padding * 2)
                }
            }
        }
        return ceil(width + padding * 2)
    }

    private static func textWidth(_ text: String, style: RCTextStyle, traits: UITraitCollection) -> CGFloat {
        let value = style.spec.uppercase ? text.uppercased() : text
        let attributes = RCTypography.attributes(style, color: RCColor.text, compatibleWith: traits)
        let rect = NSAttributedString(string: value, attributes: attributes).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        return ceil(rect.width)
    }
}

/// One list of rows: optional back row, section titles, rows, separators.
/// Scrolls when the panel is shorter than its content.
@MainActor
final class RCMenuPageView: UIScrollView {
    private enum Element {
        case row(RCMenuRowView)
        case header(RCLabel)
        case separator(RCSeparator)
    }

    let backTitle: String?
    let sections: [RCMenuSection]
    private(set) var rows: [RCMenuRowView] = []
    private var elements: [Element] = []
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 0
    /// Width the rows were last laid out at; scrolling re-enters
    /// `layoutSubviews` every frame and must not redo row layout.
    private var laidOutWidth: CGFloat = -1
    var onActivate: ((RCMenuRowView) -> Void)?

    init(sections: [RCMenuSection], backTitle: String?) {
        self.backTitle = backTitle
        self.sections = sections
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = false
        delaysContentTouches = false
        scrollsToTop = false
        contentInsetAdjustmentBehavior = .never
        verticalScrollIndicatorInsets = UIEdgeInsets(top: RCMenuPanelView.cornerRadius / 2, left: 0, bottom: RCMenuPanelView.cornerRadius / 2, right: 2)
        clipsToBounds = false
        build(sections: sections)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    private func build(sections: [RCMenuSection]) {
        let visible = sections.enumerated().filter { !$0.element.items.isEmpty }
        let reservesIcon = backTitle != nil || visible.contains { $0.element.items.contains { $0.icon != nil } }
        if let backTitle {
            let back = RCMenuRowView(kind: .back(title: backTitle), reservesIconColumn: true)
            add(.row(back))
        }
        for (position, entry) in visible.enumerated() {
            if position > 0 || backTitle != nil {
                add(.separator(RCSeparator()))
            }
            if let title = entry.element.title {
                let header = RCLabel(title, style: .overline, color: RCColor.textTertiary)
                header.accessibilityTraits = .header
                add(.header(header))
            }
            for (index, item) in entry.element.items.enumerated() {
                let row = RCMenuRowView(kind: .item(item, IndexPath(item: index, section: entry.offset)), reservesIconColumn: reservesIcon)
                add(.row(row))
            }
        }
    }

    private func add(_ element: Element) {
        elements.append(element)
        switch element {
        case let .row(row):
            rows.append(row)
            row.onAccessibilityActivate = { [weak self, weak row] in
                guard let self, let row else { return }
                self.onActivate?(row)
            }
            addSubview(row)
        case let .header(label):
            addSubview(label)
        case let .separator(separator):
            addSubview(separator)
        }
    }

    var firstAccessibleRow: RCMenuRowView? { rows.first }

    /// Content height (including panel padding) at `width`. Cached per width.
    func contentHeight(for width: CGFloat) -> CGFloat {
        if abs(width - measuredWidth) < 0.5 { return measuredHeight }
        measuredWidth = width
        measuredHeight = layoutElements(width: width, apply: false)
        return measuredHeight
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height: CGFloat
        if abs(bounds.width - laidOutWidth) < 0.5 {
            height = contentSize.height
        } else {
            height = layoutElements(width: bounds.width, apply: true)
            laidOutWidth = bounds.width
        }
        let size = CGSize(width: bounds.width, height: height)
        if contentSize != size { contentSize = size }
        let scrolls = height > bounds.height + 0.5
        if isScrollEnabled != scrolls { isScrollEnabled = scrolls }
        showsVerticalScrollIndicator = scrolls
    }

    @discardableResult
    private func layoutElements(width: CGFloat, apply: Bool) -> CGFloat {
        let padding = RCMenuPanelView.padding
        let rowWidth = max(0, width - padding * 2)
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var y = padding
        for element in elements {
            switch element {
            case let .row(row):
                let height = row.height(for: rowWidth)
                if apply { row.frame = CGRect(x: padding, y: y, width: rowWidth, height: height) }
                y += height
            case let .header(label):
                y += RCSpace.sm
                let inset = padding + RCMenuRowView.horizontalPadding
                let height = RCTypography.lineHeight(.overline, compatibleWith: traitCollection)
                if apply {
                    let labelWidth = max(0, width - inset * 2)
                    label.textAlignment = isRightToLeft ? .right : .left
                    label.frame = CGRect(x: inset, y: y, width: labelWidth, height: height)
                }
                y += height + RCSpace.xs
            case let .separator(separator):
                y += RCSpace.xs
                if apply { separator.frame = CGRect(x: 0, y: y, width: width, height: RCLayout.hairline) }
                y += RCLayout.hairline + RCSpace.xs
            }
        }
        return ceil(y + padding)
    }

    func row(at point: CGPoint) -> RCMenuRowView? {
        rows.first { !$0.isHidden && $0.frame.contains(point) }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory
            || traitCollection.layoutDirection != previousTraitCollection?.layoutDirection {
            measuredWidth = -1
            laidOutWidth = -1
            setNeedsLayout()
        }
    }
}

/// Menu row: leading icon column, title (+ subtitle), trailing checkmark or
/// submenu chevron, `pressWash` highlight. Not a control: touches are routed
/// by the presentation so press-and-drag works across rows.
@MainActor
final class RCMenuRowView: RCView {
    enum Kind {
        case item(RCMenuItem, IndexPath)
        case back(title: String)
    }

    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 10
    static let iconSize: CGFloat = 18
    static let iconSpacing: CGFloat = 12
    static let trailingSize: CGFloat = 16
    static let minimumHeight: CGFloat = RCLayout.minimumHitTarget

    /// Glyphs grow with Dynamic Type (capped) so they keep up with the title.
    static func iconSize(for traits: UITraitCollection) -> CGFloat {
        (iconSize * glyphScale(for: traits)).rounded()
    }

    static func trailingSize(for traits: UITraitCollection) -> CGFloat {
        (trailingSize * glyphScale(for: traits)).rounded()
    }

    private static func glyphScale(for traits: UITraitCollection) -> CGFloat {
        min(max(RCTypography.scale(for: .body, compatibleWith: traits), 1), 1.5)
    }

    let kind: Kind
    let reservesIconColumn: Bool
    /// Lazily built submenu page, reused if the user navigates in again.
    var childPage: RCMenuPageView?
    var onAccessibilityActivate: (() -> Void)?

    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            highlightLayer.removeAnimation(forKey: "flash")
            withoutImplicitAnimations { highlightLayer.opacity = isHighlighted ? 1 : 0 }
        }
    }

    private let highlightLayer = CALayer()
    private let iconView = RCIconView(pointSize: RCMenuRowView.iconSize)
    private let titleLabel: RCLabel
    private let subtitleLabel: RCLabel?
    private let trailingView = RCIconView(pointSize: RCMenuRowView.trailingSize)
    private var cachedWidth: CGFloat = -1
    private var cachedHeight: CGFloat = 0

    var item: RCMenuItem? {
        if case let .item(item, _) = kind { return item }
        return nil
    }

    var indexPath: IndexPath? {
        if case let .item(_, path) = kind { return path }
        return nil
    }

    var isEnabled: Bool { item?.isEnabled ?? true }
    var isBack: Bool { if case .back = kind { return true } else { return false } }
    var hasChildren: Bool { !(item?.children.isEmpty ?? true) }

    /// One weight for every item keeps mixed menus calm; subtitles add
    /// hierarchy through size and color. The back row uses `bodyStrong` as
    /// the submenu's heading.
    static func titleStyle(for item: RCMenuItem) -> RCTextStyle {
        .body
    }

    init(kind: Kind, reservesIconColumn: Bool) {
        self.kind = kind
        self.reservesIconColumn = reservesIconColumn
        switch kind {
        case let .item(item, _):
            titleLabel = RCLabel(item.title, style: Self.titleStyle(for: item), lines: 2)
            subtitleLabel = item.subtitle.map { RCLabel($0, style: .footnote, color: RCColor.textTertiary, lines: 2) }
        case let .back(title):
            titleLabel = RCLabel(title, style: .bodyStrong, lines: 2)
            subtitleLabel = nil
        }
        super.init(frame: .zero)
        configure()
    }

    override func setUp() {
        isAccessibilityElement = true
        highlightLayer.opacity = 0
        highlightLayer.cornerRadius = RCRadius.sm
        highlightLayer.cornerCurve = .continuous
        layer.addSublayer(highlightLayer)
        addSubview(iconView)
        addSubview(trailingView)
    }

    private func configure() {
        addSubview(titleLabel)
        if let subtitleLabel { addSubview(subtitleLabel) }
        titleLabel.isAccessibilityElement = false
        subtitleLabel?.isAccessibilityElement = false
        switch kind {
        case let .item(item, _):
            iconView.glyph = item.icon
            iconView.isHidden = item.icon == nil
            if !item.children.isEmpty {
                trailingView.isHidden = false
            } else {
                trailingView.glyph = .check
                trailingView.isHidden = !item.isChecked
            }
            alpha = item.isEnabled ? 1 : 0.4
            accessibilityLabel = item.title
            accessibilityValue = item.subtitle
            var traits: UIAccessibilityTraits = .button
            if item.isChecked { traits.insert(.selected) }
            if !item.isEnabled { traits.insert(.notEnabled) }
            accessibilityTraits = traits
            accessibilityHint = item.children.isEmpty ? nil : "Opens submenu"
        case let .back(title):
            trailingView.isHidden = true
            accessibilityLabel = "Back"
            accessibilityValue = title
            accessibilityTraits = .button
        }
        updateAppearance()
        updateDirectionalGlyphs()
    }

    override func updateAppearance() {
        guard highlightLayer.superlayer != nil else { return }
        highlightLayer.backgroundColor = RCColor.pressWash.cgColor(for: self)
        let destructive = item?.role == .destructive
        // AA text token: the web danger color is under 4.5:1 once the row is highlighted in Warm.
        titleLabel.color = destructive ? RCColor.dangerText : RCColor.text
        iconView.tintColor = destructive ? RCColor.dangerText : RCColor.textTertiary
        trailingView.tintColor = hasChildren ? RCColor.textTertiary : RCColor.accent
    }

    private func updateDirectionalGlyphs() {
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        if isBack {
            iconView.glyph = isRightToLeft ? .chevronRight : .chevronLeft
            iconView.isHidden = false
        }
        if hasChildren {
            trailingView.glyph = isRightToLeft ? .chevronLeft : .chevronRight
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.layoutDirection != previousTraitCollection?.layoutDirection {
            updateDirectionalGlyphs()
        }
    }

    override func updateTypography() {
        cachedWidth = -1
        iconView.pointSize = Self.iconSize(for: traitCollection)
        trailingView.pointSize = Self.trailingSize(for: traitCollection)
        setNeedsLayout()
    }

    /// Short confirmation blink before the menu dismisses.
    func flash() {
        isHighlighted = true
        guard !RCMotion.reduceMotion else { return }
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        blink.values = [1, 0.35, 1]
        blink.keyTimes = [0, 0.45, 1]
        blink.duration = 0.12
        highlightLayer.add(blink, forKey: "flash")
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        onAccessibilityActivate?()
        return true
    }

    private var textInsets: (leading: CGFloat, trailing: CGFloat) {
        let leading = Self.horizontalPadding + (reservesIconColumn ? iconView.pointSize + Self.iconSpacing : 0)
        let trailing = Self.horizontalPadding + (trailingView.isHidden ? 0 : trailingView.pointSize + Self.iconSpacing)
        return (leading, trailing)
    }

    func height(for width: CGFloat) -> CGFloat {
        if abs(width - cachedWidth) < 0.5 { return cachedHeight }
        let insets = textInsets
        let textWidth = max(0, width - insets.leading - insets.trailing)
        let fit = CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        var textHeight = titleLabel.sizeThatFits(fit).height
        if let subtitleLabel {
            textHeight += 1 + subtitleLabel.sizeThatFits(fit).height
        }
        cachedWidth = width
        cachedHeight = max(Self.minimumHeight, ceil(textHeight + Self.verticalPadding * 2))
        return cachedHeight
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitAnimations { highlightLayer.frame = bounds }
        let width = bounds.width
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func place(_ rect: CGRect) -> CGRect {
            RCLayout.pixelAligned(isRightToLeft ? CGRect(x: width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect)
        }
        let insets = textInsets
        let textWidth = max(0, width - insets.leading - insets.trailing)
        let fit = CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        let titleHeight = titleLabel.sizeThatFits(fit).height
        let subtitleHeight = subtitleLabel?.sizeThatFits(fit).height ?? 0
        let total = titleHeight + (subtitleLabel == nil ? 0 : 1 + subtitleHeight)
        var y = (bounds.height - total) / 2
        titleLabel.textAlignment = isRightToLeft ? .right : .left
        subtitleLabel?.textAlignment = isRightToLeft ? .right : .left
        titleLabel.frame = place(CGRect(x: insets.leading, y: y, width: textWidth, height: titleHeight))
        y += titleHeight + 1
        subtitleLabel?.frame = place(CGRect(x: insets.leading, y: y, width: textWidth, height: subtitleHeight))
        // The icon aligns with the first line of the title so multi-line rows stay tidy.
        let firstLine = RCTypography.lineHeight(titleLabel.style, compatibleWith: traitCollection)
        let icon = iconView.pointSize
        let trailingSide = trailingView.pointSize
        let iconY = subtitleLabel == nil && titleHeight <= firstLine + 1
            ? (bounds.height - icon) / 2
            : (bounds.height - total) / 2 + (firstLine - icon) / 2
        iconView.frame = place(CGRect(x: Self.horizontalPadding, y: iconY, width: icon, height: icon))
        trailingView.frame = place(CGRect(x: width - Self.horizontalPadding - trailingSide, y: (bounds.height - trailingSide) / 2, width: trailingSide, height: trailingSide))
    }
}
