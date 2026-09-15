import UIKit

/// Tappable list row: leading tile, title, detail, trailing badge/accessory.
///
/// Frame layout computed once per width, content size category and content
/// (`Layout`, cached); the row never rebuilds subviews when reconfigured.
///
/// **Press feedback.** The `pressWash` highlight appears on the first frame
/// after touch-down. Inside a scroll view it waits ~60 ms after the touch
/// began (like `UITableView`) so a drag that starts on a row never flashes it;
/// a tap shorter than that still flashes briefly. Hosting scroll views should
/// return `true` from `touchesShouldCancel(in:)` for rows (collection and
/// table views already do): the `UIScrollView` default refuses to cancel
/// touches in any `UIControl`, which would stop a drag that starts after a
/// finger rested on a row.
///
/// **Large text.** At accessibility sizes, or whenever the title or detail
/// would be truncated to make room for the badge, the badge moves under the
/// detail instead (`Layout.isStacked`).
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
        /// Render the detail in SF Mono (addresses, endpoints); truncates in the middle.
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

    /// Resolved geometry of a row for one width and trait environment. A pure
    /// value: cached per width by the row and unit-tested directly.
    struct Layout: Equatable {
        var size: CGSize
        /// Badge placed under the detail instead of beside the text.
        var isStacked: Bool
        var titleLineCount: Int
        var tileFrame: CGRect
        var titleFrame: CGRect
        var detailFrame: CGRect
        var badgeFrame: CGRect
        var trailingViewFrame: CGRect
        var accessoryFrame: CGRect
    }

    private(set) var content: Content
    var onTap: (() -> Void)?
    var haptic: RCHaptics.Kind? = .light

    /// Custom trailing accessory (e.g. a small `RCIconButton`), placed before
    /// the chevron/plus/check. Sized with `sizeThatFits`; it receives its own
    /// touches. A `UIControl` with an accessibility label is also exposed as a
    /// VoiceOver custom action on the row.
    var trailingView: UIView? {
        didSet {
            guard trailingView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let trailingView { addSubview(trailingView) }
            invalidateLayoutCache()
            setNeedsLayout()
        }
    }

    /// VoiceOver hint, e.g. "Opens remote control" or "Shows why this device is unavailable".
    var accessibilityHintText: String? {
        didSet { accessibilityHint = accessibilityHintText }
    }

    static let tileSide: CGFloat = 40
    static let insets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 14)
    /// Narrowest text column allowed beside a badge before it stacks.
    static let minimumInlineTextWidth: CGFloat = 96
    /// Delay before the highlight shows when the row is inside a scroll view.
    static let scrollHighlightDelay: TimeInterval = 0.06

    private static let accessorySide: CGFloat = 16
    private static let detailSpacing: CGFloat = 2
    private static let stackedBadgeSpacing: CGFloat = 6

    private let tile: RCIconTile
    private let titleLabel = RCLabel(style: .bodyStrong, lines: 2)
    private let detailLabel = RCLabel(style: .footnote, color: RCColor.textTertiary)
    private let badge = RCStatusBadge()
    private let accessoryIcon = RCIconView(pointSize: 16)
    private let highlightLayer = CALayer()

    private var layoutCache: [(key: LayoutKey, layout: Layout)] = []
    private var cachedBadgeSize: CGSize?
    private var hasConfigured = false
    private var isFlashingHighlight = false

    private var touchDownTimestamp: TimeInterval?
    private(set) var isHighlightVisible = false
    private var didShowHighlightForTouch = false
    private var storedCustomActions: [UIAccessibilityCustomAction]?

    /// Set by `RCListGroupView` to hide separators beside a pressed row.
    fileprivate var groupHighlightHandler: ((RCListRow, Bool) -> Void)?
    /// Set by `RCListGroupView` to animate its height when a row's height changes.
    fileprivate var groupSizeHandler: ((RCListRow, Bool) -> Void)?

    init(content: Content) {
        self.content = content
        tile = RCIconTile(glyph: content.glyph ?? .tabletSmartphone, tone: content.tileTone, side: Self.tileSide)
        super.init(frame: .zero)
        addSubview(tile)
        configure(content)
    }

    override func setUp() {
        isAccessibilityElement = true
        accessibilityTraits = .button
        layer.addSublayer(highlightLayer)
        highlightLayer.opacity = 0
        titleLabel.lineBreakMode = .byTruncatingTail
        for view in [titleLabel, detailLabel, badge, accessoryIcon] as [UIView] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        badge.isAccessibilityElement = false
        addTarget(self, action: #selector(handleTap), for: .primaryActionTriggered)
    }

    // MARK: Content

    /// Applies new content. With `animated`, changed text and the tile
    /// crossfade, the badge resizes and frames move with a spring; a height
    /// change animates the enclosing `RCListGroupView` in the same motion.
    func configure(_ content: Content, animated: Bool = false) {
        let old = self.content
        guard content != old || !hasConfigured else { return }
        let animate = animated && hasConfigured && window != nil && bounds.width > 0
        hasConfigured = true
        self.content = content

        if animate {
            if old.title != content.title || old.appearsEnabled != content.appearsEnabled { crossfade(titleLabel) }
            if old.detail != content.detail || old.detailIsMonospaced != content.detailIsMonospaced { crossfade(detailLabel) }
            if old.glyph != content.glyph || Self.effectiveTone(old) != Self.effectiveTone(content) { crossfade(tile) }
        }

        titleLabel.text = content.title
        titleLabel.color = content.appearsEnabled ? RCColor.text : RCColor.textSecondary
        detailLabel.text = content.detail
        detailLabel.style = content.detailIsMonospaced ? .monoSmall : .footnote
        detailLabel.lineBreakMode = content.detailIsMonospaced ? .byTruncatingMiddle : .byTruncatingTail
        if let glyph = content.glyph { tile.glyph = glyph }
        tile.tone = Self.effectiveTone(content)
        var appearing: [UIView] = []
        if setVisible(tile, content.glyph != nil, animated: animate) { appearing.append(tile) }

        if let badgeValue = content.trailing.badgeValue {
            badge.configure(text: badgeValue.text, tone: badgeValue.tone, busy: badgeValue.busy, animated: animate)
        }
        if setVisible(badge, content.trailing.badgeValue != nil, animated: animate) { appearing.append(badge) }
        if let glyph = content.trailing.accessoryGlyph {
            accessoryIcon.setGlyph(glyph, animated: animate && old.trailing.accessoryGlyph != nil)
        }
        if setVisible(accessoryIcon, content.trailing.accessoryGlyph != nil, animated: animate) { appearing.append(accessoryIcon) }
        accessoryIcon.tintColor = content.trailing == .check ? RCColor.accent : RCColor.textQuaternary

        updateAccessibility()
        let oldHeight = bounds.height
        invalidateLayoutCache()
        setNeedsLayout()
        guard bounds.width > 0 else { return }
        let newLayout = layout(forWidth: bounds.width)
        if !appearing.isEmpty {
            // Appearing elements fade in at their destination instead of flying in from a stale frame.
            UIView.performWithoutAnimation {
                if appearing.contains(tile) { tile.frame = newLayout.tileFrame }
                if appearing.contains(badge) { badge.frame = newLayout.badgeFrame; badge.layoutIfNeeded() }
                if appearing.contains(accessoryIcon) { accessoryIcon.frame = newLayout.accessoryFrame }
            }
        }
        invalidateIntrinsicContentSize()
        if let groupSizeHandler {
            // The group re-evaluates shared stacking and animates every affected row and its height.
            groupSizeHandler(self, animate)
            return
        }
        if abs(newLayout.size.height - oldHeight) > 0.5 {
            superview?.setNeedsLayout()
        }
        if animate {
            RCMotion.animate(RCMotion.snappy) { self.layoutIfNeeded() }
        }
    }

    private static func effectiveTone(_ content: Content) -> RCIconTile.Tone {
        content.appearsEnabled ? content.tileTone : .muted
    }

    private func crossfade(_ view: UIView) {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = RCMotion.quickDuration
        transition.timingFunction = RCMotion.easeOut
        view.layer.add(transition, forKey: "rc.crossfade")
    }

    /// Shows or hides an element; animated changes fade. Returns true when a
    /// hidden element starts appearing (it needs its frame before the move).
    @discardableResult
    private func setVisible(_ view: UIView, _ visible: Bool, animated: Bool) -> Bool {
        guard animated else {
            view.isHidden = !visible
            view.alpha = 1
            return false
        }
        if visible {
            guard view.isHidden || view.alpha < 1 else { return false }
            let appearing = view.isHidden
            if appearing {
                view.alpha = 0
                view.isHidden = false
            }
            RCMotion.animate(duration: RCMotion.quickDuration) { view.alpha = 1 }
            return appearing
        }
        guard !view.isHidden, view.alpha > 0 else { return false }
        RCMotion.animate(duration: RCMotion.quickDuration, animations: { view.alpha = 0 }, completion: { _ in
            // Skip if the element was shown again while fading out.
            guard view.alpha == 0 else { return }
            view.isHidden = true
            view.alpha = 1
        })
        return false
    }

    override func updateAppearance() {
        withoutImplicitAnimations {
            highlightLayer.backgroundColor = RCColor.pressWash.cgColor(for: self)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory
            || traitCollection.layoutDirection != previousTraitCollection?.layoutDirection {
            invalidateLayoutCache()
        }
        super.traitCollectionDidChange(previousTraitCollection)
    }

    // MARK: Accessibility

    private func updateAccessibility() {
        accessibilityLabel = content.title
        let status = content.trailing.badgeValue?.text
        let value = [content.detail, status].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        accessibilityValue = value.isEmpty ? nil : value
        accessibilityTraits = content.trailing == .check ? [.button, .selected] : .button
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            var actions = storedCustomActions ?? []
            if let control = trailingView as? UIControl, control.isEnabled, !control.isHidden,
               let name = control.accessibilityLabel, !name.isEmpty {
                actions.append(UIAccessibilityCustomAction(name: name) { [weak control] _ in
                    guard let control else { return false }
                    let event: UIControl.Event = control.allControlEvents.contains(.primaryActionTriggered) ? .primaryActionTriggered : .touchUpInside
                    control.sendActions(for: event)
                    return true
                })
            }
            return actions.isEmpty ? nil : actions
        }
        set { storedCustomActions = newValue }
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        handleTap()
        return true
    }

    // MARK: Press feedback

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchDownTimestamp = touches.first?.timestamp
        didShowHighlightForTouch = false
        if let haptic { RCHaptics.prepare(haptic) }
        super.touchesBegan(touches, with: event)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(showPendingHighlight), object: nil)
            if isHighlighted {
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideFlashedHighlight), object: nil)
                isFlashingHighlight = false
                let delay = highlightDelay()
                touchDownTimestamp = nil
                if delay <= 0 {
                    showPendingHighlight()
                } else {
                    perform(#selector(showPendingHighlight), with: nil, afterDelay: delay, inModes: [.common])
                }
            } else if !isFlashingHighlight {
                setHighlightVisible(false)
            }
        }
    }

    /// Remaining wait before the highlight may show: zero outside scroll views
    /// and for touches the scroll view already delayed (`delaysContentTouches`).
    private func highlightDelay() -> TimeInterval {
        guard let timestamp = touchDownTimestamp, isInsideScrollView() else { return 0 }
        let elapsed = ProcessInfo.processInfo.systemUptime - timestamp
        return max(0, Self.scrollHighlightDelay - elapsed)
    }

    private func isInsideScrollView() -> Bool {
        var view = superview
        while let current = view {
            if let scrollView = current as? UIScrollView, scrollView.isScrollEnabled { return true }
            view = current.superview
        }
        return false
    }

    @objc private func showPendingHighlight() {
        guard isHighlighted else { return }
        didShowHighlightForTouch = true
        setHighlightVisible(true)
    }

    @objc private func hideFlashedHighlight() {
        isFlashingHighlight = false
        guard !isHighlighted else { return }
        setHighlightVisible(false)
    }

    private func setHighlightVisible(_ visible: Bool) {
        guard visible != isHighlightVisible else { return }
        isHighlightVisible = visible
        let target: Float = visible ? 1 : 0
        let current = highlightLayer.presentation()?.opacity ?? highlightLayer.opacity
        withoutImplicitAnimations { highlightLayer.opacity = target }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current
        fade.toValue = target
        fade.duration = visible ? RCMotion.pressDuration : RCMotion.releaseDuration
        fade.timingFunction = RCMotion.easeOut
        highlightLayer.add(fade, forKey: "opacity")
        groupHighlightHandler?(self, visible)
    }

    @objc private func handleTap() {
        if !didShowHighlightForTouch, !isHighlightVisible {
            // A quick tap inside a scroll view ended before the highlight delay: flash it.
            didShowHighlightForTouch = true
            isFlashingHighlight = true
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(showPendingHighlight), object: nil)
            setHighlightVisible(true)
            perform(#selector(hideFlashedHighlight), with: nil, afterDelay: RCMotion.pressDuration, inModes: [.common])
        }
        if let haptic { RCHaptics.play(haptic) }
        onTap?()
    }

    // MARK: Layout

    private struct LayoutKey: Equatable {
        var width: CGFloat
        var category: UIContentSizeCategory
        var direction: UITraitEnvironmentLayoutDirection
        var trailingViewSize: CGSize
        var forcesStacking: Bool
    }

    private func invalidateLayoutCache() {
        layoutCache.removeAll(keepingCapacity: true)
        cachedBadgeSize = nil
    }

    private var trailingViewSize: CGSize {
        guard let trailingView, !trailingView.isHidden else { return .zero }
        let fitted = trailingView.sizeThatFits(CGSize(width: RCLayout.minimumHitTarget * 2, height: RCLayout.minimumHitTarget))
        if fitted.width > 0, fitted.height > 0 { return fitted }
        let intrinsic = trailingView.intrinsicContentSize
        return CGSize(width: max(0, intrinsic.width), height: max(0, intrinsic.height))
    }

    /// Set by `RCListGroupView` so all badge rows of a card share one layout.
    fileprivate var groupStacksBadges = false {
        didSet {
            guard groupStacksBadges != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    /// Cached layout at `width` for the row's current traits.
    func layout(forWidth width: CGFloat) -> Layout {
        layout(forWidth: width, forcesStacking: groupStacksBadges)
    }

    private func layout(forWidth width: CGFloat, forcesStacking: Bool) -> Layout {
        let key = LayoutKey(width: width, category: traitCollection.preferredContentSizeCategory, direction: traitCollection.layoutDirection, trailingViewSize: trailingViewSize, forcesStacking: forcesStacking)
        if let hit = layoutCache.first(where: { $0.key == key }) { return hit.layout }
        let badgeSize: CGSize
        if content.trailing.badgeValue == nil {
            badgeSize = .zero
        } else if let cachedBadgeSize {
            badgeSize = cachedBadgeSize
        } else {
            badgeSize = badge.sizeThatFits(.zero)
            cachedBadgeSize = badgeSize
        }
        let computed = Self.layout(for: content, width: width, traits: traitCollection, badgeSize: badgeSize, trailingViewSize: key.trailingViewSize, forcesStacking: forcesStacking)
        if layoutCache.count >= 6 { layoutCache.removeFirst() }
        layoutCache.append((key, computed))
        return computed
    }

    /// Whether this row's own content needs the stacked layout at `width`.
    fileprivate func requiresStacking(forWidth width: CGFloat) -> Bool {
        layout(forWidth: width, forcesStacking: false).isStacked
    }

    /// Computes the row geometry without a view (deterministic, testable).
    /// `forcesStacking` stacks a badge row even when it would fit inline.
    static func layout(for content: Content, width: CGFloat, traits: UITraitCollection, badgeSize: CGSize = .zero, trailingViewSize: CGSize = .zero, forcesStacking: Bool = false) -> Layout {
        let width = max(0, width)
        let hasTile = content.glyph != nil
        let hasBadge = content.trailing.badgeValue != nil
        let hasAccessory = content.trailing.accessoryGlyph != nil
        let hasTrailingView = trailingViewSize.width > 0
        let detail = content.detail.flatMap { $0.isEmpty ? nil : $0 }
        let titleLineHeight = RCTypography.lineHeight(.bodyStrong, compatibleWith: traits)
        // One line box for both detail fonts so switching to/from an address never changes the height.
        let detailLineHeight = max(RCTypography.lineHeight(.footnote, compatibleWith: traits), RCTypography.lineHeight(.monoSmall, compatibleWith: traits))
        let detailStyle: RCTextStyle = content.detailIsMonospaced ? .monoSmall : .footnote

        let textX = insets.left + (hasTile ? tileSide + RCSpace.md : 0)
        var cursor = width - insets.right
        var accessoryX: CGFloat = 0
        if hasAccessory {
            cursor -= accessorySide
            accessoryX = cursor
            cursor -= RCSpace.xs
        }
        var trailingViewX: CGFloat = 0
        if hasTrailingView {
            cursor -= trailingViewSize.width
            trailingViewX = cursor
            cursor -= RCSpace.sm
        }
        let stackedTextWidth = max(0, cursor - textX)
        let inlineTextWidth = hasBadge ? max(0, cursor - badgeSize.width - RCSpace.sm - textX) : stackedTextWidth

        var isStacked = false
        if hasBadge {
            if forcesStacking || traits.preferredContentSizeCategory.isAccessibilityCategory || inlineTextWidth < minimumInlineTextWidth {
                isStacked = true
            } else if ListTextMetrics.lineCount(content.title, style: .bodyStrong, width: inlineTextWidth, traits: traits) > 2 {
                isStacked = true
            } else if let detail, ListTextMetrics.naturalWidth(detail, style: detailStyle, traits: traits) > inlineTextWidth {
                isStacked = true
            }
        }

        let textWidth = isStacked ? stackedTextWidth : inlineTextWidth
        let titleLines = min(2, ListTextMetrics.lineCount(content.title, style: .bodyStrong, width: textWidth, traits: traits))
        let titleHeight = CGFloat(titleLines) * titleLineHeight
        let textHeight = titleHeight + (detail == nil ? 0 : detailSpacing + detailLineHeight)
        let columnHeight = textHeight + (isStacked ? stackedBadgeSpacing + badgeSize.height : 0)
        let contentHeight = max(hasTile ? tileSide : 0, columnHeight, isStacked ? 0 : badgeSize.height, trailingViewSize.height, accessorySide)
        let height = ceil(contentHeight + insets.top + insets.bottom)

        var tileFrame = CGRect.zero
        var titleFrame: CGRect
        var detailFrame = CGRect.zero
        var badgeFrame = CGRect.zero
        if isStacked {
            let top = insets.top
            if hasTile { tileFrame = CGRect(x: insets.left, y: top, width: tileSide, height: tileSide) }
            titleFrame = CGRect(x: textX, y: top, width: textWidth, height: titleHeight)
            var y = titleFrame.maxY
            if detail != nil {
                detailFrame = CGRect(x: textX, y: y + detailSpacing, width: textWidth, height: detailLineHeight)
                y = detailFrame.maxY
            }
            badgeFrame = CGRect(x: textX, y: y + stackedBadgeSpacing, width: min(badgeSize.width, textWidth), height: badgeSize.height)
        } else {
            if hasTile { tileFrame = CGRect(x: insets.left, y: (height - tileSide) / 2, width: tileSide, height: tileSide) }
            let top = ((height - textHeight) / 2).rounded()
            titleFrame = CGRect(x: textX, y: top, width: textWidth, height: titleHeight)
            if detail != nil {
                detailFrame = CGRect(x: textX, y: titleFrame.maxY + detailSpacing, width: textWidth, height: detailLineHeight)
            }
            if hasBadge {
                badgeFrame = CGRect(x: cursor - badgeSize.width, y: ((height - badgeSize.height) / 2).rounded(), width: badgeSize.width, height: badgeSize.height)
            }
        }
        let trailingViewFrame = hasTrailingView
            ? CGRect(x: trailingViewX, y: ((height - trailingViewSize.height) / 2).rounded(), width: trailingViewSize.width, height: trailingViewSize.height)
            : .zero
        let accessoryFrame = hasAccessory
            ? CGRect(x: accessoryX, y: ((height - accessorySide) / 2).rounded(), width: accessorySide, height: accessorySide)
            : .zero

        var result = Layout(
            size: CGSize(width: width, height: height),
            isStacked: isStacked,
            titleLineCount: titleLines,
            tileFrame: tileFrame,
            titleFrame: titleFrame,
            detailFrame: detailFrame,
            badgeFrame: badgeFrame,
            trailingViewFrame: trailingViewFrame,
            accessoryFrame: accessoryFrame
        )
        if traits.layoutDirection == .rightToLeft {
            func mirror(_ rect: CGRect) -> CGRect {
                rect == .zero ? rect : CGRect(x: width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
            }
            result.tileFrame = mirror(result.tileFrame)
            result.titleFrame = mirror(result.titleFrame)
            result.detailFrame = mirror(result.detailFrame)
            result.badgeFrame = mirror(result.badgeFrame)
            result.trailingViewFrame = mirror(result.trailingViewFrame)
            result.accessoryFrame = mirror(result.accessoryFrame)
        }
        return result
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: bounds.width > 0 ? layout(forWidth: bounds.width).size.height : Self.tileSide + Self.insets.top + Self.insets.bottom)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: layout(forWidth: size.width).size.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let resolved = layout(forWidth: bounds.width)
        withoutImplicitAnimations {
            highlightLayer.frame = bounds.insetBy(dx: 4, dy: 2)
            highlightLayer.cornerRadius = RCRadius.md
            highlightLayer.cornerCurve = .continuous
        }
        // Elements absent from the layout keep their last frame while they fade out.
        if content.glyph != nil { tile.frame = resolved.tileFrame }
        titleLabel.frame = resolved.titleFrame
        if content.detail != nil { detailLabel.frame = resolved.detailFrame }
        if content.trailing.badgeValue != nil { badge.frame = resolved.badgeFrame }
        trailingView?.frame = resolved.trailingViewFrame
        if content.trailing.accessoryGlyph != nil { accessoryIcon.frame = resolved.accessoryFrame }
    }
}

private extension RCListRow.Trailing {
    var badgeValue: (text: String, tone: RCStatusBadge.Tone, busy: Bool)? {
        switch self {
        case let .badge(text, tone, busy), let .badgeAndChevron(text, tone, busy): (text, tone, busy)
        case .none, .chevron, .plus, .check: nil
        }
    }

    var accessoryGlyph: RCIconGlyph? {
        switch self {
        case .chevron, .badgeAndChevron: .chevronRight
        case .plus: .plus
        case .check: .check
        case .none, .badge: nil
        }
    }
}

/// Text measurement for row layout with explicit traits (no label instances).
@MainActor
private enum ListTextMetrics {
    static func naturalWidth(_ text: String, style: RCTextStyle, traits: UITraitCollection) -> CGFloat {
        ceil(attributed(text, style: style, traits: traits).size().width)
    }

    static func lineCount(_ text: String, style: RCTextStyle, width: CGFloat, traits: UITraitCollection) -> Int {
        guard !text.isEmpty, width > 0 else { return 1 }
        let rect = attributed(text, style: style, traits: traits).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        let lineHeight = max(1, RCTypography.lineHeight(style, compatibleWith: traits))
        return max(1, Int((rect.height / lineHeight).rounded()))
    }

    private static func attributed(_ text: String, style: RCTextStyle, traits: UITraitCollection) -> NSAttributedString {
        let value = style.spec.uppercase ? text.uppercased() : text
        return NSAttributedString(string: value, attributes: RCTypography.attributes(style, color: RCColor.text, lineBreakMode: .byWordWrapping, compatibleWith: traits))
    }
}

/// Card that stacks row views with inset hairline separators and animates
/// insertions, removals, moves and its own height.
///
/// **Height changes.** The group never resizes itself; its host owns the
/// frame. Whenever `setItems` (or a row's `configure(_:animated:)`) changes
/// the fitted height, `onHeightChange` is called with the new height —
/// inside the group's `RCMotion.standard` animation when animated. Hosts
/// re-lay out there (`view.setNeedsLayout(); view.layoutIfNeeded()`), so the
/// card, its shadow, the moving rows and everything below the card share one
/// spring.
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

    /// Identity changes between two id lists (moves are survivors whose
    /// relative order changed).
    struct Diff: Equatable {
        var inserted: [String] = []
        var removed: [String] = []
        var moved: [String] = []

        var isEmpty: Bool { inserted.isEmpty && removed.isEmpty && moved.isEmpty }
    }

    /// Leading inset of separators (aligns with row text after the tile).
    var separatorInset: CGFloat = 12 + 40 + 12 { didSet { setNeedsLayout() } }
    private(set) var items: [Item] = []
    /// New fitted height; called inside the animation when animated (see type docs).
    var onHeightChange: ((CGFloat) -> Void)?
    /// True while skeleton rows from `showPlaceholder(rows:animated:)` are displayed.
    private(set) var isShowingPlaceholder = false

    private static let separatorTrailingInset: CGFloat = 14
    private static let placeholderPrefix = "rc.placeholder."
    /// Inserted rows start fading in once neighbors have mostly cleared their slot.
    private static let insertionFadeDelay: TimeInterval = 0.1
    private static let fadeInKey = "rc.fadeIn"

    private var separators: [String: RCSeparator] = [:]
    private var departing: [ObjectIdentifier: Int] = [:]
    private var departureToken = 0
    private var highlightedIDs: Set<String> = []
    private var runningMoves = 0
    private var lifted: [ObjectIdentifier: UIView] = [:]

    init() {
        super.init(style: .card, cornerRadius: RCRadius.lg)
        contentInsets = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
    }

    /// A group showing `rows` skeleton rows (loading state).
    static func placeholder(rows: Int) -> RCListGroupView {
        let group = RCListGroupView()
        group.showPlaceholder(rows: rows, animated: false)
        return group
    }

    /// Replaces the content with `rows` skeleton rows sized like device rows.
    /// A later `setItems(_:animated:)` crossfades them into real rows.
    func showPlaceholder(rows: Int, animated: Bool) {
        let count = max(1, rows)
        let placeholders = (0..<count).map { index -> Item in
            let id = Self.placeholderPrefix + String(index)
            let view = items.first(where: { $0.id == id })?.view ?? ListSkeletonRow(index: index)
            return Item(id: id, view: view)
        }
        apply(placeholders, animated: animated)
        isShowingPlaceholder = true
        updateGroupAccessibility()
    }

    /// Replaces the rows. Views are matched by identity: reused views move to
    /// their new position, new ones fade in, removed ones fade and shrink out.
    /// Ids must be unique (later duplicates are ignored). See the type docs
    /// for how the height change is animated.
    func setItems(_ newItems: [Item], animated: Bool) {
        apply(newItems, animated: animated)
        isShowingPlaceholder = false
        updateGroupAccessibility()
    }

    static func diff(from old: [String], to new: [String]) -> Diff {
        let oldIndex = Dictionary(old.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var diff = Diff()
        for change in new.difference(from: old).inferringMoves() {
            switch change {
            case let .insert(_, id, associated):
                if associated == nil { diff.inserted.append(id) } else { diff.moved.append(id) }
            case let .remove(_, id, associated):
                if associated == nil { diff.removed.append(id) }
            }
        }
        diff.removed.sort { (oldIndex[$0] ?? 0) < (oldIndex[$1] ?? 0) }
        return diff
    }

    private func apply(_ requested: [Item], animated requestedAnimation: Bool) {
        var seen = Set<String>()
        let newItems = requested.filter { seen.insert($0.id).inserted }
        let animated = requestedAnimation && window != nil && bounds.width > 0
        let oldItems = items
        let newViews = Set(newItems.map { ObjectIdentifier($0.view) })
        let oldViews = Set(oldItems.map { ObjectIdentifier($0.view) })

        items = newItems
        highlightedIDs.formIntersection(Set(newItems.map(\.id)))
        contentView.accessibilityElements = newItems.map(\.view)

        var arriving: [UIView] = []
        for item in newItems {
            let key = ObjectIdentifier(item.view)
            if departing.removeValue(forKey: key) != nil {
                item.view.accessibilityElementsHidden = false
                if animated {
                    RCMotion.animate(duration: RCMotion.quickDuration) {
                        item.view.alpha = 1
                        item.view.transform = .identity
                    }
                } else {
                    item.view.alpha = 1
                    item.view.transform = .identity
                }
            } else if !oldViews.contains(key) || item.view.superview !== contentView {
                contentView.insertSubview(item.view, at: 0)
                arriving.append(item.view)
            }
            attachHooks(to: item.view)
        }

        for item in oldItems where !newViews.contains(ObjectIdentifier(item.view)) {
            detachHooks(from: item.view)
            depart(item.view, animated: animated)
        }

        let width = bounds.width - contentInsets.left - contentInsets.right
        let frames = rowFrames(width: max(0, width))
        let arrivingSet = Set(arriving.map(ObjectIdentifier.init))
        UIView.performWithoutAnimation {
            for (index, item) in newItems.enumerated() where arrivingSet.contains(ObjectIdentifier(item.view)) {
                item.view.transform = .identity
                item.view.frame = frames[index]
                item.view.layoutIfNeeded()
                item.view.alpha = 1
            }
        }
        updateSeparators(frames: frames, animated: animated)

        let newHeight = fittedHeight(width: bounds.width)
        let heightChanged = abs(newHeight - bounds.height) > 0.5
        guard animated else {
            setNeedsLayout()
            if heightChanged { onHeightChange?(newHeight) }
            return
        }
        let movedIDs = Set(Self.diff(from: oldItems.map(\.id), to: newItems.map(\.id)).moved)
        newItems.filter { movedIDs.contains($0.id) && oldViews.contains(ObjectIdentifier($0.view)) }.forEach(lift)
        beginMove()
        RCMotion.animate(RCMotion.standard, animations: {
            self.setNeedsLayout()
            self.layoutIfNeeded()
            if heightChanged { self.onHeightChange?(newHeight) }
        }, completion: { [weak self] _ in
            self?.endMove()
        })
        arriving.forEach { Self.fadeIn($0, duration: RCMotion.releaseDuration) }
    }

    /// A reordered row travels above its neighbors on the card color, so
    /// transparent rows never show through each other mid-flight.
    private func lift(_ item: Item) {
        let view = item.view
        let key = ObjectIdentifier(view)
        guard lifted[key] != nil || (view.backgroundColor == nil && view.layer.backgroundColor == nil) else { return }
        lifted[key] = view
        withoutImplicitAnimations {
            view.layer.backgroundColor = RCColor.elevated.cgColor(for: self)
            view.layer.cornerRadius = RCRadius.md
            view.layer.cornerCurve = .continuous
        }
        contentView.bringSubviewToFront(view)
        if let separator = separators[item.id] { contentView.bringSubviewToFront(separator) }
    }

    /// Returns lifted rows to rest once every overlapping move has finished.
    private func settleLiftedRows() {
        for view in lifted.values {
            withoutImplicitAnimations {
                view.layer.backgroundColor = nil
                view.layer.cornerRadius = 0
            }
            if view.superview === contentView { contentView.sendSubviewToBack(view) }
        }
        lifted.removeAll()
    }

    /// Render-server fade that holds the start value through the delay
    /// (`UIViewPropertyAnimator` with a delay would show the final alpha first).
    private static func fadeIn(_ view: UIView, duration: TimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = view.layer.opacity
        fade.duration = duration
        fade.timingFunction = RCMotion.easeOut
        fade.beginTime = view.layer.convertTime(CACurrentMediaTime(), from: nil) + (RCMotion.reduceMotion ? 0 : insertionFadeDelay)
        fade.fillMode = .backwards
        view.layer.add(fade, forKey: fadeInKey)
    }

    private func depart(_ view: UIView, animated: Bool) {
        guard animated else {
            view.removeFromSuperview()
            view.alpha = 1
            view.transform = .identity
            return
        }
        departureToken += 1
        let token = departureToken
        let key = ObjectIdentifier(view)
        departing[key] = token
        view.accessibilityElementsHidden = true
        if view.layer.animation(forKey: Self.fadeInKey) != nil {
            // Removed while still fading in: continue from what is on screen.
            view.alpha = CGFloat(view.layer.presentation()?.opacity ?? 0)
            view.layer.removeAnimation(forKey: Self.fadeInKey)
        }
        RCMotion.animate(duration: RCMotion.quickDuration, animations: {
            view.alpha = 0
            if !RCMotion.reduceMotion { view.transform = CGAffineTransform(scaleX: 0.96, y: 0.96) }
        }, completion: { [weak self] _ in
            guard let self, self.departing[key] == token else { return }
            self.departing[key] = nil
            view.removeFromSuperview()
            view.alpha = 1
            view.transform = .identity
            view.accessibilityElementsHidden = false
        })
    }

    /// Clips departing rows to the card while it shrinks.
    private func beginMove() {
        runningMoves += 1
        contentView.clipsToBounds = true
    }

    private func endMove() {
        runningMoves = max(0, runningMoves - 1)
        guard runningMoves == 0 else { return }
        contentView.clipsToBounds = false
        settleLiftedRows()
    }

    private func attachHooks(to view: UIView) {
        guard let row = view as? RCListRow else { return }
        row.groupHighlightHandler = { [weak self] row, visible in self?.rowHighlightChanged(row, visible: visible) }
        row.groupSizeHandler = { [weak self] _, animated in self?.rowSizeChanged(animated: animated) }
    }

    private func detachHooks(from view: UIView) {
        guard let row = view as? RCListRow else { return }
        row.groupHighlightHandler = nil
        row.groupSizeHandler = nil
        row.groupStacksBadges = false
    }

    private func rowHighlightChanged(_ row: RCListRow, visible: Bool) {
        guard let id = items.first(where: { $0.view === row })?.id else { return }
        if visible { highlightedIDs.insert(id) } else { highlightedIDs.remove(id) }
        let duration = visible ? RCMotion.pressDuration : RCMotion.releaseDuration
        let targets = separatorAlphaTargets()
        RCMotion.animate(duration: duration) {
            for (separator, alpha) in targets { separator.alpha = alpha }
        }
    }

    private func rowSizeChanged(animated: Bool) {
        let newHeight = fittedHeight(width: bounds.width)
        let heightChanged = abs(newHeight - bounds.height) > 0.5
        guard animated, window != nil else {
            setNeedsLayout()
            if heightChanged { onHeightChange?(newHeight) }
            return
        }
        beginMove()
        RCMotion.animate(RCMotion.standard, animations: {
            self.setNeedsLayout()
            self.layoutIfNeeded()
            if heightChanged { self.onHeightChange?(newHeight) }
        }, completion: { [weak self] _ in
            self?.endMove()
        })
    }

    // MARK: Separators

    private func updateSeparators(frames: [CGRect], animated: Bool) {
        let needed = items.dropLast().map(\.id)
        let neededSet = Set(needed)
        for (id, separator) in separators where !neededSet.contains(id) {
            separators[id] = nil
            if animated {
                RCMotion.animate(duration: RCMotion.quickDuration, animations: { separator.alpha = 0 }, completion: { _ in
                    separator.removeFromSuperview()
                })
            } else {
                separator.removeFromSuperview()
            }
        }
        var created: [RCSeparator] = []
        for (index, id) in needed.enumerated() where separators[id] == nil {
            let separator = RCSeparator()
            contentView.addSubview(separator)
            separators[id] = separator
            UIView.performWithoutAnimation {
                separator.frame = separatorFrame(below: frames[index], width: frames[index].width)
            }
            created.append(separator)
        }
        let targets = separatorAlphaTargets()
        let createdSet = Set(created.map(ObjectIdentifier.init))
        UIView.performWithoutAnimation {
            for (separator, alpha) in targets where createdSet.contains(ObjectIdentifier(separator)) { separator.alpha = alpha }
        }
        if animated {
            created.forEach { Self.fadeIn($0, duration: RCMotion.quickDuration) }
            RCMotion.animate(duration: RCMotion.quickDuration) {
                for (separator, alpha) in targets where !createdSet.contains(ObjectIdentifier(separator)) { separator.alpha = alpha }
            }
        } else {
            for (separator, alpha) in targets { separator.alpha = alpha }
        }
    }

    /// Separators beside a highlighted row disappear, like iOS lists.
    private func separatorAlphaTargets() -> [(RCSeparator, CGFloat)] {
        guard items.count > 1 else { return [] }
        return (0..<(items.count - 1)).compactMap { index in
            let id = items[index].id
            guard let separator = separators[id] else { return nil }
            let hidden = highlightedIDs.contains(id) || highlightedIDs.contains(items[index + 1].id)
            return (separator, hidden ? 0 : 1)
        }
    }

    private func separatorFrame(below rowFrame: CGRect, width: CGFloat) -> CGRect {
        let hairline = RCLayout.hairline
        let length = max(0, width - separatorInset - Self.separatorTrailingInset)
        let x = effectiveUserInterfaceLayoutDirection == .rightToLeft ? Self.separatorTrailingInset : separatorInset
        return CGRect(x: x, y: RCLayout.pixelAligned(rowFrame.maxY - hairline), width: length, height: hairline)
    }

    // MARK: Layout

    private func rowFrames(width: CGFloat) -> [CGRect] {
        updateSharedStacking(width: width)
        var y: CGFloat = 0
        return items.map { item in
            let height = ceil(item.view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            defer { y += height }
            return CGRect(x: 0, y: y, width: width, height: height)
        }
    }

    /// A card reads as one table: when any badge row must stack (large text,
    /// narrow column, long address), every badge row stacks, so statuses line
    /// up in one place instead of alternating between two.
    private func updateSharedStacking(width: CGFloat) {
        let rows = items.compactMap { $0.view as? RCListRow }
        guard rows.count > 1, width > 0 else {
            rows.forEach { $0.groupStacksBadges = false }
            return
        }
        let stacks = rows.contains { $0.requiresStacking(forWidth: width) }
        rows.forEach { $0.groupStacksBadges = stacks }
    }

    private func fittedHeight(width: CGFloat) -> CGFloat {
        let inner = max(0, width - contentInsets.left - contentInsets.right)
        let rows = rowFrames(width: inner).last?.maxY ?? 0
        return ceil(rows + contentInsets.top + contentInsets.bottom)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: fittedHeight(width: size.width))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory else { return }
        // Rows re-measure during this trait pass; report the new height once it settles.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.bounds.width > 0 else { return }
                let height = self.fittedHeight(width: self.bounds.width)
                if abs(height - self.bounds.height) > 0.5 { self.onHeightChange?(height) }
            }
        }
    }

    override func layoutSubviews() {
        let shadowLayers = [layer] + (layer.sublayers ?? []).filter { $0 !== contentView.layer && $0.shadowPath != nil }
        let oldPaths = shadowLayers.map(\.shadowPath)
        super.layoutSubviews()
        let frames = rowFrames(width: contentView.bounds.width)
        for (index, item) in items.enumerated() {
            let frame = frames[index]
            item.view.bounds = CGRect(origin: item.view.bounds.origin, size: frame.size)
            item.view.center = CGPoint(x: frame.midX, y: frame.midY)
            if index < items.count - 1, let separator = separators[item.id] {
                separator.frame = separatorFrame(below: frame, width: frame.width)
            }
        }
        animateShadowPaths(of: shadowLayers, from: oldPaths)
    }

    /// `RCSurfaceView` sets shadow paths without actions; when the card's
    /// size is animating, run the paths on the same timing so the shadow
    /// never detaches from the card.
    private func animateShadowPaths(of layers: [CALayer], from oldPaths: [CGPath?]) {
        guard let sizeAnimation = (layer.animation(forKey: "bounds.size") ?? layer.animation(forKey: "bounds")) as? CABasicAnimation else { return }
        for (target, oldPath) in zip(layers, oldPaths) {
            guard let oldPath, let newPath = target.shadowPath, oldPath != newPath else { continue }
            guard let animation = sizeAnimation.copy() as? CABasicAnimation else { continue }
            animation.keyPath = "shadowPath"
            animation.isAdditive = false
            animation.fromValue = target.presentation()?.shadowPath ?? oldPath
            animation.toValue = newPath
            target.add(animation, forKey: "rc.shadowPath")
        }
    }

    private func updateGroupAccessibility() {
        isAccessibilityElement = isShowingPlaceholder
        accessibilityLabel = isShowingPlaceholder ? "Loading" : nil
        accessibilityTraits = isShowingPlaceholder ? .updatesFrequently : .none
    }
}

