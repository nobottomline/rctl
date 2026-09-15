import UIKit

// Building blocks private to the Devices screen. All use frame layout with
// accurate `sizeThatFits`, never rebuild subviews on reconfiguration, and take
// colors, type and spacing from the design-system tokens.
//
// Measurement: a render lays the page out once for sizing and once for
// placement, inside springs that may re-run layout. Text is therefore measured
// once per width, content size category and content (`DevicesMeasureCache`),
// never on every `sizeThatFits`/`layoutSubviews` call.

/// Measured values for a few widths of one view, keyed by width, content size
/// category and a content signature (the text being measured). A lookup with
/// different content replaces the stale entries, so owners never serve an old
/// measurement for new text.
struct DevicesMeasureCache<Value> {
    private var entries: [(width: CGFloat, category: UIContentSizeCategory, value: Value)] = []
    private var content = ""
    private static var capacity: Int { 4 }

    mutating func value(width: CGFloat, category: UIContentSizeCategory, content: String, measure: () -> Value) -> Value {
        if content != self.content {
            self.content = content
            entries.removeAll(keepingCapacity: true)
        }
        if let hit = entries.first(where: { $0.width == width && $0.category == category }) { return hit.value }
        let value = measure()
        if entries.count >= Self.capacity { entries.removeFirst() }
        entries.append((width, category, value))
        return value
    }

    mutating func invalidate() {
        entries.removeAll(keepingCapacity: true)
    }
}

/// Timing of in-place state switches on the Devices screen: the old state
/// fades out, the layout changes, then the new state fades in, so two states
/// are never visible on top of each other.
enum DevicesSwitchMotion {
    static let fadeOut = RCListGroupView.replaceFadeOutDuration
    static let fadeIn = RCListGroupView.replaceFadeInDuration

    /// Render-server opacity fade from what is on screen to `alpha` (the model
    /// value changes immediately), cheaper than a property animator for a
    /// plain fade. `completion` runs on the main queue once the fade is over.
    @MainActor
    static func fade(_ view: UIView, to alpha: CGFloat, duration: TimeInterval, curve: CAMediaTimingFunction = RCMotion.easeOut, completion: (@MainActor () -> Void)? = nil) {
        let layer = view.layer
        let from = layer.presentation()?.opacity ?? layer.opacity
        UIView.performWithoutAnimation { view.alpha = alpha }
        if from != Float(alpha) {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = from
            animation.toValue = Float(alpha)
            animation.duration = duration
            animation.timingFunction = curve
            layer.add(animation, forKey: "rc.switchFade")
        }
        guard let completion else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            MainActor.assumeIsolated { completion() }
        }
    }

    /// Fades `view` out, runs `swap` while it is invisible, then fades it back
    /// in. The swap is skipped when `current()` no longer returns `token`
    /// (a newer swap started).
    @MainActor
    static func swap(_ view: UIView, token: Int, current: @escaping @MainActor () -> Int, swap: @escaping @MainActor () -> Void) {
        fade(view, to: 0, duration: fadeOut, curve: RCMotion.easeIn) {
            guard current() == token else { return }
            swap()
            fade(view, to: 1, duration: fadeIn)
        }
    }
}

/// Brand mark and wordmark at the leading edge of the top bar. Collapsed (the
/// page scrolled under a solid bar) it keeps only the mark, leaving the small
/// title room between the brand and the bar buttons.
@MainActor
final class DevicesBrandView: RCView {
    private let mark = RCBrandMark(side: 28)
    private let wordmark = RCLabel("rctl", style: .headline)
    private var wordmarkSize = DevicesMeasureCache<CGSize>()
    private(set) var isCollapsed = false

    override func setUp() {
        isAccessibilityElement = true
        accessibilityLabel = "rctl"
        accessibilityTraits = .staticText
        addSubview(mark)
        addSubview(wordmark)
    }

