import UIKit

/// Custom navigation header used instead of `UINavigationBar`. It sits at the
/// top of a screen (the navigation bar is hidden app-wide), extends under the
/// status bar, and reveals a solid background + hairline and a small centered
/// title as content scrolls beneath it (`setScrollProgress`).
///
/// Typical wiring with a large title as the first scroll element:
/// ```swift
/// func scrollViewDidScroll(_ scrollView: UIScrollView) {
///     topBar.setScrollProgress(largeTitle.collapseProgress(in: scrollView, topBarHeight: topBar.bounds.height))
/// }
/// ```
/// Scroll updates only set layer opacities and one label transform; they never
/// trigger layout.
@MainActor
final class RCTopBar: RCView {
    /// Small centered title that fades in on scroll.
    var title: String? {
        didSet {
            guard title != oldValue else { return }
            titleLabel.text = title
            setNeedsLayout()
        }
    }

    var showsBackButton = false {
        didSet {
            guard showsBackButton != oldValue else { return }
            backButton.isHidden = !showsBackButton
            setNeedsLayout()
        }
    }

    var onBack: (() -> Void)?

    /// Views placed at the leading edge after the back button (e.g. brand mark).
    var leadingViews: [UIView] = [] { didSet { replace(oldValue, with: leadingViews) } }

    /// Views placed at the trailing edge, in the order given (leading → trailing).
    var trailingViews: [UIView] = [] { didSet { replace(oldValue, with: trailingViews) } }

    /// Use on the media stage: always transparent, white glyphs, overlay back button.
    var isOverlayStyle = false {
        didSet {
            guard isOverlayStyle != oldValue else { return }
            updateAppearance()
        }
    }