/// Skeleton stand-in for a device row. Geometry comes from `RCListRow.layout`
/// for a representative device row, so loading never changes the card height
/// (including the stacked layout at accessibility sizes).
@MainActor
private final class ListSkeletonRow: RCView {
    private let tile = RCSkeletonView()
    private let titleBar = RCSkeletonView()
    private let detailBar = RCSkeletonView()
    private let badgePill = RCSkeletonView()
    /// Hidden real badge, measured with this row's traits.
    private let badgeProbe = RCStatusBadge(text: "Online", tone: .neutral)
    private let titleFraction: CGFloat
    private let detailFraction: CGFloat
    private var cachedLayout: (width: CGFloat, category: UIContentSizeCategory, layout: RCListRow.Layout)?

    private static let sample = RCListRow.Content(
        title: "Device",
        detail: "192.168.1.20:8080",
        detailIsMonospaced: true,
        glyph: .tabletSmartphone,
        trailing: .badgeAndChevron(text: "Online", tone: .neutral, busy: false)
    )

    init(index: Int) {
        let titles: [CGFloat] = [0.52, 0.38, 0.46]
        let details: [CGFloat] = [0.34, 0.44, 0.28]
        titleFraction = titles[index % titles.count]
        detailFraction = details[index % details.count]
        super.init(frame: .zero)
    }

