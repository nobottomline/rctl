import CoreGraphics

/// Placement math for dropdown and context menus. Deliberately UIKit-free so
/// every flip/clamp/keyboard rule is unit tested without a window
/// (`Tests/Menus/RCMenuLayoutTests.swift`). All rects share one coordinate
/// space: the window that hosts the overlay.
struct RCMenuLayoutMetrics: Equatable, Sendable {
    /// Distance between the anchor (or lifted preview) and the panel.
    var gap: CGFloat = 8
    /// Minimum distance between the panel and the safe area / keyboard.
    var margin: CGFloat = 8
    var minimumWidth: CGFloat = 220
    var maximumWidth: CGFloat = 320
    /// Smallest scrolling height worth showing on the preferred side before
    /// the larger side wins (about two rows plus panel padding).
    var minimumUsefulHeight: CGFloat = 96
    /// Scale of a lifted context-menu preview.
    var liftScale: CGFloat = 1.02
    /// Smallest scale a preview may shrink to so the menu still fits.
    var minimumPreviewScale: CGFloat = 0.5

    static let standard = RCMenuLayoutMetrics()
}

enum RCMenuEdge: Equatable, Sendable {
    /// Panel sits below the anchor and grows downward.
    case below
    /// Panel sits above the anchor and grows upward.
    case above
}

struct RCMenuPlacement: Equatable, Sendable {
    var frame: CGRect
    var edge: RCMenuEdge
    /// Content is taller than `frame` and must scroll.
    var scrolls: Bool
    /// Largest height the panel may grow to on `edge` (used when a submenu
    /// changes the content height without re-placing the panel).
    var maximumHeight: CGFloat
    /// Unit point of `frame` nearest the anchor: the scale/translate origin
    /// of the open and close motion.
    var transformOrigin: CGPoint
}

struct RCContextMenuPlacement: Equatable, Sendable {
    /// Final frame of the lifted preview (already scaled by `previewScale`).
    var previewFrame: CGRect
    var previewScale: CGFloat
    var menu: RCMenuPlacement
}

enum RCMenuLayout {
    struct Environment: Equatable, Sendable {
        /// Container bounds (the window).
        var bounds: CGRect
        /// Safe-area rect inside `bounds`.
        var safeArea: CGRect
        /// Keyboard frame in container coordinates; nil or empty when hidden.
        var keyboard: CGRect?
        var isRightToLeft = false
        var metrics = RCMenuLayoutMetrics.standard

        init(bounds: CGRect, safeArea: CGRect? = nil, keyboard: CGRect? = nil, isRightToLeft: Bool = false, metrics: RCMenuLayoutMetrics = .standard) {
            self.bounds = bounds
            self.safeArea = safeArea ?? bounds
            self.keyboard = keyboard
            self.isRightToLeft = isRightToLeft
            self.metrics = metrics
        }
    }

    /// Region a panel may occupy: safe area inset by the margin, cut above a
    /// docked keyboard. Floating/undocked keyboards do not reach the bottom
    /// edge and are ignored (they can be moved out of the way).
    static func limits(in environment: Environment) -> CGRect {
        let margin = environment.metrics.margin
        var limits = environment.safeArea.intersection(environment.bounds)
        if limits.isNull { limits = environment.bounds }
        limits = limits.insetBy(dx: margin, dy: margin)
        if limits.width < 0 { limits = CGRect(x: environment.bounds.midX, y: limits.minY, width: 0, height: limits.height) }
        if limits.height < 0 { limits = CGRect(x: limits.minX, y: environment.bounds.midY, width: limits.width, height: 0) }
        if let keyboard = environment.keyboard, !keyboard.isEmpty,
           keyboard.maxY >= environment.bounds.maxY - 1,
           keyboard.minY < limits.maxY {
            let bottom = max(limits.minY, keyboard.minY - margin)
            limits.size.height = bottom - limits.minY
        }
        return limits
    }

