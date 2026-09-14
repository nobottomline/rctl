import CoreText
import UIKit

/// Type scale. San Francisco (the web client also uses `system-ui`) with
/// tightened tracking on large sizes, SF Mono for machine data (addresses,
/// metrics). All styles scale with Dynamic Type through `UIFontMetrics`,
/// capped so dense operational chrome stays usable.
enum RCTextStyle: CaseIterable, Sendable {
    /// 32 bold — screen titles ("Devices").
    case display
    /// 24 semibold — sheet and dialog hero titles.
    case title1
    /// 20 semibold — section heroes, empty states.
    case title2
    /// 17 semibold — dialog titles, prominent row titles.
    case headline
    /// 16 regular — default body.
    case body
    /// 16 semibold — row titles, button labels (large).
    case bodyStrong
    /// 15 regular.
    case callout
    /// 15 semibold — button labels (medium).
    case calloutStrong
    /// 14 regular — secondary copy.
    case subheadline
    /// 14 semibold — small button labels.
    case subheadlineStrong
    /// 13 regular — row details, helper text.
    case footnote
    /// 13 semibold.
    case footnoteStrong
    /// 12 medium — badges, captions.
    case caption
    /// 11 semibold, uppercase, wide tracking — section overlines.
    case overline
    /// 14 SF Mono — addresses, endpoints.
    case mono
    /// 12 SF Mono medium — compact machine data, metrics.
    case monoSmall

    struct Spec: Sendable {
        let size: CGFloat
        let weight: UIFont.Weight
        /// Letter spacing in points at the base size.
        let tracking: CGFloat
        /// Line height in points at the base size.
        let lineHeight: CGFloat
        let textStyle: UIFont.TextStyle
        let monospaced: Bool
        let uppercase: Bool
        /// Largest point size Dynamic Type may scale this style to.
        let maximumSize: CGFloat
    }

    var spec: Spec {
        switch self {
        case .display:
            Spec(size: 32, weight: .bold, tracking: -0.8, lineHeight: 38, textStyle: .largeTitle, monospaced: false, uppercase: false, maximumSize: 44)
        case .title1:
            Spec(size: 24, weight: .semibold, tracking: -0.5, lineHeight: 30, textStyle: .title1, monospaced: false, uppercase: false, maximumSize: 36)
        case .title2:
            Spec(size: 20, weight: .semibold, tracking: -0.35, lineHeight: 26, textStyle: .title2, monospaced: false, uppercase: false, maximumSize: 32)
        case .headline:
            Spec(size: 17, weight: .semibold, tracking: -0.25, lineHeight: 22, textStyle: .headline, monospaced: false, uppercase: false, maximumSize: 28)
        case .body:
            Spec(size: 16, weight: .regular, tracking: -0.16, lineHeight: 22, textStyle: .body, monospaced: false, uppercase: false, maximumSize: 28)
        case .bodyStrong:
            Spec(size: 16, weight: .semibold, tracking: -0.16, lineHeight: 22, textStyle: .body, monospaced: false, uppercase: false, maximumSize: 28)
        case .callout:
            Spec(size: 15, weight: .regular, tracking: -0.12, lineHeight: 20, textStyle: .callout, monospaced: false, uppercase: false, maximumSize: 26)
        case .calloutStrong:
            Spec(size: 15, weight: .semibold, tracking: -0.12, lineHeight: 20, textStyle: .callout, monospaced: false, uppercase: false, maximumSize: 26)
        case .subheadline:
            Spec(size: 14, weight: .regular, tracking: -0.08, lineHeight: 19, textStyle: .subheadline, monospaced: false, uppercase: false, maximumSize: 24)
        case .subheadlineStrong:
            Spec(size: 14, weight: .semibold, tracking: -0.08, lineHeight: 19, textStyle: .subheadline, monospaced: false, uppercase: false, maximumSize: 24)
        case .footnote:
            Spec(size: 13, weight: .regular, tracking: -0.04, lineHeight: 18, textStyle: .footnote, monospaced: false, uppercase: false, maximumSize: 22)
        case .footnoteStrong:
            Spec(size: 13, weight: .semibold, tracking: -0.04, lineHeight: 18, textStyle: .footnote, monospaced: false, uppercase: false, maximumSize: 22)
        case .caption:
            Spec(size: 12, weight: .medium, tracking: 0, lineHeight: 16, textStyle: .caption1, monospaced: false, uppercase: false, maximumSize: 20)
        case .overline:
            Spec(size: 11, weight: .semibold, tracking: 0.9, lineHeight: 14, textStyle: .caption2, monospaced: false, uppercase: true, maximumSize: 17)
        case .mono:
            Spec(size: 14, weight: .regular, tracking: 0, lineHeight: 19, textStyle: .subheadline, monospaced: true, uppercase: false, maximumSize: 24)
        case .monoSmall:
            Spec(size: 12, weight: .medium, tracking: 0, lineHeight: 16, textStyle: .caption1, monospaced: true, uppercase: false, maximumSize: 20)
        }
    }
}

