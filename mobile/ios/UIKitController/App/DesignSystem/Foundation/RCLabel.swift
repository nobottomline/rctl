import UIKit

/// Label bound to a type style. Applies tracking, line height and Dynamic Type
/// through attributed text, rebuilt only when text, style, color, alignment,
/// line breaking, content size category or Bold Text actually change (UILabel
/// re-lays out on every assignment).
///
/// Metrics: a single line is exactly `RCTypography.lineHeight(style)` tall
/// with glyphs where a plain `UILabel` of the font's natural height would put
/// them, so labels of different styles center and baseline-align predictably.
/// Multi-line labels (`lines: 0`) wrap; a fixed line count (`lines: 2`)
/// truncates the last line with an ellipsis.
@MainActor
final class RCLabel: UILabel {
    var style: RCTextStyle {
        didSet { if style != oldValue { rebuild() } }
    }

    /// Dynamic color token; resolved automatically by UIKit for attributed text.
    var color: UIColor {
        didSet { if color != oldValue { rebuild() } }
    }

    var usesMonospacedDigits = false {
        didSet { if usesMonospacedDigits != oldValue { rebuild() } }
    }

    private var storedText: String?
    /// Set while assigning `super.attributedText`, which can echo paragraph
    /// attributes back through the overridden setters below.
    private var isApplying = false
    /// Font the current attributed string was built with (fonts are cached by
    /// `RCTypography`, so identity tells whether traits changed anything).
    private var builtFont: UIFont?
    private var customAccessibilityLabel: String?

#if DEBUG
    /// Number of attributed-string builds; lets tests prove updates are not redundant.
    private(set) var rebuildCount = 0
#endif

    init(_ text: String? = nil, style: RCTextStyle = .body, color: UIColor = RCColor.text, lines: Int = 1, alignment: NSTextAlignment = .natural) {
        self.style = style
        self.color = color
        super.init(frame: .zero)
        isApplying = true
        numberOfLines = lines
        textAlignment = alignment
        lineBreakMode = lines == 0 ? .byWordWrapping : .byTruncatingTail
        isApplying = false
        storedText = text
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var text: String? {
        get { storedText }
        set {
            guard newValue != storedText else { return }
            storedText = newValue
            rebuild()
        }
    }

    /// The source text, not the uppercased rendering, so VoiceOver reads
    /// overlines as words rather than spelling them out.
    override var accessibilityLabel: String? {
        get { customAccessibilityLabel ?? storedText }
        set { customAccessibilityLabel = newValue }
    }

    override var textAlignment: NSTextAlignment {
        didSet { if textAlignment != oldValue, !isApplying { rebuild() } }
    }

    override var lineBreakMode: NSLineBreakMode {
        didSet { if lineBreakMode != oldValue, !isApplying { rebuild() } }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard storedText?.isEmpty == false else { return }
        if RCTypography.font(style, compatibleWith: traitCollection, monospacedDigits: usesMonospacedDigits) !== builtFont {
            rebuild()
        }
    }

    private func rebuild() {
        guard let storedText, !storedText.isEmpty else {
            if super.attributedText != nil {
                applyAttributedText(nil)
            }
            return
        }
#if DEBUG
        rebuildCount += 1
#endif
        builtFont = RCTypography.font(style, compatibleWith: traitCollection, monospacedDigits: usesMonospacedDigits)
        applyAttributedText(RCTypography.attributedString(
            storedText,
            style: style,
            color: color,
            alignment: textAlignment,
            lineBreakMode: lineBreakMode,
            compatibleWith: traitCollection,
            monospacedDigits: usesMonospacedDigits
        ))
    }

    private func applyAttributedText(_ value: NSAttributedString?) {
        isApplying = true
        super.attributedText = value
        isApplying = false
        invalidateIntrinsicContentSize()
    }
}