    /// Panel width: natural content width, at least the minimum, grown to the
    /// anchor width when asked, never above the maximum or the available width.
    static func panelWidth(contentWidth: CGFloat, anchorWidth: CGFloat?, available: CGFloat, metrics: RCMenuLayoutMetrics) -> CGFloat {
        var width = max(contentWidth, metrics.minimumWidth)
        if let anchorWidth { width = max(width, anchorWidth) }
        return max(0, min(width, metrics.maximumWidth, available))
    }

    /// Dropdown placement next to `anchor`.
    static func place(
        contentSize: CGSize,
        anchor: CGRect,
        direction: RCMenu.Direction,
        alignment: RCMenu.Alignment,
        matchesAnchorWidth: Bool = true,
        in environment: Environment
    ) -> RCMenuPlacement {
        let metrics = environment.metrics
        let limits = limits(in: environment)
        let width = panelWidth(
            contentWidth: contentSize.width,
            anchorWidth: matchesAnchorWidth ? anchor.width : nil,
            available: limits.width,
            metrics: metrics
        )
        let spaceBelow = limits.maxY - (anchor.maxY + metrics.gap)
        let spaceAbove = (anchor.minY - metrics.gap) - limits.minY
        let edge = chooseEdge(
            height: contentSize.height,
            below: spaceBelow,
            above: spaceAbove,
            direction: direction,
            metrics: metrics
        )
        let space = max(0, edge == .below ? spaceBelow : spaceAbove)
        // A side smaller than a useful height (anchor covering most of the
        // screen) still gets a usable panel that overlaps the anchor.
        let maximumHeight = min(limits.height, max(space, min(metrics.minimumUsefulHeight, limits.height)))
        let height = min(contentSize.height, maximumHeight)
        var y = edge == .below ? anchor.maxY + metrics.gap : anchor.minY - metrics.gap - height
        y = clamp(y, limits.minY, limits.maxY - height)

        var x = horizontalOrigin(width: width, anchor: anchor, alignment: alignment, limits: limits, isRightToLeft: environment.isRightToLeft)
        x = clamp(x, limits.minX, limits.maxX - width)
        let frame = CGRect(x: x, y: y, width: width, height: max(0, height))
        return RCMenuPlacement(
            frame: frame,
            edge: edge,
            scrolls: height < contentSize.height - 0.5,
            maximumHeight: maximumHeight,
            transformOrigin: transformOrigin(frame: frame, anchor: anchor, edge: edge)
        )
    }

    /// Context-menu placement: the lifted preview stays over its source when
    /// the menu fits below or above it; otherwise the preview shifts up to
    /// make room, and only when even that fails does it shrink and the menu
    /// scroll.
    static func placeContextMenu(
        contentSize: CGSize,
        source: CGRect,
        in environment: Environment
    ) -> RCContextMenuPlacement {
        let metrics = environment.metrics
        let limits = limits(in: environment)
        let menuWidth = panelWidth(contentWidth: contentSize.width, anchorWidth: nil, available: limits.width, metrics: metrics)
        let menuHeight = contentSize.height

        var scale = metrics.liftScale
        if source.width > 0, source.width * scale > limits.width {
            scale = max(metrics.minimumPreviewScale, limits.width / source.width)
        }
        var preview = scaledRect(source, scale: scale)
        preview = clampedPreview(preview, in: limits)

        let spaceBelow = limits.maxY - (preview.maxY + metrics.gap)
        let spaceAbove = (preview.minY - metrics.gap) - limits.minY
        var edge = RCMenuEdge.below
        var height = menuHeight
        var maximumHeight: CGFloat
        if menuHeight <= spaceBelow {
            maximumHeight = spaceBelow
        } else if menuHeight <= spaceAbove {
            edge = .above
            maximumHeight = spaceAbove
        } else if preview.height + metrics.gap + menuHeight <= limits.height {
            // Shift the preview up just enough for the menu to fit below it.
            preview.origin.y = limits.maxY - menuHeight - metrics.gap - preview.height
            maximumHeight = menuHeight
        } else {
            // Shrink the preview (down to the minimum scale), then let the menu scroll.
            let budget = limits.height - metrics.gap - min(menuHeight, max(metrics.minimumUsefulHeight, limits.height / 2))
            if source.height > 0 {
                scale = min(scale, max(metrics.minimumPreviewScale, budget / source.height))
            }
            preview = clampedPreview(scaledRect(source, scale: scale), in: limits)
            preview.origin.y = limits.minY
            // A preview that still fills the screen gets overlapped by a menu of useful height.
            let usefulHeight = min(menuHeight, metrics.minimumUsefulHeight, limits.height)
            maximumHeight = max(limits.maxY - (preview.maxY + metrics.gap), usefulHeight)
            height = min(menuHeight, maximumHeight)
        }

        var y = edge == .below ? preview.maxY + metrics.gap : preview.minY - metrics.gap - height
        y = clamp(y, limits.minY, limits.maxY - height)
        var x = horizontalOrigin(width: menuWidth, anchor: preview, alignment: .automatic, limits: limits, isRightToLeft: environment.isRightToLeft)
        x = clamp(x, limits.minX, limits.maxX - menuWidth)
        let frame = CGRect(x: x, y: y, width: menuWidth, height: max(0, height))
        let menu = RCMenuPlacement(
            frame: frame,
            edge: edge,
            scrolls: height < menuHeight - 0.5,
            maximumHeight: maximumHeight,
            transformOrigin: transformOrigin(frame: frame, anchor: preview, edge: edge)
        )
        return RCContextMenuPlacement(previewFrame: preview, previewScale: scale, menu: menu)
    }