@MainActor
enum RCTypography {
    private static var cache: [CacheKey: UIFont] = [:]

    private struct CacheKey: Hashable {
        let style: RCTextStyle
        let category: String
        let monospacedDigits: Bool
    }

    /// Scaled font for a style and content size category. Cached; cheap to call
    /// from `layoutSubviews` or `sizeThatFits`.
    static func font(
        _ style: RCTextStyle,
        compatibleWith traits: UITraitCollection? = nil,
        monospacedDigits: Bool = false
    ) -> UIFont {
        let traits = traits ?? UIScreen.main.traitCollection
        let key = CacheKey(style: style, category: traits.preferredContentSizeCategory.rawValue, monospacedDigits: monospacedDigits)
        if let cached = cache[key] { return cached }
        let spec = style.spec
        var base = spec.monospaced
            ? UIFont.monospacedSystemFont(ofSize: spec.size, weight: spec.weight)
            : UIFont.systemFont(ofSize: spec.size, weight: spec.weight)
        if monospacedDigits, !spec.monospaced {
            let setting: [UIFontDescriptor.FeatureKey: Int]
            if #available(iOS 15.0, *) {
                setting = [.type: kNumberSpacingType, .selector: kMonospacedNumbersSelector]
            } else {
                setting = [UIFontDescriptor.FeatureKey(rawValue: "CTFeatureTypeIdentifier"): kNumberSpacingType,
                           UIFontDescriptor.FeatureKey(rawValue: "CTFeatureSelectorIdentifier"): kMonospacedNumbersSelector]
            }
            let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: [setting]])
            base = UIFont(descriptor: descriptor, size: spec.size)
        }
        let scaled = UIFontMetrics(forTextStyle: spec.textStyle)
            .scaledFont(for: base, maximumPointSize: spec.maximumSize, compatibleWith: traits)
        cache[key] = scaled
        return scaled
    }

    /// Scale factor Dynamic Type applies to a style (1 at the default size).
    static func scale(for style: RCTextStyle, compatibleWith traits: UITraitCollection? = nil) -> CGFloat {
        font(style, compatibleWith: traits).pointSize / style.spec.size
    }

    /// Attributes applying font, color, tracking and line height. Line height
    /// uses min/max line height with a baseline correction so single-line
    /// labels stay optically centered.
    static func attributes(
        _ style: RCTextStyle,
        color: UIColor,
        alignment: NSTextAlignment = .natural,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail,
        compatibleWith traits: UITraitCollection? = nil,
        monospacedDigits: Bool = false
    ) -> [NSAttributedString.Key: Any] {
        let font = font(style, compatibleWith: traits, monospacedDigits: monospacedDigits)
        let spec = style.spec
        let scale = font.pointSize / spec.size
        let lineHeight = (spec.lineHeight * scale).rounded()
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreakMode
        return [
            .font: font,
            .foregroundColor: color,
            .kern: spec.tracking * scale,
            .paragraphStyle: paragraph,
            .baselineOffset: (lineHeight - font.lineHeight) / 4,
        ]
    }

    /// Line height in points for a style at the given traits.
    static func lineHeight(_ style: RCTextStyle, compatibleWith traits: UITraitCollection? = nil) -> CGFloat {
        (style.spec.lineHeight * scale(for: style, compatibleWith: traits)).rounded()
    }

    static func invalidateCache() {
        cache.removeAll()
    }
}
