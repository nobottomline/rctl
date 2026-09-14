import UIKit

/// 4-point spacing scale.
enum RCSpace {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
    static let huge: CGFloat = 40
    static let giant: CGFloat = 56
}

/// Corner radii. Always pair with `cornerCurve = .continuous` (`RCView.applyCornerRadius`).
enum RCRadius {
    /// Tiny chips, keycaps.
    static let xs: CGFloat = 6
    /// Menu item highlights, small controls.
    static let sm: CGFloat = 8
    /// Buttons, inputs, icon tiles, segmented controls.
    static let md: CGFloat = 12
    /// Cards and grouped lists.
    static let lg: CGFloat = 16
    /// Menus, popovers, toasts.
    static let xl: CGFloat = 20
    /// Sheets and dialogs.
    static let xxl: CGFloat = 26
}

enum RCLayout {
    /// Horizontal page margin on phones.
    static let gutter: CGFloat = 20
    /// Readable column on iPad and landscape.
    static let maxContentWidth: CGFloat = 620
    /// Narrow column for forms and sheets.
    static let maxFormWidth: CGFloat = 520
    /// Minimum hit target on every interactive element.
    static let minimumHitTarget: CGFloat = 44
    /// Height of the custom top bar content (excluding the status bar).
    static let topBarHeight: CGFloat = 52

    /// A single device pixel.
    @MainActor static var hairline: CGFloat { 1 / UIScreen.main.scale }

    /// Rounds to the device pixel grid to avoid blurry edges.
    @MainActor static func pixelAligned(_ value: CGFloat) -> CGFloat {
        let scale = UIScreen.main.scale
        return (value * scale).rounded() / scale
    }

    @MainActor static func pixelAligned(_ rect: CGRect) -> CGRect {
        CGRect(
            x: pixelAligned(rect.minX),
            y: pixelAligned(rect.minY),
            width: pixelAligned(rect.width),
            height: pixelAligned(rect.height)
        )
    }

    /// Horizontal inset that centers a readable column of `maxWidth` inside
    /// `width`, never smaller than the gutter plus safe-area insets.
    static func columnInset(width: CGFloat, safeArea: UIEdgeInsets, maxWidth: CGFloat = maxContentWidth) -> (left: CGFloat, right: CGFloat) {
        let minimumLeft = gutter + safeArea.left
        let minimumRight = gutter + safeArea.right
        let available = width - minimumLeft - minimumRight
        guard available > maxWidth else { return (minimumLeft, minimumRight) }
        let extra = (available - maxWidth) / 2
        return (minimumLeft + extra, minimumRight + extra)
    }
}
