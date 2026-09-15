import UIKit

/// Screen title block placed as the first element of scroll content: a large
/// `display` title and an optional quiet subtitle. Pair it with `RCTopBar`,
/// whose small title takes over exactly as this one slides under the bar:
///
/// ```swift
/// func scrollViewDidScroll(_ scrollView: UIScrollView) {
///     topBar.setScrollProgress(largeTitle.collapseProgress(in: scrollView, topBarHeight: topBar.bounds.height))
/// }
/// ```
///
/// Frame-based: position it with `sizeThatFits(_:)` at the content column width.
@MainActor
final class RCLargeTitleView: RCView {
    var title: String {
        didSet {
            guard title != oldValue else { return }
            titleLabel.text = title
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    var subtitle: String? {
        didSet {
            guard subtitle != oldValue else { return }
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = Self.isEmpty(subtitle)
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    let titleLabel = RCLabel(style: .display, lines: 0)
    let subtitleLabel = RCLabel(style: .callout, color: RCColor.textSecondary, lines: 0)

    /// Gap between the title and the subtitle.
    static let subtitleSpacing: CGFloat = RCSpace.xs + 2

    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        super.init(frame: .zero)
        titleLabel.text = title
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = Self.isEmpty(subtitle)
    }

    override func setUp() {
        titleLabel.accessibilityTraits = .header
        addSubview(titleLabel)
        addSubview(subtitleLabel)
    }

    private static func isEmpty(_ value: String?) -> Bool {
        value?.isEmpty ?? true
    }

    /// How far the title has slid under a top bar whose bottom edge is
    /// `topBarHeight` points below the scroll view's top edge: 0 while the
    /// title is fully below the bar, 1 once it is completely covered.
    /// Cheap enough to call from every `scrollViewDidScroll`.
    func collapseProgress(in scrollView: UIScrollView, topBarHeight: CGFloat) -> CGFloat {
        guard isDescendant(of: scrollView), titleLabel.bounds.height > 0 else { return 0 }
        let frame = titleLabel.convert(titleLabel.bounds, to: scrollView)
        let visibleTop = frame.minY - scrollView.bounds.minY
        return Self.collapseProgress(titleTop: visibleTop, titleHeight: frame.height, barBottom: topBarHeight)
    }

    nonisolated static func collapseProgress(titleTop: CGFloat, titleHeight: CGFloat, barBottom: CGFloat) -> CGFloat {
        guard titleHeight > 0 else { return 0 }
        return min(max((barBottom - titleTop) / titleHeight, 0), 1)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = max(0, size.width)
        let limit = CGSize(width: width, height: .greatestFiniteMagnitude)
        var height = ceil(titleLabel.sizeThatFits(limit).height)
        if !subtitleLabel.isHidden {
            height += Self.subtitleSpacing + ceil(subtitleLabel.sizeThatFits(limit).height)
        }
        return CGSize(width: width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let limit = CGSize(width: width, height: .greatestFiniteMagnitude)
        let titleHeight = ceil(titleLabel.sizeThatFits(limit).height)
        titleLabel.frame = CGRect(x: 0, y: 0, width: width, height: titleHeight)
        if !subtitleLabel.isHidden {
            let subtitleHeight = ceil(subtitleLabel.sizeThatFits(limit).height)
            subtitleLabel.frame = CGRect(x: 0, y: titleHeight + Self.subtitleSpacing, width: width, height: subtitleHeight)
        }
    }
}
