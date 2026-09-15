import UIKit

/// Text button (shadcn `Button`). Variants map to semantic tokens; sizes to
/// minimum heights that grow with Dynamic Type. Frame-based layout;
/// `sizeThatFits` returns the exact natural size on the pixel grid. At
/// accessibility text sizes a title wraps to up to three lines when the
/// proposed width is too narrow (the height grows); otherwise it stays on one
/// line and truncates.
///
/// Disabled filled variants (primary, accent, destructive) switch to a quiet
/// sunken fill with a tertiary label that stays readable (≥ 4.5:1); other
/// variants fade to 45 %.
///
/// Press feedback runs on a dedicated body view (the control's own frame and
/// transform stay untouched for layout): a spring to 0.97, an opaque on-color
/// overlay that moves the fill toward the canvas, and a lowered shadow. All of
/// it is interruptible; under Reduce Motion only the overlay fades.
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

        /// Variants whose label sits on a saturated fill.
        var isFilled: Bool {
            switch self {
            case .primary, .accent, .destructive: true
            case .secondary, .ghost, .destructiveSoft: false
            }
        }
    }

    /// Most lines a title wraps to at accessibility text sizes.
    static let maximumTitleLines = 3

    enum Size: Sendable {
        /// 36 pt, subheadline label.
        case small
        /// 44 pt, callout label.
        case medium
        /// 52 pt, body label.
        case large

        /// Minimum height; Dynamic Type can make the button taller.
        var height: CGFloat {
            switch self {
            case .small: 36
            case .medium: 44
            case .large: 52
            }
        }
    }

    enum IconPlacement: Sendable { case leading, trailing }

    var title: String? {
        didSet {
            guard title != oldValue else { return }
            titleLabel.text = title
            contentDidChange()
        }
    }

    var icon: RCIconGlyph? {
        didSet {
            guard icon != oldValue else { return }
            iconView.glyph = icon
            applyLoadingState(animated: false)
            contentDidChange()
        }
    }

    /// Leading/trailing follow the layout direction (mirrored in RTL).
    var iconPlacement: IconPlacement = .leading { didSet { if iconPlacement != oldValue { contentDidChange() } } }
    var variant: Variant {
        didSet {
            guard variant != oldValue else { return }
            applyEnabledState(animated: false)
        }
    }

    var size: Size {
        didSet {
            guard size != oldValue else { return }
            updateTypography()
            contentDidChange()
        }
    }

    /// Replaces the icon with a spinner (or the title, for text-only buttons)
    /// and blocks interaction; the width is kept. Animated while on screen.
    var isLoading = false {
        didSet {
            guard isLoading != oldValue else { return }
            applyLoadingState(animated: window != nil && !suppressesLoadingAnimation)
        }
    }

    /// Called on tap (touch up inside, or the control's primary action).
    var onTap: (() -> Void)?
    /// Haptic prepared on touch-down and played on tap; nil for none.
    var haptic: RCHaptics.Kind? = .light

    private let body = UIView()
    private let pressOverlay = UIView()
    private let titleLabel = RCLabel(style: .bodyStrong)
    private let iconView = RCIconView(pointSize: 18)
    private let spinner = RCSpinner(diameter: 16, lineWidth: 2)
    private var shadowSize: CGSize = .zero
    private var shadowRadius: CGFloat = 0
    private var lastActionTimestamp: TimeInterval = -1
    private var suppressesLoadingAnimation = false

    init(title: String? = nil, icon: RCIconGlyph? = nil, variant: Variant = .primary, size: Size = .large) {
        self.variant = variant
        self.size = size
        super.init(frame: .zero)
        self.title = title
        self.icon = icon
        titleLabel.text = title
        iconView.glyph = icon
        updateTypography()
        updateAppearance()
        applyLoadingState(animated: false)
    }

    override func setUp() {
        isAccessibilityElement = true
        accessibilityTraits = .button
        body.isUserInteractionEnabled = false
        pressOverlay.isUserInteractionEnabled = false
        pressOverlay.alpha = 0
        body.addSubview(pressOverlay)
        titleLabel.isAccessibilityElement = false
        titleLabel.textAlignment = .center
        body.addSubview(titleLabel)
        body.addSubview(iconView)
        spinner.hidesWhenStopped = true
        spinner.alpha = 0
        body.addSubview(spinner)
        addSubview(body)
        addTarget(self, action: #selector(handleAction(_:event:)), for: [.touchUpInside, .primaryActionTriggered])
        if #available(iOS 13.4, *) {
            addInteraction(UIPointerInteraction(delegate: self))
        }
    }

    private func contentDidChange() {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    // MARK: Accessibility

    override var accessibilityLabel: String? {
        get { super.accessibilityLabel ?? title }
        set { super.accessibilityLabel = newValue }
    }

    override var accessibilityValue: String? {
        get { isLoading ? "In progress" : super.accessibilityValue }
        set { super.accessibilityValue = newValue }
    }

    override var accessibilityTraits: UIAccessibilityTraits {
        get {
            var traits = super.accessibilityTraits.union(.button)
            if !isEnabled || isLoading { traits.insert(.notEnabled) }
            return traits
        }
        set { super.accessibilityTraits = newValue }
    }

    override var accessibilityUserInputLabels: [String]! {
        get { super.accessibilityUserInputLabels ?? title.map { [$0] } }
        set { super.accessibilityUserInputLabels = newValue }
    }

    // MARK: State

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            applyPressed(isHighlighted && isEnabled && !isLoading)
        }
    }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            applyEnabledState(animated: window != nil)
        }
    }

    /// Swaps to (or from) the disabled palette. Filled variants crossfade to a
    /// readable sunken look at full opacity; the others fade to 45 %.
    private func applyEnabledState(animated: Bool) {
        let alpha: CGFloat = isEnabled || variant.isFilled ? 1 : 0.45
        guard animated else {
            updateAppearance()
            body.alpha = alpha
            updateRasterization()
            return
        }
        let layer = body.layer
        let current = layer.presentation() ?? layer
        let from: [(String, Any?)] = [
            ("backgroundColor", current.backgroundColor),
            ("borderColor", current.borderColor),
            ("shadowOpacity", current.shadowOpacity),
        ]
        let fade = CATransition()
        fade.type = .fade
        fade.duration = RCMotion.quickDuration
        titleLabel.layer.add(fade, forKey: "rc.crossfade")
        iconView.layer.add(fade, forKey: "rc.crossfade")
        updateAppearance()
        for (keyPath, value) in from {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = value
            animation.toValue = layer.value(forKeyPath: keyPath)
            animation.duration = RCMotion.quickDuration
            animation.timingFunction = RCMotion.easeOut
            layer.add(animation, forKey: "rc.enabled.\(keyPath)")
        }
        RCMotion.animate(duration: RCMotion.quickDuration) { self.body.alpha = alpha }
        updateRasterization()
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        if let haptic, !isLoading { RCHaptics.prepare(haptic) }
        return super.beginTracking(touch, with: event)
    }

    @objc private func handleAction(_ sender: Any?, event: UIEvent?) {
        // Touch up and the primary action can both fire for one tap.
        if let event {
            guard event.timestamp != lastActionTimestamp else { return }
            lastActionTimestamp = event.timestamp
        }
        guard isEnabled, !isLoading else { return }
        if let haptic { RCHaptics.play(haptic) }
        onTap?()
    }

    /// Sets `isLoading`, choosing whether the swap animates.
    func setLoading(_ loading: Bool, animated: Bool) {
        suppressesLoadingAnimation = !animated
        isLoading = loading
        suppressesLoadingAnimation = false
    }

    // MARK: Appearance

    private struct Palette {
        let fill: UIColor?
        let border: UIColor?
        let foreground: UIColor
        /// Opaque press overlay (already carries its alpha).
        let press: UIColor
        let hasShadow: Bool
    }

    private var palette: Palette {
        if !isEnabled, variant.isFilled {
            // A faded saturated fill reads as an empty bar with an unreadable label.
            return Palette(fill: RCColor.surfaceSunken, border: RCColor.line, foreground: RCColor.textTertiary, press: RCColor.pressWash, hasShadow: false)
        }
        switch variant {
        case .primary:
            return Palette(fill: RCColor.text, border: nil, foreground: RCColor.onPrimary, press: Self.overlay(RCColor.onPrimary), hasShadow: true)
        case .accent:
            return Palette(fill: RCColor.accent, border: nil, foreground: RCColor.onAccent, press: Self.overlay(RCColor.onAccent), hasShadow: true)
        case .secondary:
            return Palette(fill: RCColor.elevated, border: RCColor.lineStrong, foreground: RCColor.text, press: RCColor.pressWash, hasShadow: false)
        case .ghost:
            return Palette(fill: nil, border: nil, foreground: RCColor.text, press: RCColor.pressWash, hasShadow: false)
        case .destructive:
            return Palette(fill: RCColor.danger, border: nil, foreground: RCColor.onDanger, press: Self.overlay(RCColor.onDanger), hasShadow: false)
        case .destructiveSoft:
            return Palette(fill: RCColor.dangerSoft, border: nil, foreground: RCColor.dangerText, press: Self.overlay(RCColor.danger, alpha: 0.1), hasShadow: false)
        }
    }

    /// On-color state layer: moves a filled control toward the canvas.
    private static func overlay(_ color: UIColor, alpha: CGFloat = 0.14) -> UIColor {
        UIColor { color.resolvedColor(with: $0).withAlphaComponent(alpha) }
    }

    override func updateTypography() {
        let metrics = metrics
        titleLabel.style = metrics.textStyle
        titleLabel.numberOfLines = metrics.wrapsTitle ? Self.maximumTitleLines : 1
        iconView.pointSize = metrics.iconSize
        iconView.strokeWidth = metrics.iconSize < 18 ? 2.25 : 2
        spinner.diameter = (metrics.iconSize * 0.86).rounded()
        spinner.lineWidth = metrics.iconSize < 18 ? 1.75 : 2
        shadowSize = .zero
    }

    override func updateAppearance() {
        let palette = palette
        withoutImplicitAnimations {
            body.layer.backgroundColor = palette.fill?.cgColor(for: self)
            body.layer.borderColor = palette.border?.cgColor(for: self)
            body.layer.borderWidth = palette.border == nil ? 0 : 1
            pressOverlay.layer.backgroundColor = palette.press.cgColor(for: self)
            if palette.hasShadow {
                body.layer.shadowColor = RCColor.shadow.cgColor(for: self)
                body.layer.shadowOpacity = restingShadowOpacity
                body.layer.shadowRadius = RCShadow.button.radius
                body.layer.shadowOffset = RCShadow.button.offset
            } else {
                RCShadow.clear(body.layer)
            }
        }
        shadowSize = .zero
        titleLabel.color = palette.foreground
        iconView.tintColor = palette.foreground
        spinner.tintColor = palette.foreground
        setNeedsLayout()
        updateRasterization()
    }

    private var restingShadowOpacity: Float {
        traitCollection.userInterfaceStyle == .dark ? RCShadow.button.opacityDark : RCShadow.button.opacityLight
    }

    // MARK: Press

    private func applyPressed(_ pressed: Bool) {
        let reduceMotion = RCMotion.reduceMotion
        RCMotion.animate(pressed ? RCMotion.snappy : RCMotion.bouncy) {
            self.body.transform = pressed && !reduceMotion ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
        }
        let duration = pressed ? RCMotion.pressDuration : RCMotion.releaseDuration
        RCMotion.animate(duration: duration) { self.pressOverlay.alpha = pressed ? 1 : 0 }
        guard palette.hasShadow else { return }
        let resting = restingShadowOpacity
        RCLayerAnimation.set(body.layer, "shadowOpacity", to: pressed ? resting * 0.55 : resting, duration: duration)
        RCLayerAnimation.set(body.layer, "shadowRadius", to: pressed ? RCShadow.button.radius * 0.6 : RCShadow.button.radius, duration: duration)
        let offset = RCShadow.button.offset
        RCLayerAnimation.set(body.layer, "shadowOffset", to: NSValue(cgSize: pressed ? CGSize(width: 0, height: offset.height / 2) : offset), duration: duration)
    }

    // MARK: Loading

    private func applyLoadingState(animated: Bool) {
        let loading = isLoading
        let hasIcon = icon != nil
        let hasTitle = title?.isEmpty == false
        if loading { spinner.startAnimating() }
        let animate = animated && window != nil
        let reduceMotion = RCMotion.reduceMotion
        let shrunk = CGAffineTransform(scaleX: 0.6, y: 0.6)
        let changes: @MainActor () -> Void = {
            self.iconView.alpha = hasIcon && !loading ? 1 : 0
            self.spinner.alpha = loading ? 1 : 0
            self.titleLabel.alpha = loading && !hasIcon && hasTitle ? 0 : 1
            guard !reduceMotion || !animate else { return }
            self.iconView.transform = loading ? shrunk : .identity
            self.spinner.transform = loading ? .identity : shrunk
        }
        let finish: @MainActor (Bool) -> Void = { _ in
            if !self.isLoading { self.spinner.stopAnimating() }
        }
        if animate {
            if loading, !reduceMotion { spinner.transform = shrunk }
            RCMotion.animate(RCMotion.snappy, animations: changes, completion: finish)
        } else {
            UIView.performWithoutAnimation { changes() }
            finish(true)
        }
        if loading, isHighlighted { applyPressed(false) }
        setNeedsLayout()
        updateRasterization()
    }

    /// A faded disabled button is static: flatten it once instead of compositing
    /// the 45% group opacity offscreen on every frame it moves (e.g. scrolling).
    /// Disabled filled variants stay opaque and need no flattening.
    private func updateRasterization() {
        let rasterize = !isEnabled && !isLoading && !variant.isFilled
        body.layer.shouldRasterize = rasterize
        if rasterize { body.layer.rasterizationScale = window?.screen.scale ?? UIScreen.main.scale }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRasterization()
    }

