import UIKit

/// Balanced wrapping for short centered copy (titles, one-sentence guidance):
/// the narrowest width that keeps the line count, so a two-line sentence
/// splits evenly instead of leaving a one-word last line. UIKit has no
/// balanced line-break strategy, and this has to work on iOS 13.
@MainActor
enum PairingTextBalance {
    /// Width at most `maxWidth` at which `label` wraps into as few lines as
    /// it does at `maxWidth`. Single-line text keeps `maxWidth`.
    static func width(of label: UILabel, fitting maxWidth: CGFloat) -> CGFloat {
        guard maxWidth > 1, label.numberOfLines != 1, label.text?.isEmpty == false else { return maxWidth }
        func height(_ width: CGFloat) -> CGFloat {
            ceil(label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        }
        let target = height(maxWidth)
        let single = ceil(label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).height)
        guard target > single + 0.5 else { return maxWidth }
        // Balanced lines can never be narrower than an even split of the widest layout.
        var low = floor(maxWidth * 0.5)
        var high = maxWidth
        while high - low > 2 {
            let mid = floor((low + high) / 2)
            if height(mid) <= target + 0.5 { high = mid } else { low = mid }
        }
        return ceil(high)
    }
}
