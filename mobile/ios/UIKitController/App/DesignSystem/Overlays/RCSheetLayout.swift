import UIKit

/// Inputs for resolving sheet geometry. A plain value so the math is unit-tested
/// without UIKit views.
struct RCSheetGeometry: Equatable, Sendable {
    enum Style: Equatable, Sendable {
        /// Phone / compact width: attached to the bottom edge, top corners rounded.
        case bottomSheet
        /// iPad regular width: centered floating card, all corners rounded.
        case card
    }

    var style: Style
    /// Container (window) size.
    var containerSize: CGSize
    var safeAreaInsets: UIEdgeInsets
    /// Height of the container covered by a docked keyboard.
    var keyboardHeight: CGFloat = 0
    /// Content's `preferredContentSize.height`; nil or ≤ 0 when it did not provide one.
    var preferredContentHeight: CGFloat?
}

/// Pure geometry and gesture math for `RCSheet`.
enum RCSheetLayout {
    /// Gap between the top safe area and a `.large` bottom sheet.
    static let largeTopGap: CGFloat = 10
    static let mediumFraction: CGFloat = 0.5
    static let cardMaxWidth: CGFloat = 540
    static let cardMaxHeightFraction: CGFloat = 0.8
    /// Minimum distance between a card and the container edges.
    static let cardMargin: CGFloat = 20
    /// Widest bottom sheet on a landscape phone (readable column).
    static let landscapeMaxWidth: CGFloat = 620
    /// Smallest sheet height ever produced.
    static let minimumHeight: CGFloat = 64

    /// Height a sheet may use at most (the `.large` detent).
    static func maximumHeight(in geometry: RCSheetGeometry) -> CGFloat {
        let size = geometry.containerSize
        let safe = geometry.safeAreaInsets
        let keyboard = max(0, geometry.keyboardHeight)
        switch geometry.style {
        case .bottomSheet:
            return max(minimumHeight, size.height - keyboard - safe.top - largeTopGap)
        case .card:
            let bottomInset = keyboard > 0 ? keyboard : safe.bottom
            let available = size.height - safe.top - bottomInset - cardMargin * 2
            return max(minimumHeight, min(size.height * cardMaxHeightFraction, available))
        }
    }

    /// Extra height added below the content: the home indicator area for a
    /// bottom sheet resting on the bottom edge; nothing above a keyboard or for cards.
    static func bottomAccessoryHeight(in geometry: RCSheetGeometry) -> CGFloat {
        guard geometry.style == .bottomSheet, geometry.keyboardHeight <= 0 else { return 0 }
        return geometry.safeAreaInsets.bottom
    }

    /// Resolved sheet height for one detent (clamped to `maximumHeight`).
    static func height(for detent: RCSheetDetent, in geometry: RCSheetGeometry) -> CGFloat {
        let maximum = maximumHeight(in: geometry)
        let accessory = bottomAccessoryHeight(in: geometry)
        let raw: CGFloat
        switch detent {
        case .fitting:
            if let preferred = geometry.preferredContentHeight, preferred > 0 {
                raw = preferred + accessory
            } else {
                raw = geometry.containerSize.height * mediumFraction
            }
        case .medium:
            raw = geometry.containerSize.height * mediumFraction
        case .large:
            raw = maximum
        case let .height(value):
            raw = max(0, value) + accessory
        }
        return min(maximum, max(minimumHeight, raw.rounded(.up)))
    }

    /// Distinct detent heights, ascending. Detents that resolve within half a
    /// point of each other collapse into one stop.
    static func resolvedHeights(for detents: [RCSheetDetent], in geometry: RCSheetGeometry) -> [CGFloat] {
        let heights = (detents.isEmpty ? [.fitting] : detents).map { height(for: $0, in: geometry) }.sorted()
        var result: [CGFloat] = []
        for value in heights where result.last.map({ abs($0 - value) > 0.5 }) ?? true {
            result.append(value)
        }
        return result
    }

    /// Index into `resolvedHeights` nearest to `detent`.
    static func index(of detent: RCSheetDetent, in heights: [CGFloat], geometry: RCSheetGeometry) -> Int {
        let target = height(for: detent, in: geometry)
        return nearestIndex(to: target, in: heights)
    }