#if DEBUG
    /// Resolved fill, label color and body opacity (tests).
    var appearanceForTesting: (fill: UIColor?, label: UIColor, bodyAlpha: CGFloat, titleLines: Int) {
        (palette.fill?.resolved(for: self), palette.foreground.resolved(for: self), body.alpha, titleLabel.numberOfLines)
    }
#endif

    // MARK: Layout

    private struct Metrics {
        let textStyle: RCTextStyle
        let minimumHeight: CGFloat
        let verticalPadding: CGFloat
        let horizontalPadding: CGFloat
        let iconSize: CGFloat
        let gap: CGFloat
        let cornerRadius: CGFloat
        let lineHeight: CGFloat
        /// Accessibility text sizes: titles may wrap instead of truncating.
        let wrapsTitle: Bool
    }

    private var metrics: Metrics {
        let style: RCTextStyle
        let base: (vertical: CGFloat, horizontal: CGFloat, icon: CGFloat, gap: CGFloat, radius: CGFloat)
        switch size {
        case .small:
            style = .subheadlineStrong
            base = (8, 14, 16, 6, RCRadius.sm + 2)
        case .medium:
            style = .calloutStrong
            base = (10, 18, 18, 8, RCRadius.md)
        case .large:
            style = .bodyStrong
            base = (12, 22, 20, 8, RCRadius.md)
        }
        let scale = min(RCTypography.scale(for: style, compatibleWith: traitCollection), 1.5)
        return Metrics(
            textStyle: style,
            minimumHeight: size.height,
            verticalPadding: base.vertical,
            horizontalPadding: base.horizontal,
            iconSize: (base.icon * scale).rounded(),
            gap: (base.gap * min(scale, 1.25)).rounded(),
            cornerRadius: base.radius,
            lineHeight: RCTypography.lineHeight(style, compatibleWith: traitCollection),
            wrapsTitle: traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        )
    }

    private var hasTitle: Bool { title?.isEmpty == false }

    /// Horizontal padding on the icon side is 2 pt tighter: a glyph's ink sits
    /// inside its box, so equal padding reads as lopsided.
    private func paddings(_ metrics: Metrics, height: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        guard hasTitle else {
            let side = max(metrics.horizontalPadding / 2, (height - metrics.iconSize) / 2)
            return (side, side)
        }
        guard icon != nil else { return (metrics.horizontalPadding, metrics.horizontalPadding) }
        let tight = metrics.horizontalPadding - 2
        return iconPlacement == .leading ? (tight, metrics.horizontalPadding) : (metrics.horizontalPadding, tight)
    }

    override var intrinsicContentSize: CGSize {
        sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let metrics = metrics
        let singleLineHeight = RCPixelSnap.ceil(max(metrics.minimumHeight, metrics.lineHeight + metrics.verticalPadding * 2))
        let pads = paddings(metrics, height: singleLineHeight)
        let glyph: CGFloat = icon != nil || !hasTitle ? metrics.iconSize : 0
        let gap: CGFloat = icon != nil && hasTitle ? metrics.gap : 0
        let naturalTitle = hasTitle ? singleLineTitleWidth(metrics) : 0
        let wrapped = wrappedTitle(metrics, naturalWidth: naturalTitle, available: size.width - pads.leading - pads.trailing - glyph - gap)
        let titleWidth = wrapped?.width ?? naturalTitle
        let height = wrapped.map { RCPixelSnap.ceil(max(metrics.minimumHeight, $0.height + metrics.verticalPadding * 2)) } ?? singleLineHeight
        let width = RCPixelSnap.ceil(pads.leading + glyph + gap + titleWidth + pads.trailing)
        return CGSize(width: max(width, hasTitle ? 0 : height), height: height)
    }

    private func singleLineTitleWidth(_ metrics: Metrics) -> CGFloat {
        titleLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: metrics.lineHeight)).width
    }

    /// Wrapped title size when the title may wrap and does not fit `available`
    /// on one line; nil keeps the single-line layout.
    private func wrappedTitle(_ metrics: Metrics, naturalWidth: CGFloat, available: CGFloat) -> CGSize? {
        guard metrics.wrapsTitle, hasTitle, available > 0, available < .greatestFiniteMagnitude / 2, naturalWidth > available else { return nil }
        let fitted = titleLabel.sizeThatFits(CGSize(width: available, height: CGFloat.greatestFiniteMagnitude))
        let lines = CGFloat(Self.maximumTitleLines)
        return CGSize(width: min(available, RCPixelSnap.ceil(fitted.width)), height: min(RCPixelSnap.ceil(fitted.height), metrics.lineHeight * lines))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let metrics = metrics
        // bounds + center keep the body's press transform out of the geometry.
        body.bounds = CGRect(origin: .zero, size: bounds.size)
        body.center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(metrics.cornerRadius, bounds.height / 2)
        withoutImplicitAnimations {
            body.layer.cornerRadius = radius
            body.layer.cornerCurve = .continuous
            pressOverlay.layer.cornerRadius = radius
            pressOverlay.layer.cornerCurve = .continuous
        }
        pressOverlay.frame = body.bounds
        updateShadowPath(radius: radius)

        let size = bounds.size
        let pads = paddings(metrics, height: size.height)
        let showsGlyphSlot = icon != nil
        let glyph = showsGlyphSlot ? metrics.iconSize : 0
        let gap = showsGlyphSlot && hasTitle ? metrics.gap : 0
        let available = max(0, size.width - pads.leading - pads.trailing)
        let naturalTitle = hasTitle ? singleLineTitleWidth(metrics) : 0
        let wrapped = wrappedTitle(metrics, naturalWidth: naturalTitle, available: available - glyph - gap)
        let titleWidth = wrapped?.width ?? max(0, min(naturalTitle, available - glyph - gap))
        // A frame shorter than the wrapped text keeps the lines that fit (the last one truncates).
        let titleHeight = min(wrapped?.height ?? metrics.lineHeight, max(metrics.lineHeight, size.height))
        let contentWidth = glyph + gap + titleWidth
        // Center the content in the padded box so tuned paddings shift it optically.
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let glyphFirst = (iconPlacement == .leading) != rtl
        let x = (rtl ? pads.trailing : pads.leading) + (available - contentWidth) / 2

        let midY = size.height / 2
        var glyphFrame = CGRect(x: 0, y: midY - metrics.iconSize / 2, width: metrics.iconSize, height: metrics.iconSize)
        var titleFrame = CGRect(x: 0, y: midY - titleHeight / 2, width: titleWidth, height: titleHeight)
        if glyphFirst {
            glyphFrame.origin.x = x
            titleFrame.origin.x = x + glyph + gap
        } else {
            titleFrame.origin.x = x
            glyphFrame.origin.x = x + titleWidth + gap
        }
        titleLabel.frame = RCLayout.pixelAligned(titleFrame)
        if showsGlyphSlot {
            // bounds + center: the icon carries a scale transform while loading.
            let aligned = RCLayout.pixelAligned(glyphFrame)
            iconView.bounds = CGRect(origin: .zero, size: aligned.size)
            iconView.center = CGPoint(x: aligned.midX, y: aligned.midY)
        }
        let spinnerCenter = showsGlyphSlot
            ? CGPoint(x: glyphFrame.midX, y: glyphFrame.midY)
            : CGPoint(x: size.width / 2, y: midY)
        let spinnerSide = spinner.diameter
        spinner.bounds = CGRect(x: 0, y: 0, width: spinnerSide, height: spinnerSide)
        spinner.center = CGPoint(x: RCLayout.pixelAligned(spinnerCenter.x), y: RCLayout.pixelAligned(spinnerCenter.y))
    }

    private func updateShadowPath(radius: CGFloat) {
        guard palette.hasShadow else { return }
        let size = body.bounds.size
        guard size != shadowSize || radius != shadowRadius, size.width > 0 else { return }
        let oldPath = body.layer.shadowPath
        let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius).cgPath
        withoutImplicitAnimations { body.layer.shadowPath = path }
        if shadowSize != .zero, let oldPath {
            RCLayerAnimation.follow(boundsAnimationOf: body.layer, on: body.layer, keyPath: "shadowPath", from: oldPath, to: path)
        }
        shadowSize = size
        shadowRadius = radius
    }
}

@available(iOS 13.4, *)
extension RCButton: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard isEnabled, !isLoading else { return nil }
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: body.bounds, cornerRadius: body.layer.cornerRadius)
        let preview = UITargetedPreview(view: body, parameters: parameters)
        return UIPointerStyle(effect: .highlight(preview))
    }
}