    override func setUp() {
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        tile.cornerRadius = RCListRow.tileSide * 0.28
        titleBar.cornerRadius = RCRadius.xs
        detailBar.cornerRadius = RCRadius.xs
        badgePill.cornerRadius = RCRadius.lg
        badgeProbe.isHidden = true
        [tile, titleBar, detailBar, badgePill, badgeProbe].forEach(addSubview)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        cachedLayout = nil
    }

    private func layout(width: CGFloat) -> RCListRow.Layout {
        let category = traitCollection.preferredContentSizeCategory
        if let cachedLayout, cachedLayout.width == width, cachedLayout.category == category { return cachedLayout.layout }
        let computed = RCListRow.layout(for: Self.sample, width: width, traits: traitCollection, badgeSize: badgeProbe.sizeThatFits(.zero))
        cachedLayout = (width, category, computed)
        return computed
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: layout(width: size.width).size.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let resolved = layout(width: bounds.width)
        let titleLine = RCTypography.lineHeight(.bodyStrong, compatibleWith: traitCollection)
        let barHeight = (titleLine * 0.55).rounded()
        let detailHeight = (resolved.detailFrame.height * 0.5).rounded()
        tile.frame = resolved.tileFrame
        titleBar.frame = CGRect(x: resolved.titleFrame.minX, y: resolved.titleFrame.minY + (titleLine - barHeight) / 2, width: resolved.titleFrame.width * titleFraction, height: barHeight)
        detailBar.frame = CGRect(x: resolved.detailFrame.minX, y: resolved.detailFrame.midY - detailHeight / 2, width: resolved.detailFrame.width * detailFraction, height: detailHeight)
        badgePill.frame = resolved.badgeFrame.insetBy(dx: 0, dy: 2)
        if effectiveUserInterfaceLayoutDirection == .rightToLeft {
            for bar in [titleBar, detailBar] {
                // Layout frames are already mirrored; anchor the shortened bars to the leading (right) edge.
                let full = bar === titleBar ? resolved.titleFrame : resolved.detailFrame
                bar.frame.origin.x = full.maxX - bar.frame.width
            }
        }
    }
}