    static func nearestIndex(to value: CGFloat, in heights: [CGFloat]) -> Int {
        guard !heights.isEmpty else { return 0 }
        var best = 0
        for (index, height) in heights.enumerated() where abs(height - value) < abs(heights[best] - value) {
            best = index
        }
        return best
    }

    /// Frame of the sheet at rest for a given height.
    static func frame(height: CGFloat, in geometry: RCSheetGeometry) -> CGRect {
        let size = geometry.containerSize
        let safe = geometry.safeAreaInsets
        let keyboard = max(0, geometry.keyboardHeight)
        switch geometry.style {
        case .bottomSheet:
            var width = size.width
            if size.width > size.height {
                width = min(size.width - safe.left - safe.right, landscapeMaxWidth)
            }
            width = max(0, min(size.width, width))
            return CGRect(x: ((size.width - width) / 2).rounded(), y: size.height - keyboard - height, width: width, height: height)
        case .card:
            let width = max(0, min(cardMaxWidth, size.width - safe.left - safe.right - cardMargin * 2))
            let top = safe.top + cardMargin
            let bottom = size.height - (keyboard > 0 ? keyboard : safe.bottom) - cardMargin
            let y = top + max(0, (bottom - top - height) / 2)
            return CGRect(x: ((size.width - width) / 2).rounded(), y: y.rounded(), width: width, height: height)
        }
    }

    // MARK: Gesture

    enum SnapTarget: Equatable, Sendable {
        case detent(Int)
        case dismiss
    }

    /// Where a released drag settles. `visibleHeight` is the sheet height the
    /// finger implies (detent height at rest minus the downward drag);
    /// `velocity` is the vertical finger velocity in pt/s (positive = down).
    /// Chooses the stop nearest to the projected position; a dismissible sheet
    /// also dismisses on a fast downward flick from its smallest detent.
    static func snapTarget(visibleHeight: CGFloat, velocity: CGFloat, detentHeights: [CGFloat], isDismissible: Bool) -> SnapTarget {
        guard !detentHeights.isEmpty else { return isDismissible ? .dismiss : .detent(0) }
        let projected = visibleHeight - RCModalSupport.projectedDistance(velocity: velocity)
        if isDismissible, let smallest = detentHeights.first {
            if velocity > 1600, visibleHeight <= smallest + 1 { return .dismiss }
            if projected < smallest / 2, velocity > -200 { return .dismiss }
        }
        var best = 0
        for (index, height) in detentHeights.enumerated() where abs(height - projected) < abs(detentHeights[best] - projected) {
            best = index
        }
        return .detent(best)
    }

    /// Displayed state for a drag. The raw `visibleHeight` is split into a
    /// sheet height within the detent range plus a stretch above the largest
    /// detent (rubber-banded) or a downward offset below the smallest detent
    /// (free when dismissible, rubber-banded otherwise).
    struct DragState: Equatable, Sendable {
        var height: CGFloat
        var stretch: CGFloat
        var offset: CGFloat
    }

    static func dragState(visibleHeight: CGFloat, detentHeights: [CGFloat], isDismissible: Bool, resizes: Bool, restHeight: CGFloat) -> DragState {
        guard let smallest = detentHeights.first, let largest = detentHeights.last else {
            return DragState(height: restHeight, stretch: 0, offset: 0)
        }
        let limit: CGFloat = 80
        if visibleHeight > largest {
            let stretch = RCModalSupport.rubberBand(visibleHeight - largest, dimension: limit)
            return resizes
                ? DragState(height: largest, stretch: stretch, offset: 0)
                : DragState(height: restHeight, stretch: 0, offset: -(largest - restHeight) - stretch)
        }
        if visibleHeight < smallest {
            let under = smallest - visibleHeight
            let offset = isDismissible ? under : RCModalSupport.rubberBand(under, dimension: limit)
            return resizes
                ? DragState(height: smallest, stretch: 0, offset: offset)
                : DragState(height: restHeight, stretch: 0, offset: (restHeight - smallest) + offset)
        }
        return resizes
            ? DragState(height: visibleHeight, stretch: 0, offset: 0)
            : DragState(height: restHeight, stretch: 0, offset: restHeight - visibleHeight)
    }
}