    /// Width of the page's readable column (`RCLayout.maxContentWidth` or
    /// `maxFormWidth`). When set, leading and trailing items are inset with
    /// `RCLayout.columnInset` so they line up with the column on wide screens
    /// (iPad) instead of hugging the screen edges; nil keeps edge alignment.
    var contentColumnWidth: CGFloat? {
        didSet {
            guard contentColumnWidth != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// Keeps the small title visible at rest instead of fading it in with
    /// scroll progress (e.g. the media stage, which has no large title).
    var showsTitleAtRest = false {
        didSet {
            guard showsTitleAtRest != oldValue else { return }
            applyProgress()
        }
    }

    let backButton = RCIconButton(icon: .chevronLeft, variant: .plain, diameter: RCTopBar.backButtonDiameter, accessibilityLabel: "Back")

    /// Scroll progress last applied (0...1).
    private(set) var scrollProgress: CGFloat = 0

    let titleLabel = RCLabel(style: .headline, alignment: .center)
    private let backgroundLayer = CALayer()
    private let hairlineLayer = CALayer()
    private var titleVisibility: CGFloat = -1

    static let backButtonDiameter: CGFloat = 40
    /// Space between adjacent bar items.
    static let itemSpacing: CGFloat = RCSpace.sm
    /// Circular buttons sit slightly outside the content gutter so their
    /// glyphs, not their circles, align with the column below.
    static let edgeInset: CGFloat = RCLayout.gutter - 4
    /// Minimum space between the title and the nearest side item.
    static let titleSpacing: CGFloat = RCSpace.md
    /// Distance the small title rises while it fades in.
    private static let titleRise: CGFloat = 5

    override func setUp() {
        layer.addSublayer(backgroundLayer)
        layer.addSublayer(hairlineLayer)
        titleLabel.alpha = 0
        titleLabel.accessibilityTraits = .header
        titleLabel.isUserInteractionEnabled = false
        addSubview(titleLabel)
        backButton.isHidden = true
        backButton.onTap = { [weak self] in self?.onBack?() }
        addSubview(backButton)
        applyProgress()
    }

    private func replace(_ old: [UIView], with new: [UIView]) {
        for view in old where !new.contains(where: { $0 === view }) && view.superview === self {
            view.removeFromSuperview()
        }
        for view in new where view.superview !== self {
            addSubview(view)
        }
        setNeedsLayout()
    }

    // MARK: Scroll progress

    /// 0 = content at rest (transparent bar), 1 = scrolled past the large
    /// title (solid bar, hairline, small title visible).
    func setScrollProgress(_ value: CGFloat) {
        let clamped = value.isFinite ? min(max(value, 0), 1) : 0
        guard abs(clamped - scrollProgress) > 0.001 || (clamped != scrollProgress && (clamped == 0 || clamped == 1)) else { return }
        scrollProgress = clamped
        applyProgress()
    }

    /// Convenience: progress from a scroll view's offset, reaching 1 after `distance` points.
    func track(_ scrollView: UIScrollView, distance: CGFloat = 44) {
        let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        setScrollProgress(offset / max(distance, 1))
    }

    private func applyProgress() {
        let chrome: Float = isOverlayStyle ? 0 : Float(scrollProgress)
        withoutImplicitAnimations {
            backgroundLayer.opacity = chrome
            // The hairline trails the fill slightly so a half-faded bar never
            // shows a hard line over content that is still visible through it.
            hairlineLayer.opacity = chrome * chrome
        }
        let visibility = showsTitleAtRest ? 1 : Self.smoothstep(0.4, 1, scrollProgress)
        guard abs(visibility - titleVisibility) > 0.001 || visibility == 0 || visibility == 1 else { return }
        titleVisibility = visibility
        titleLabel.alpha = visibility
        let rise = RCMotion.reduceMotion ? 0 : (1 - visibility) * Self.titleRise
        titleLabel.transform = rise == 0 ? .identity : CGAffineTransform(translationX: 0, y: rise)
    }

#if DEBUG
    /// The solid background layer that fades in with scroll progress (tests).
    var backgroundLayerForTesting: CALayer { backgroundLayer }
#endif

    private static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: Appearance

    override func updateAppearance() {
        withoutImplicitAnimations {
            // Fully opaque once solid: any translucency lets scrolled text ghost through.
            backgroundLayer.backgroundColor = RCColor.background.cgColor(for: self)
            hairlineLayer.backgroundColor = RCColor.line.cgColor(for: self)
        }
        titleLabel.color = isOverlayStyle ? RCColor.onStage : RCColor.text
        backButton.variant = isOverlayStyle ? .overlay : .plain
        applyProgress()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.layoutDirection != previousTraitCollection?.layoutDirection {
            setNeedsLayout()
        }
    }

    override var semanticContentAttribute: UISemanticContentAttribute {
        didSet { setNeedsLayout() }
    }

    // MARK: Layout

    /// Height including the top safe-area inset of the hosting view.
    func preferredHeight(safeAreaTop: CGFloat) -> CGFloat {
        safeAreaTop + RCLayout.topBarHeight
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: preferredHeight(safeAreaTop: safeAreaInsets.top))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let backGlyph: RCIconGlyph = isRightToLeft ? .chevronRight : .chevronLeft
        if backButton.icon != backGlyph { backButton.icon = backGlyph }

        withoutImplicitAnimations {
            backgroundLayer.frame = bounds
            hairlineLayer.frame = CGRect(x: 0, y: bounds.height - RCLayout.hairline, width: bounds.width, height: RCLayout.hairline)
        }

        let width = bounds.width
        let barHeight = min(RCLayout.topBarHeight, bounds.height)
        let centerY = bounds.height - barHeight / 2
        let edges = Self.itemEdges(width: width, safeArea: safeAreaInsets, contentColumnWidth: contentColumnWidth, isRightToLeft: isRightToLeft)
        let maxItemSize = CGSize(width: width / 2, height: barHeight)

        // Lay out in a leading-to-trailing coordinate space, then mirror for RTL.
        func place(_ view: UIView, x: CGFloat, size: CGSize) {
            let logical = CGRect(x: x, y: centerY - size.height / 2, width: size.width, height: size.height)
            let physical = isRightToLeft
                ? CGRect(x: width - logical.maxX, y: logical.minY, width: logical.width, height: logical.height)
                : logical
            view.frame = RCLayout.pixelAligned(physical)
        }

        var leadingEdge = edges.leading
        if showsBackButton {
            let side = Self.backButtonDiameter
            place(backButton, x: leadingEdge, size: CGSize(width: side, height: side))
            leadingEdge += side + Self.itemSpacing
        }
        for view in leadingViews {
            let size = Self.fittedSize(of: view, in: maxItemSize)
            place(view, x: leadingEdge, size: size)
            leadingEdge += size.width + Self.itemSpacing
        }
        let leadingItemsEnd = leadingEdge - ((showsBackButton || !leadingViews.isEmpty) ? Self.itemSpacing : 0)

        var trailingEdge = width - edges.trailing
        for view in trailingViews.reversed() {
            let size = Self.fittedSize(of: view, in: maxItemSize)
            trailingEdge -= size.width
            place(view, x: trailingEdge, size: size)
            trailingEdge -= Self.itemSpacing
        }
        let trailingItemsStart = trailingEdge + (trailingViews.isEmpty ? 0 : Self.itemSpacing)

        let titleFrame = Self.titleFrame(
            width: width,
            leadingItemsEnd: leadingItemsEnd,
            trailingItemsStart: trailingItemsStart,
            titleWidth: ceil(titleLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: barHeight)).width),
            spacing: Self.titleSpacing
        )
        let titleHeight = min(barHeight, ceil(titleLabel.sizeThatFits(CGSize(width: max(titleFrame.width, 1), height: barHeight)).height))
        let logicalTitle = CGRect(x: titleFrame.minX, y: centerY - titleHeight / 2, width: titleFrame.width, height: titleHeight)
        // Keep the rise transform out of the frame math.
        let transform = titleLabel.transform
        titleLabel.transform = .identity
        titleLabel.frame = RCLayout.pixelAligned(isRightToLeft
            ? CGRect(x: width - logicalTitle.maxX, y: logicalTitle.minY, width: logicalTitle.width, height: logicalTitle.height)
            : logicalTitle)
        titleLabel.transform = transform
    }

    /// Distances from the leading and trailing screen edges to the outer edge of
    /// the first and last item. Items sit `gutter - edgeInset` outside the
    /// content column so circular buttons' glyphs align with the column below;
    /// with a column width that column is `RCLayout.columnInset`.
    static func itemEdges(width: CGFloat, safeArea: UIEdgeInsets, contentColumnWidth: CGFloat?, isRightToLeft: Bool) -> (leading: CGFloat, trailing: CGFloat) {
        let outset = RCLayout.gutter - edgeInset
        var left = safeArea.left + RCLayout.gutter
        var right = safeArea.right + RCLayout.gutter
        if let contentColumnWidth {
            (left, right) = RCLayout.columnInset(width: width, safeArea: safeArea, maxWidth: contentColumnWidth)
        }
        let leading = (isRightToLeft ? right : left) - outset
        let trailing = (isRightToLeft ? left : right) - outset
        return (leading, trailing)
    }

    /// Horizontal title span in leading-to-trailing coordinates. The title is
    /// centered on the bar when it fits between symmetric side reserves;
    /// otherwise it is centered in the space actually left between the items,
    /// and truncates rather than overlapping them.
    nonisolated static func titleFrame(width: CGFloat, leadingItemsEnd: CGFloat, trailingItemsStart: CGFloat, titleWidth: CGFloat, spacing: CGFloat) -> (minX: CGFloat, width: CGFloat) {
        let leadingLimit = leadingItemsEnd + spacing
        let trailingLimit = trailingItemsStart - spacing
        let reserve = max(leadingLimit, width - trailingLimit)
        let symmetricWidth = width - reserve * 2
        if symmetricWidth > 0, titleWidth <= symmetricWidth {
            return (reserve, symmetricWidth)
        }
        let available = max(0, trailingLimit - leadingLimit)
        let used = min(titleWidth, available)
        return (leadingLimit + (available - used) / 2, used)
    }

    private static func fittedSize(of view: UIView, in limit: CGSize) -> CGSize {
        var size = view.sizeThatFits(limit)
        if size.width <= 0 || size.height <= 0 {
            let intrinsic = view.intrinsicContentSize
            size = CGSize(
                width: intrinsic.width > 0 ? intrinsic.width : view.bounds.width,
                height: intrinsic.height > 0 ? intrinsic.height : view.bounds.height
            )
        }
        return CGSize(width: min(ceil(size.width), limit.width), height: min(ceil(size.height), limit.height))
    }

    // MARK: Hit testing

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard hit === self else { return hit }
        // Transparent areas let touches fall through to the content beneath;
        // once the bar is solid it behaves like a bar and absorbs them.
        return isOverlayStyle || scrollProgress < 0.5 ? nil : hit
    }
}