    /// Hides the wordmark (fading) and reports whether the size changed, so the
    /// top bar can re-lay out its title once instead of on every scroll step.
    @discardableResult
    func setCollapsed(_ collapsed: Bool, animated: Bool) -> Bool {
        guard collapsed != isCollapsed else { return false }
        isCollapsed = collapsed
        let alpha: CGFloat = collapsed ? 0 : 1
        if animated {
            DevicesSwitchMotion.fade(wordmark, to: alpha, duration: collapsed ? DevicesSwitchMotion.fadeOut : DevicesSwitchMotion.fadeIn)
        } else {
            wordmark.alpha = alpha
        }
        wordmark.accessibilityElementsHidden = collapsed
        invalidateIntrinsicContentSize()
        return true
    }

    private func measuredWordmark() -> CGSize {
        wordmarkSize.value(width: 0, category: traitCollection.preferredContentSizeCategory, content: wordmark.text ?? "") {
            let size = wordmark.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            return CGSize(width: ceil(size.width), height: ceil(size.height))
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let label = measuredWordmark()
        let width = isCollapsed ? mark.side : ceil(mark.side + RCSpace.sm + label.width)
        return CGSize(width: width, height: max(mark.side, label.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let markX = rightToLeft ? bounds.width - mark.side : 0
        mark.frame = CGRect(x: markX, y: (bounds.height - mark.side) / 2, width: mark.side, height: mark.side)
        // The wordmark keeps its natural frame when collapsed so it fades out in place.
        let label = measuredWordmark()
        let x = rightToLeft ? markX - RCSpace.sm - label.width : mark.side + RCSpace.sm
        wordmark.frame = RCLayout.pixelAligned(CGRect(x: x, y: (bounds.height - label.height) / 2, width: label.width, height: label.height))
    }
}

/// "2 online · 5 devices" under the large title, with a success dot while
/// anything is online. A text change fades the old text out before the new
/// one fades in.
@MainActor
final class DevicesSummaryView: RCView {
    private let label = RCLabel(style: .callout, color: RCColor.textSecondary, lines: 0)
    private let dot = CALayer()
    private(set) var showsDot = false
    /// The text being shown, or faded in next.
    private(set) var text: String?
    private var heights = DevicesMeasureCache<CGFloat>()
    private var swapToken = 0
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
        let changed = text != self.text || showsDot != self.showsDot
        guard changed else { return }
        if text != self.text {
            let hadText = self.text != nil
            self.text = text
            accessibilityLabel = text
            swapToken += 1
            if animated, hadText, window != nil {
                let token = swapToken
                DevicesSwitchMotion.swap(label, token: token, current: { [weak self] in self?.swapToken ?? -1 }) { [weak self] in
                    self?.label.text = text
                    self?.setNeedsLayout()
                    self?.layoutIfNeeded()
                }
            } else {
                label.text = text
                label.alpha = 1
            }
        }
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

    /// Height of the target text (not the label's, which may still show the old text while fading).
    private func textHeight(width: CGFloat) -> CGFloat {
        guard let text, !text.isEmpty else { return 0 }
        return heights.value(width: width, category: traitCollection.preferredContentSizeCategory, content: text) {
            let string = RCTypography.attributedString(text, style: .callout, color: RCColor.textSecondary, lineBreakMode: .byWordWrapping, compatibleWith: traitCollection)
            let rect = string.boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil)
            return max(RCTypography.lineHeight(.callout, compatibleWith: traitCollection), ceil(rect.height))
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: textHeight(width: max(0, size.width - textInset)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let lineHeight = RCTypography.lineHeight(.callout, compatibleWith: traitCollection)
        withoutImplicitAnimations {
            dot.frame = CGRect(x: 0, y: (lineHeight - Self.dotSide) / 2, width: Self.dotSide, height: Self.dotSide)
            dot.cornerRadius = Self.dotSide / 2
        }
        let width = max(0, bounds.width - textInset)
        label.frame = CGRect(x: textInset, y: 0, width: width, height: textHeight(width: width))
    }
}

/// Horizontal run of small views (section header accessories). Hidden views
/// take no space.
@MainActor
final class DevicesAccessoryStack: UIView {
    /// Default keeps 32 pt buttons' 44 pt hit areas from overlapping.
    var spacing: CGFloat = RCLayout.minimumHitTarget - 32 { didSet { setNeedsLayout() } }
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
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var x: CGFloat = 0
        for view in visible {
            let size = view.sizeThatFits(bounds.size)
            let frame = CGRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            view.frame = rightToLeft ? CGRect(x: bounds.width - frame.maxX, y: frame.minY, width: frame.width, height: frame.height) : frame
            x += size.width + spacing
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Small buttons extend their hit areas to 44 pt beyond this container.
        visible.contains { $0.point(inside: convert(point, to: $0), with: event) } || super.point(inside: point, with: event)
    }
}

/// First Nearby header control: a spinner while the search window is open,
/// replaced by the Search again button once it settles. Both share one slot,
/// so neither overlaps the other and the Stop button never moves.
@MainActor
final class DevicesSearchSlot: UIView {
    let button: RCIconButton
    let spinner = RCSpinner(diameter: 14, lineWidth: 1.75)
    private(set) var isSearching = false
    private var token = 0

    init(button: RCIconButton) {
        self.button = button
        super.init(frame: .zero)
        spinner.hidesWhenStopped = false
        spinner.isHidden = true
        spinner.isAccessibilityElement = true
        spinner.accessibilityLabel = "Searching"
        spinner.accessibilityTraits = [.staticText, .updatesFrequently]
        addSubview(spinner)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func setSearching(_ searching: Bool, animated: Bool) {
        guard searching != isSearching else { return }
        isSearching = searching
        token += 1
        let incoming: UIView = searching ? spinner : button
        let outgoing: UIView = searching ? button : spinner
        outgoing.isUserInteractionEnabled = false
        // Shows the incoming control; the spinner runs only while it is visible.
        let reveal = { [spinner] (alpha: CGFloat) in
            incoming.alpha = alpha
            if searching { spinner.startAnimating() }
            incoming.isHidden = false
            incoming.isUserInteractionEnabled = true
        }
        let conceal = { [spinner] in
            outgoing.isHidden = true
            outgoing.alpha = 1
            if !searching { spinner.stopAnimating() }
        }
        guard animated, window != nil, !outgoing.isHidden else {
            conceal()
            reveal(1)
            return
        }
        let current = token
        DevicesSwitchMotion.fade(outgoing, to: 0, duration: DevicesSwitchMotion.fadeOut, curve: RCMotion.easeIn) { [weak self] in
            guard let self, self.token == current else { return }
            conceal()
            reveal(0)
            DevicesSwitchMotion.fade(incoming, to: 1, duration: DevicesSwitchMotion.fadeIn)
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        button.sizeThatFits(size)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.frame = bounds
        let side = spinner.diameter
        spinner.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if !button.isHidden { return button.point(inside: convert(point, to: button), with: event) }
        return super.point(inside: point, with: event)
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

    private struct Metrics {
        var title: CGFloat
        var message: CGFloat
        var buttons: [CGRect]
    }

    private let tile = UIView()
    private let iconView = RCIconView(pointSize: 18)
    private let spinner = RCSpinner(diameter: 18, lineWidth: 2)
    private let titleLabel = RCLabel(style: .bodyStrong, lines: 0)
    private let messageLabel = RCLabel(style: .footnote, color: RCColor.textTertiary, lines: 0)
    private var buttons: [RCButton] = []
    private var handlers: [@MainActor () -> Void] = []
    private var metrics = DevicesMeasureCache<Metrics>()
    private var contentSignature = ""

    private static let insets = UIEdgeInsets(top: 12, left: 12, bottom: 14, right: 14)
    private static let tileSide: CGFloat = 40
    private static let buttonSpacing: CGFloat = RCSpace.sm

#if DEBUG
    /// Text and button measurements performed (tests prove layout passes reuse them).
    private(set) var measurementCount = 0
#endif

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
        contentSignature = ([title, message] + actions.map { "\($0.title)\($0.isProminent)" }).joined(separator: "\u{1F}")
        setNeedsLayout()
    }

    private static func variant(for action: Action) -> RCButton.Variant {
        action.isProminent ? .primary : .secondary
    }

    private func textWidth(for width: CGFloat) -> CGFloat {
        max(0, width - Self.insets.left - Self.tileSide - RCSpace.md - Self.insets.right)
    }

    /// Text heights and button frames (relative to the text column) at `width`, measured once per width.
    private func measured(width: CGFloat) -> Metrics {
        metrics.value(width: width, category: traitCollection.preferredContentSizeCategory, content: contentSignature) {
#if DEBUG
            measurementCount += 1
#endif
            let fit = CGSize(width: width, height: .greatestFiniteMagnitude)
            return Metrics(
                title: ceil(titleLabel.sizeThatFits(fit).height),
                message: ceil(messageLabel.sizeThatFits(fit).height),
                buttons: buttonFrames(width: width)
            )
        }
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

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let metrics = measured(width: textWidth(for: size.width))
        var height = metrics.title + RCSpace.xxs + metrics.message
        if let last = metrics.buttons.last { height += RCSpace.md + last.maxY }
        return CGSize(width: size.width, height: ceil(max(Self.tileSide, height) + Self.insets.top + Self.insets.bottom))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = textWidth(for: bounds.width)
        let metrics = measured(width: width)
        let textBlock = metrics.title + RCSpace.xxs + metrics.message
        let contentHeight = textBlock + (metrics.buttons.last.map { RCSpace.md + $0.maxY } ?? 0)
        let x = Self.insets.left + Self.tileSide + RCSpace.md
        // Short content centers on the tile; taller notices align to the top.
        var y = contentHeight < Self.tileSide ? Self.insets.top + (Self.tileSide - textBlock) / 2 : Self.insets.top
        tile.frame = CGRect(x: Self.insets.left, y: Self.insets.top, width: Self.tileSide, height: Self.tileSide)
        tile.applyCornerRadius(Self.tileSide * 0.28)
        iconView.frame = tile.bounds
        spinner.frame = tile.bounds
        titleLabel.frame = CGRect(x: x, y: y, width: width, height: metrics.title)
        y += metrics.title + RCSpace.xxs
        messageLabel.frame = CGRect(x: x, y: y, width: width, height: metrics.message)
        y += metrics.message + RCSpace.md
        for (button, frame) in zip(buttons, metrics.buttons) {
            button.frame = frame.offsetBy(dx: x, dy: y)
        }
    }
}

/// Small print under a group: optional leading glyph and wrapping text.
@MainActor
final class DevicesFootnoteView: RCView {
    var glyph: RCIconGlyph? { didSet { iconView.glyph = glyph; iconView.isHidden = glyph == nil; setNeedsLayout() } }
    var text: String? { didSet { label.text = text; label.accessibilityLabel = text; setNeedsLayout() } }
    var style: RCTextStyle = .caption { didSet { label.style = style; heights.invalidate(); setNeedsLayout() } }
    var color: UIColor = RCColor.textTertiary { didSet { label.color = color; updateAppearance() } }
    var truncatesMiddle = false {
        didSet {
            label.numberOfLines = truncatesMiddle ? 1 : 0
            label.lineBreakMode = truncatesMiddle ? .byTruncatingMiddle : .byWordWrapping
            heights.invalidate()
            setNeedsLayout()
        }
    }

    private let iconView = RCIconView(pointSize: 12, strokeWidth: 2.25)
    private let label = RCLabel(style: .caption, color: RCColor.textTertiary, lines: 0)
    private var heights = DevicesMeasureCache<CGFloat>()
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

    private func textHeight(width: CGFloat) -> CGFloat {
        guard let text, !text.isEmpty else { return 0 }
        return heights.value(width: width, category: traitCollection.preferredContentSizeCategory, content: text) {
            ceil(label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: textHeight(width: max(0, size.width - textX - Self.horizontalInset)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, bounds.width - textX - Self.horizontalInset)
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let labelFrame = CGRect(x: textX, y: 0, width: width, height: textHeight(width: width))
        label.frame = rightToLeft ? CGRect(x: bounds.width - labelFrame.maxX, y: 0, width: width, height: labelFrame.height) : labelFrame
        let lineHeight = RCTypography.lineHeight(style, compatibleWith: traitCollection)
        let side = iconView.pointSize
        let iconX = rightToLeft ? bounds.width - Self.horizontalInset - side : Self.horizontalInset
        iconView.frame = RCLayout.pixelAligned(CGRect(x: iconX, y: (lineHeight - side) / 2, width: side, height: side))
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

    /// Heights from the last `sizeThatFits`, reused by the `layoutSubviews`
    /// that follows it so one layout pass measures the subtree once.
    private struct Measurement {
        var width: CGFloat
        var category: UIContentSizeCategory
        var header: CGFloat
        var group: CGFloat
        var footnote: CGFloat
        var total: CGFloat
    }

    private var measurement: Measurement?
    private var headerHeights = DevicesMeasureCache<CGFloat>()

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

    /// Header subtitle and trailing accessory; unchanged values cost nothing.
    func setHeader(subtitle: String?, accessory: UIView?) {
        guard header.subtitle != subtitle || header.accessoryView !== accessory else { return }
        header.subtitle = subtitle
        header.accessoryView = accessory
        measurement = nil
        setNeedsLayout()
    }

    /// Replaces the rows; the group animates insertions, removals and its height.
    func setRows(_ items: [RCListGroupView.Item], animated: Bool) {
        setRows(items, transition: animated ? .rows : .none)
    }

    /// Replaces the rows with an explicit group transition (`.replace` for state switches).
    func setRows(_ items: [RCListGroupView.Item], transition: RCListGroupView.Transition) {
        guard group.isTargetPlaceholder || group.targetItemIDs != items.map(\.id) else { return }
        measurement = nil
        group.setItems(items, transition: transition)
    }

    /// Shows or hides the footnote. Hidden text is kept so it can fade out in place.
    func setFootnote(_ text: String?, glyph: RCIconGlyph? = nil, animated: Bool) {
        let visible = text?.isEmpty == false
        if visible {
            if footnote.glyph != glyph { footnote.glyph = glyph; measurement = nil }
            if footnote.text != text { footnote.text = text; measurement = nil }
        }
        guard visible != showsFootnote else { return }
        showsFootnote = visible
        measurement = nil
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

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory {
            measurement = nil
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || header.frame.contains(point)
    }

    private func headerHeight(width: CGFloat) -> CGFloat {
        // Read from the header itself, so a subtitle set directly is never served stale.
        let accessory = header.accessoryView.map { "\(ObjectIdentifier($0).hashValue)" } ?? ""
        let signature = "\(header.title)\u{1F}\(header.subtitle ?? "")\u{1F}\(accessory)"
        return headerHeights.value(width: width, category: traitCollection.preferredContentSizeCategory, content: signature) {
            header.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
    }

    private func measure(width: CGFloat) -> Measurement {
        let fit = CGSize(width: width, height: .greatestFiniteMagnitude)
        let header = headerHeight(width: width)
        let group = group.sizeThatFits(fit).height
        let footnote = footnote.sizeThatFits(fit).height
        let total = ceil(header + Self.headerGap + group + (showsFootnote ? Self.footnoteGap + footnote : 0))
        let result = Measurement(width: width, category: traitCollection.preferredContentSizeCategory, header: header, group: group, footnote: footnote, total: total)
        measurement = result
        return result
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: measure(width: size.width).total)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        // The page sizes a section right before placing it; reuse that pass
        // unless the frame or traits no longer match what was measured.
        let resolved: Measurement
        if let measurement, measurement.width == width, measurement.total == bounds.height,
           measurement.category == traitCollection.preferredContentSizeCategory {
            resolved = measurement
        } else {
            resolved = measure(width: width)
        }
        // The header draws in its measured height, but its frame grows to a
        // 44 pt band so small accessory buttons keep full-size hit targets.
        let headerOutset = max(0, (RCLayout.minimumHitTarget - resolved.header) / 2)
        header.frame = CGRect(x: 0, y: -headerOutset, width: width, height: resolved.header + headerOutset * 2)
        group.frame = CGRect(x: 0, y: resolved.header + Self.headerGap, width: width, height: resolved.group)
        footnote.frame = CGRect(x: 0, y: group.frame.maxY + Self.footnoteGap, width: width, height: resolved.footnote)
        // Header text changes are instant; laying it out inside the page spring
        // would animate the subtitle's width and re-truncate it every frame.
        UIView.performWithoutAnimation { header.layoutIfNeeded() }
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
