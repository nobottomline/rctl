import UIKit

/// Label bound to a type style. Applies tracking, line height and Dynamic Type
/// through attributed text, rebuilt only when text, style, color, or content
/// size category actually change (UILabel re-lays out on every assignment).
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

    init(_ text: String? = nil, style: RCTextStyle = .body, color: UIColor = RCColor.text, lines: Int = 1, alignment: NSTextAlignment = .natural) {
        self.style = style
        self.color = color
        super.init(frame: .zero)
        numberOfLines = lines
        textAlignment = alignment
        lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
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

    override var textAlignment: NSTextAlignment {
        didSet { if textAlignment != oldValue { rebuild() } }
    }

    override var lineBreakMode: NSLineBreakMode {
        didSet { if lineBreakMode != oldValue { rebuild() } }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory {
            rebuild()
        }
    }

    private func rebuild() {
        guard let storedText, !storedText.isEmpty else {
            super.attributedText = nil
            return
        }
        let value = style.spec.uppercase ? storedText.uppercased() : storedText
        super.attributedText = NSAttributedString(
            string: value,
            attributes: RCTypography.attributes(
                style,
                color: color,
                alignment: textAlignment,
                lineBreakMode: lineBreakMode,
                compatibleWith: traitCollection,
                monospacedDigits: usesMonospacedDigits
            )
        )
        invalidateIntrinsicContentSize()
    }
}
