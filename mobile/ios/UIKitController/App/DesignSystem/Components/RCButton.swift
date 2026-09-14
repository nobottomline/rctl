import UIKit

/// Text button (shadcn `Button`). Variants map to semantic tokens; sizes to
/// fixed heights. Frame-based layout; `sizeThatFits` returns the natural size.
@MainActor
final class RCButton: RCControl {
    enum Variant: Sendable {
        /// Filled with `text` color (ink on warm, near-white on console).
        case primary
        /// Filled terracotta / amber — the single most important action.
        case accent
        /// Elevated surface with a strong border.
        case secondary
        /// No chrome; wash on press.
        case ghost
        /// Filled danger.
        case destructive
        /// Danger text on a soft danger wash.
        case destructiveSoft
    }

    enum Size: Sendable {
        /// 36 pt, subheadline label.
        case small
        /// 44 pt, callout label.
        case medium
        /// 52 pt, body label.
        case large

        var height: CGFloat {
            switch self {
            case .small: 36
            case .medium: 44
            case .large: 52
            }
        }
    }

    enum IconPlacement: Sendable { case leading, trailing }

    var title: String? { didSet { titleLabel.text = title; invalidateIntrinsicContentSize(); setNeedsLayout() } }
    var icon: RCIconGlyph? { didSet { iconView.glyph = icon; iconView.isHidden = icon == nil || isLoading; invalidateIntrinsicContentSize(); setNeedsLayout() } }
    var iconPlacement: IconPlacement = .leading { didSet { setNeedsLayout() } }
    var variant: Variant { didSet { updateAppearance() } }
    var size: Size { didSet { updateTypography(); invalidateIntrinsicContentSize(); setNeedsLayout() } }
    /// Replaces the icon with a spinner and blocks interaction; width is kept.
    var isLoading = false { didSet { updateLoading() } }
    /// Called on `.primaryActionTriggered` (touch up inside).
    var onTap: (() -> Void)?
    /// Haptic played on tap; nil for none.
    var haptic: RCHaptics.Kind? = .light

    private let titleLabel = RCLabel(style: .bodyStrong)
    private let iconView = RCIconView(pointSize: 18)
    private let spinner = RCSpinner(diameter: 18, lineWidth: 2)
    private let backgroundLayer = CALayer()

    init(title: String? = nil, icon: RCIconGlyph? = nil, variant: Variant = .primary, size: Size = .large) {
        self.variant = variant
        self.size = size
        super.init(frame: .zero)
        self.title = title
        self.icon = icon
        titleLabel.text = title
        iconView.glyph = icon
        iconView.isHidden = icon == nil
        updateTypography()
        updateAppearance()
    }

    override func setUp() {
        isAccessibilityElement = true
        accessibilityTraits = .button
        layer.addSublayer(backgroundLayer)
        titleLabel.isUserInteractionEnabled = false
        addSubview(titleLabel)
        addSubview(iconView)
        spinner.isHidden = true
        addSubview(spinner)
        addTarget(self, action: #selector(handleTap), for: .primaryActionTriggered)
    }

    override var accessibilityLabel: String? {
        get { super.accessibilityLabel ?? title }
        set { super.accessibilityLabel = newValue }
    }

    override var isHighlighted: Bool {
        didSet { guard isHighlighted != oldValue else { return }; animatePress() }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.45 }
    }

    override func updateTypography() {
        switch size {
        case .small: titleLabel.style = .subheadlineStrong; iconView.pointSize = 16
        case .medium: titleLabel.style = .calloutStrong; iconView.pointSize = 18
        case .large: titleLabel.style = .bodyStrong; iconView.pointSize = 18
        }
    }

    override func updateAppearance() {
        let (fill, border, foreground) = colors
        withoutImplicitAnimations {
            backgroundLayer.backgroundColor = fill?.cgColor(for: self)
            backgroundLayer.borderColor = border?.cgColor(for: self)
            backgroundLayer.borderWidth = border == nil ? 0 : 1
        }
        titleLabel.color = foreground
        iconView.tintColor = foreground
        spinner.tintColor = foreground
    }

    private var colors: (UIColor?, UIColor?, UIColor) {
        switch variant {
        case .primary: (RCColor.text, nil, RCColor.onPrimary)
        case .accent: (RCColor.accent, nil, RCColor.onAccent)
        case .secondary: (RCColor.elevated, RCColor.lineStrong, RCColor.text)
        case .ghost: (nil, nil, RCColor.text)
        case .destructive: (RCColor.danger, nil, RCColor.onDanger)
        case .destructiveSoft: (RCColor.dangerSoft, nil, RCColor.danger)
        }
    }

    override var intrinsicContentSize: CGSize {
        sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: size.height))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let labelWidth = titleLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: self.size.height)).width
        let iconWidth = icon == nil && !isLoading ? 0 : iconView.pointSize + (title == nil ? 0 : RCSpace.sm)
        let horizontalPadding: CGFloat = self.size == .small ? 14 : 20
        return CGSize(width: ceil(labelWidth + iconWidth + horizontalPadding * 2), height: self.size.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitAnimations {
            backgroundLayer.frame = bounds
            backgroundLayer.cornerRadius = size == .small ? RCRadius.sm + 2 : RCRadius.md
            backgroundLayer.cornerCurve = .continuous
        }
        let showsGlyph = icon != nil || isLoading
        let glyphSide = iconView.pointSize
        let labelSize = titleLabel.sizeThatFits(CGSize(width: bounds.width, height: bounds.height))
        let spacing = showsGlyph && title != nil ? RCSpace.sm : 0
        let contentWidth = min(bounds.width - 16, labelSize.width + (showsGlyph ? glyphSide + spacing : 0))
        var x = (bounds.width - contentWidth) / 2
        let glyphFrame: CGRect
        if iconPlacement == .leading {
            glyphFrame = CGRect(x: x, y: (bounds.height - glyphSide) / 2, width: showsGlyph ? glyphSide : 0, height: glyphSide)
            x += showsGlyph ? glyphSide + spacing : 0
            titleLabel.frame = CGRect(x: x, y: (bounds.height - labelSize.height) / 2, width: contentWidth - (showsGlyph ? glyphSide + spacing : 0), height: labelSize.height)
        } else {
            let labelWidth = contentWidth - (showsGlyph ? glyphSide + spacing : 0)
            titleLabel.frame = CGRect(x: x, y: (bounds.height - labelSize.height) / 2, width: labelWidth, height: labelSize.height)
            glyphFrame = CGRect(x: x + labelWidth + spacing, y: (bounds.height - glyphSide) / 2, width: showsGlyph ? glyphSide : 0, height: glyphSide)
        }
        iconView.frame = RCLayout.pixelAligned(glyphFrame)
        spinner.frame = RCLayout.pixelAligned(glyphFrame)
    }

    private func updateLoading() {
        isUserInteractionEnabled = !isLoading
        iconView.isHidden = icon == nil || isLoading
        spinner.isHidden = !isLoading
        if isLoading { spinner.startAnimating() } else { spinner.stopAnimating() }
        accessibilityTraits = isLoading ? [.button, .notEnabled] : .button
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func animatePress() {
        let highlighted = isHighlighted
        if highlighted, let haptic { RCHaptics.prepare(haptic) }
        RCMotion.animate(duration: highlighted ? RCMotion.pressDuration : RCMotion.releaseDuration) {
            self.transform = highlighted && !RCMotion.reduceMotion ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
            self.backgroundLayer.opacity = highlighted ? 0.86 : 1
        }
    }

    @objc private func handleTap() {
        if let haptic { RCHaptics.play(haptic) }
        onTap?()
    }
}