    // MARK: - Helpers

    private static func chooseEdge(height: CGFloat, below: CGFloat, above: CGFloat, direction: RCMenu.Direction, metrics: RCMenuLayoutMetrics) -> RCMenuEdge {
        let preferred: RCMenuEdge = direction == .up ? .above : .below
        let other: RCMenuEdge = preferred == .below ? .above : .below
        let space = { (edge: RCMenuEdge) in edge == .below ? below : above }
        if height <= space(preferred) { return preferred }
        if height <= space(other) { return other }
        // Neither side fits the whole menu, so it will scroll.
        switch direction {
        case .automatic:
            return space(other) > space(preferred) ? other : preferred
        case .down, .up:
            // An explicit direction holds while that side is still useful.
            if space(preferred) >= min(height, metrics.minimumUsefulHeight) { return preferred }
            return space(other) > space(preferred) ? other : preferred
        }
    }

    private static func horizontalOrigin(width: CGFloat, anchor: CGRect, alignment: RCMenu.Alignment, limits: CGRect, isRightToLeft: Bool) -> CGFloat {
        let leftAligned = anchor.minX
        let rightAligned = anchor.maxX - width
        switch alignment {
        case .leading:
            return isRightToLeft ? rightAligned : leftAligned
        case .trailing:
            return isRightToLeft ? leftAligned : rightAligned
        case .center:
            return anchor.midX - width / 2
        case .automatic:
            // Grow away from the nearer edge. A centered anchor narrower than
            // the panel gets a centered panel; a wide one follows reading direction.
            let toLeft = anchor.minX - limits.minX
            let toRight = limits.maxX - anchor.maxX
            if abs(toLeft - toRight) < 1 {
                if anchor.width < width { return anchor.midX - width / 2 }
                return isRightToLeft ? rightAligned : leftAligned
            }
            return toLeft < toRight ? leftAligned : rightAligned
        }
    }

    private static func transformOrigin(frame: CGRect, anchor: CGRect, edge: RCMenuEdge) -> CGPoint {
        let x = frame.width > 0 ? clamp((anchor.midX - frame.minX) / frame.width, 0, 1) : 0.5
        return CGPoint(x: x, y: edge == .below ? 0 : 1)
    }

    private static func scaledRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Keeps a preview inside the limits on each axis where it fits.
    private static func clampedPreview(_ rect: CGRect, in limits: CGRect) -> CGRect {
        var rect = rect
        if rect.width <= limits.width { rect.origin.x = clamp(rect.minX, limits.minX, limits.maxX - rect.width) }
        if rect.height <= limits.height { rect.origin.y = clamp(rect.minY, limits.minY, limits.maxY - rect.height) }
        return rect
    }

    /// Clamp that tolerates an empty range (upper < lower) by pinning to lower.
    static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard upper >= lower else { return lower }
        return min(max(value, lower), upper)
    }
}
