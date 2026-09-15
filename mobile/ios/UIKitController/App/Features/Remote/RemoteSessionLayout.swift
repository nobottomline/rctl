import UIKit

/// Frame math for the remote screen. Chrome never covers the viewport: the
/// video area is whatever remains between the header and the dock (or the
/// keyboard panel that replaces it).
///
/// - `bars`: portrait phones and every iPad size. Full-bleed header under the
///   status bar, floating dock centered at the bottom (≤ 680 pt).
/// - `rail`: landscape phones. A slim header pill at the top-leading corner and
///   a vertical dock rail on the trailing side, so the video keeps the full
///   screen height.
struct RemoteSessionLayout: Equatable {
    enum Style: Equatable {
        case bars
        case rail
    }

    struct Input {
        var size: CGSize
        var safeArea: UIEdgeInsets
        var style: Style
        /// `bars`: header content height below the top safe area. `rail`: header pill height.
        var headerHeight: CGFloat
        /// `rail` only: header pill width.
        var headerWidth: CGFloat = 0
        /// Dock size fitted to `dockAvailableWidth` (bars) or the rail size (rail).
        var dockSize: CGSize
        /// Non-nil while the keyboard panel replaces the dock.
        var keyboardPanelHeight: CGFloat?
        /// Height of the system keyboard covering the bottom of the view.
        var keyboardOverlap: CGFloat = 0
    }

    static let margin: CGFloat = 12
    static let gap: CGFloat = 8
    static let maximumDockWidth: CGFloat = 680

    let style: Style
    let header: CGRect
    /// The dock, or the keyboard panel while it is shown.
    let dock: CGRect
    let viewport: CGRect

    /// Containers shorter than this in landscape use the rail (every landscape
    /// phone, short Stage Manager windows); iPads are always taller.
    static let railMaximumHeight: CGFloat = 500

    /// Chooses the rail layout for short, wide containers. Decided from the
    /// size alone: size classes can lag the bounds during rotation.
    static func style(for size: CGSize) -> Style {
        size.width > size.height && size.height < railMaximumHeight ? .rail : .bars
    }

    /// Width the bars-style dock or keyboard panel may use.
    static func dockAvailableWidth(size: CGSize, safeArea: UIEdgeInsets) -> CGFloat {
        min(maximumDockWidth, max(0, size.width - safeArea.left - safeArea.right - margin * 2))
    }

    /// Width the rail-style keyboard panel may use, right of the header pill.
    static func railPanelAvailableWidth(size: CGSize, safeArea: UIEdgeInsets, headerWidth: CGFloat) -> CGFloat {
        let leading = max(safeArea.left, margin) + headerWidth + gap
        return max(0, size.width - max(safeArea.right, margin) - leading)
    }

    init(_ input: Input) {
        style = input.style
        switch input.style {
        case .bars: (header, dock, viewport) = Self.bars(input)
        case .rail: (header, dock, viewport) = Self.rail(input)
        }
    }

    private static func bars(_ input: Input) -> (CGRect, CGRect, CGRect) {
        let size = input.size
        let safe = input.safeArea
        let header = CGRect(x: 0, y: 0, width: size.width, height: safe.top + input.headerHeight)
        let restingBottom = max(safe.bottom - 6, margin)
        let available = dockAvailableWidth(size: size, safeArea: safe)
        let dockHeight: CGFloat
        let dockWidth: CGFloat
        let bottomInset: CGFloat
        if let panelHeight = input.keyboardPanelHeight {
            dockHeight = panelHeight
            dockWidth = available
            bottomInset = input.keyboardOverlap > 0 ? max(input.keyboardOverlap + gap, restingBottom) : restingBottom
        } else {
            dockHeight = input.dockSize.height
            dockWidth = min(input.dockSize.width, available)
            bottomInset = restingBottom
        }
        let columnX = safe.left + margin
        let columnWidth = max(0, size.width - safe.left - safe.right - margin * 2)
        let dock = CGRect(
            x: columnX + (columnWidth - dockWidth) / 2,
            y: size.height - bottomInset - dockHeight,
            width: dockWidth,
            height: dockHeight
        )
        let top = header.maxY + gap
        let viewport = CGRect(
            x: safe.left,
            y: top,
            width: max(0, size.width - safe.left - safe.right),
            height: max(0, dock.minY - gap - top)
        )
        return (header, dock, viewport)
    }

    private static func rail(_ input: Input) -> (CGRect, CGRect, CGRect) {
        let size = input.size
        let safe = input.safeArea
        let leading = max(safe.left, margin)
        let trailing = max(safe.right, margin)
        let top = max(safe.top, margin)
        let header = CGRect(x: leading, y: top, width: input.headerWidth, height: input.headerHeight)
        let videoX = header.maxX + gap
        if let panelHeight = input.keyboardPanelHeight {
            let restingBottom = max(safe.bottom, margin)
            let bottomInset = input.keyboardOverlap > 0 ? max(input.keyboardOverlap + gap, restingBottom) : restingBottom
            let dock = CGRect(
                x: videoX,
                y: size.height - bottomInset - panelHeight,
                width: max(0, size.width - trailing - videoX),
                height: panelHeight
            )
            let viewport = CGRect(
                x: videoX,
                y: 0,
                width: max(0, size.width - safe.right - videoX),
                height: max(0, dock.minY - gap)
            )
            return (header, dock, viewport)
        }
        let availableHeight = size.height - top - max(safe.bottom, margin)
        let dock = CGRect(
            x: size.width - trailing - input.dockSize.width,
            y: top + max(0, (availableHeight - input.dockSize.height) / 2),
            width: input.dockSize.width,
            height: input.dockSize.height
        )
        let viewport = CGRect(x: videoX, y: 0, width: max(0, dock.minX - gap - videoX), height: size.height)
        return (header, dock, viewport)
    }
}
