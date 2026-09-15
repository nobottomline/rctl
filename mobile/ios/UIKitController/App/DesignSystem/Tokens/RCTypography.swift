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
        let category: UIContentSizeCategory
        let boldText: Bool
        let monospacedDigits: Bool
    }

    /// Scaled font for a style and content size category. Cached; cheap to call
    /// from `layoutSubviews` or `sizeThatFits`. Honors the Bold Text setting
    /// (`legibilityWeight`), which system fonts with an explicit weight do not
    /// pick up on their own.
    static func font(
        _ style: RCTextStyle,
        compatibleWith traits: UITraitCollection? = nil,
        monospacedDigits: Bool = false
    ) -> UIFont {
        let category = resolvedCategory(traits)
        let boldText = (traits ?? UIScreen.main.traitCollection).legibilityWeight == .bold
        let key = CacheKey(style: style, category: category, boldText: boldText, monospacedDigits: monospacedDigits)
        if let cached = cache[key] { return cached }
        let spec = style.spec
        let weight = boldText ? bolder(spec.weight) : spec.weight
        var base = spec.monospaced
            ? UIFont.monospacedSystemFont(ofSize: spec.size, weight: weight)
            : UIFont.systemFont(ofSize: spec.size, weight: weight)
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
            .scaledFont(for: base, maximumPointSize: spec.maximumSize, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        cache[key] = scaled
        return scaled
    }

    /// Scale factor Dynamic Type applies to a style (1 at the default size).
    static func scale(for style: RCTextStyle, compatibleWith traits: UITraitCollection? = nil) -> CGFloat {
        font(style, compatibleWith: traits).pointSize / style.spec.size
    }

    /// Attributes applying font, color, tracking and line height. Line height
    /// uses min/max line height with a baseline correction so single-line
    /// labels stay optically centered (see `baselineOffset(lineHeight:font:)`).
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
            .baselineOffset: baselineOffset(lineHeight: lineHeight, font: font),
        ]
    }

    /// Styled string for `text`: uppercases overline styles and drops the
    /// tracking after the last character, so centered and trailing-aligned
    /// text is not pushed off-center by trailing letter spacing and measured
    /// widths match the ink.
    static func attributedString(
        _ text: String,
        style: RCTextStyle,
        color: UIColor,
        alignment: NSTextAlignment = .natural,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail,
        compatibleWith traits: UITraitCollection? = nil,
        monospacedDigits: Bool = false
    ) -> NSAttributedString {
        let value = style.spec.uppercase ? text.uppercased() : text
        let attributes = attributes(style, color: color, alignment: alignment, lineBreakMode: lineBreakMode, compatibleWith: traits, monospacedDigits: monospacedDigits)
        let string = NSMutableAttributedString(string: value, attributes: attributes)
        if style.spec.tracking != 0, let last = value.indices.last {
            string.removeAttribute(.kern, range: NSRange(last..<value.endIndex, in: value))
        }
        return string
    }

    /// Line height in points for a style at the given traits.
    static func lineHeight(_ style: RCTextStyle, compatibleWith traits: UITraitCollection? = nil) -> CGFloat {
        (style.spec.lineHeight * scale(for: style, compatibleWith: traits)).rounded()
    }

    /// Distance from the top of a line box to the baseline for text laid out
    /// with `attributes(_:)`. Use it to baseline-align labels of different styles.
    static func firstBaseline(_ style: RCTextStyle, compatibleWith traits: UITraitCollection? = nil) -> CGFloat {
        let font = font(style, compatibleWith: traits)
        let lineHeight = lineHeight(style, compatibleWith: traits)
        return lineHeight + font.descender - centeringLift(lineHeight: lineHeight, font: font)
    }

    /// Baseline lift that centers glyphs in a line box of `lineHeight`.
    ///
    /// With a fixed line height, text layout puts all extra space above the
    /// glyphs, so the baseline has to rise by half of it to match where a plain
    /// `UILabel` of the font's natural height would draw. The renderer floors
    /// the offset to device pixels, so it is rounded to the nearest pixel here.
    /// Before iOS 16.4 the renderer applied `baselineOffset` twice (with its own
    /// rounding), so a quarter of the extra space is passed there. Measured
    /// against a plain `UILabel` at 3x: within one pixel on iOS 18.6 and 26.1,
    /// within 1.3 px on iOS 15.5. A line box shorter than the font (display)
    /// needs no lift.
    static func baselineOffset(lineHeight: CGFloat, font: UIFont) -> CGFloat {
        if #available(iOS 16.4, *) {
            return centeringLift(lineHeight: lineHeight, font: font)
        }
        return max(0, lineHeight - font.lineHeight) / 4
    }

    private static func centeringLift(lineHeight: CGFloat, font: UIFont) -> CGFloat {
        let scale = UIScreen.main.scale
        return (max(0, lineHeight - font.lineHeight) / 2 * scale).rounded() / scale
    }

    static func invalidateCache() {
        cache.removeAll()
    }

    /// A view outside a window can report `.unspecified`; fall back to the
    /// screen so the cache never stores a font for a stale category.
    private static func resolvedCategory(_ traits: UITraitCollection?) -> UIContentSizeCategory {
        let category = traits?.preferredContentSizeCategory ?? .unspecified
        if category != .unspecified { return category }
        let screen = UIScreen.main.traitCollection.preferredContentSizeCategory
        return screen == .unspecified ? .large : screen
    }

    /// The weight step Bold Text applies to system text styles.
    private static func bolder(_ weight: UIFont.Weight) -> UIFont.Weight {
        switch weight {
        case .ultraLight: .light
        case .thin: .regular
        case .light: .medium
        case .regular: .semibold
        case .medium, .semibold: .bold
        case .bold: .heavy
        default: .black
        }
    }
}
