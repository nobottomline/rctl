import UIKit

/// Labeled text input (shadcn `Input` + `Label` + form message).
///
/// A caption sits above the value inside the field; focus draws an accent
/// border and a 3 pt ring that grows out of the border (opacity/scale on the
/// render server, never layout); an error switches both to danger. Helper
/// text or the error message render below the field and are included in
/// `sizeThatFits`. Tapping anywhere on the field focuses it.
///
/// Configure keyboard traits on `textField` directly, but keep this view as
/// its delegate. Moving the content above the keyboard is the screen's job.
@MainActor
final class RCTextField: RCView, UITextFieldDelegate, UIGestureRecognizerDelegate {
    let textField = UITextField()
    var label: String { didSet { captionLabel.text = label; updateAccessibility() } }
    var placeholder: String? { didSet { updatePlaceholder() } }
    var icon: RCIconGlyph? { didSet { iconView.glyph = icon; iconView.isHidden = icon == nil; setNeedsLayout() } }
    /// SF Mono input text (addresses).
    var isMonospaced = false { didSet { guard isMonospaced != oldValue else { return }; updateTypography() } }
    /// Non-nil shows the danger border and ring. The message renders below the
    /// field in place of `helperText` unless `displaysErrorMessage` is false
    /// (for forms that present the error elsewhere, e.g. in an `RCCallout`).
    var errorMessage: String? {
        didSet {
            guard errorMessage != oldValue else { return }
            applyState(animated: window != nil)
            updateMessage(animated: window != nil)
            updateAccessibility()
            if let errorMessage, window != nil, UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: errorMessage)
            }
        }
    }
    /// Quiet guidance below the field (e.g. "Port 8080 is used when none is given.").
    var helperText: String? {
        didSet {
            guard helperText != oldValue else { return }
            updateMessage(animated: window != nil)
            updateAccessibility()
        }
    }
    /// Whether `errorMessage` text is rendered below the field (default true).
    var displaysErrorMessage = true {
        didSet {
            guard displaysErrorMessage != oldValue else { return }
            updateMessage(animated: false)
        }
    }
    var text: String {
        get { textField.text ?? "" }
        set {
            textField.text = newValue
            updateClearButton(animated: false)
        }
    }
    /// Called on every user edit (typing, paste, dictation, clear button); not for `text` assignments.
    var onChange: ((String) -> Void)?
    /// Return key handler. Return `true` to resign first responder.
    var onReturn: (() -> Bool)?

    var isEnabled: Bool {
        get { textField.isEnabled }
        set {
            guard newValue != textField.isEnabled else { return }
            textField.isEnabled = newValue
            if !newValue, textField.isFirstResponder { textField.resignFirstResponder() }
            alpha = newValue ? 1 : 0.5
            applyState(animated: false)
            updateClearButton(animated: false)
        }
    }

    /// Forwarded to `textField`. Stored here because UIKit resolves the text
    /// field's accessory through the responder chain, which reaches this view.
    override var inputAccessoryView: UIView? {
        get { storedInputAccessoryView }
        set {
            storedInputAccessoryView = newValue
            textField.inputAccessoryView = newValue
        }
    }
    private var storedInputAccessoryView: UIView?

    static let boxPadding = UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
    static let ringWidth: CGFloat = 3
    static let messageSpacing: CGFloat = 6
    private static let baseIconSide: CGFloat = 18
    private static let baseMessageIconSide: CGFloat = 14
    /// Icons grow with Dynamic Type, less than text so they stay quiet.
    private static let maximumIconScale: CGFloat = 1.4
    private static let clearButtonSide: CGFloat = 28

    private let boxLayer = CALayer()
    private let ringLayer = CALayer()
    private let captionLabel = RCLabel(style: .caption, color: RCColor.textTertiary)
    private let iconView = RCIconView(pointSize: 18)
    private let clearButton = ClearTextButton()
    private let messageLabel = RCLabel(style: .footnote, color: RCColor.textTertiary, lines: 0)
    private let messageIcon = RCIconView(.circleAlert, pointSize: 14)
    private var isClearButtonShown = false

    init(label: String, placeholder: String? = nil, icon: RCIconGlyph? = nil) {
        self.label = label
        self.placeholder = placeholder
        self.icon = icon
        super.init(frame: .zero)
        captionLabel.text = label
        iconView.glyph = icon
        iconView.isHidden = icon == nil
        updatePlaceholder()
        updateAccessibility()
    }

    override func setUp() {
        layer.addSublayer(ringLayer)
        layer.addSublayer(boxLayer)
        ringLayer.opacity = 0
        boxLayer.borderWidth = 1
        ringLayer.borderWidth = Self.ringWidth
        captionLabel.isAccessibilityElement = false
        addSubview(captionLabel)
        addSubview(iconView)
        textField.delegate = self
        textField.borderStyle = .none
        textField.clearButtonMode = .never
        textField.adjustsFontForContentSizeCategory = false
        textField.addTarget(self, action: #selector(editingChanged), for: .editingChanged)
        textField.addTarget(self, action: #selector(focusChanged), for: [.editingDidBegin, .editingDidEnd])
        addSubview(textField)
        clearButton.alpha = 0
        clearButton.isUserInteractionEnabled = false
        clearButton.accessibilityElementsHidden = true
        clearButton.addTapAction { [weak self] in self?.clearText() }
        addSubview(clearButton)
        messageLabel.isAccessibilityElement = false
        messageIcon.isHidden = true
        addSubview(messageLabel)
        addSubview(messageIcon)
        let tap = UITapGestureRecognizer(target: self, action: #selector(focus))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        textField.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        textField.resignFirstResponder()
    }

    @objc private func focus() {
        guard isEnabled else { return }
        textField.becomeFirstResponder()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if let view = touch.view, view.isDescendant(of: textField) || view.isDescendant(of: clearButton) { return false }
        return boxFrame.contains(touch.location(in: self))
    }

    @objc private func editingChanged() {
        updateClearButton(animated: true)
        onChange?(text)
    }

    @objc private func focusChanged() {
        applyState(animated: true)
        updateClearButton(animated: true)
    }

    @objc private func clearText() {
        textField.text = ""
        // Same path as typing, so `onChange` and any `.editingChanged` targets run.
        textField.sendActions(for: .editingChanged)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let resign = onReturn?() ?? true
        if resign { textField.resignFirstResponder() }
        return false
    }

    /// Horizontal shake that draws attention to a rejected value; a ring pulse under Reduce Motion.
    func shake() {
        RCHaptics.play(.warning)
        if RCMotion.reduceMotion {
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [ringLayer.opacity, 1, 0.35, 1, ringLayer.opacity]
            pulse.duration = 0.4
            ringLayer.add(pulse, forKey: "rc.pulse")
            return
        }
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -8, 7, -5, 3, 0]
        animation.duration = 0.36
        animation.timingFunction = RCMotion.easeOut
        animation.isAdditive = true
        layer.add(animation, forKey: "rc.shake")
    }

    // MARK: Appearance

    private var iconScale: CGFloat {
        min(Self.maximumIconScale, RCTypography.scale(for: .body, compatibleWith: traitCollection))
    }
    private var iconSide: CGFloat { (Self.baseIconSide * iconScale).rounded() }
    private var messageIconSide: CGFloat { (Self.baseMessageIconSide * iconScale).rounded() }

    override func updateTypography() {
        iconView.pointSize = iconSide
        messageIcon.pointSize = messageIconSide
        let style: RCTextStyle = isMonospaced ? .mono : .body
        let font = RCTypography.font(style, compatibleWith: traitCollection)
        textField.defaultTextAttributes = [
            .font: font,
            .foregroundColor: RCColor.text,
            .kern: style.spec.tracking * (font.pointSize / style.spec.size),
        ]
        textField.font = font
        textField.textColor = RCColor.text
        updatePlaceholder()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func updateAppearance() {
        textField.textColor = RCColor.text
        textField.tintColor = RCColor.accent
        applyState(animated: false)
    }

    private func updatePlaceholder() {
        guard let placeholder else { textField.attributedPlaceholder = nil; return }
        textField.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: RCColor.textQuaternary,
            .font: RCTypography.font(isMonospaced ? .mono : .body, compatibleWith: traitCollection),
        ])
    }

    private func applyState(animated requested: Bool) {
        let animated = requested && window != nil
        let focused = textField.isFirstResponder
        let hasError = errorMessage != nil
        let border: UIColor = hasError ? RCColor.danger : (focused ? RCColor.accent : RCColor.lineStrong)
        let ringVisible = (hasError || focused) && isEnabled
        let iconTint: UIColor = hasError ? RCColor.danger : (focused ? RCColor.accent : RCColor.textTertiary)

        withoutImplicitAnimations {
            boxLayer.backgroundColor = RCColor.elevated.cgColor(for: self)
        }
        Self.transition(boxLayer, "borderColor", to: border.cgColor(for: self), animated: animated)
        let ringColor = (hasError ? RCColor.dangerSoft : RCColor.focusRing).cgColor(for: self)
        // A hidden ring takes its new color instantly; a visible one crossfades.
        Self.transition(ringLayer, "borderColor", to: ringColor, animated: animated && ringLayer.opacity > 0)
        Self.transition(ringLayer, "opacity", to: NSNumber(value: ringVisible ? 1 : 0), animated: animated, duration: ringVisible ? RCMotion.quickDuration : RCMotion.releaseDuration)
        let ringTransform = ringVisible || RCMotion.reduceMotion ? CATransform3DIdentity : collapsedRingTransform()
        Self.transition(ringLayer, "transform", to: NSValue(caTransform3D: ringTransform), animated: animated)

        let fromTint = iconView.layer.presentation()?.value(forKey: "strokeColor")
        iconView.tintColor = iconTint
        if animated, let fromTint {
            let fade = CABasicAnimation(keyPath: "strokeColor")
            fade.fromValue = fromTint
            fade.duration = RCMotion.quickDuration
            fade.timingFunction = RCMotion.easeOut
            iconView.layer.add(fade, forKey: "rc.tint")
        }
        // Error text sits on the page ground: the AA text token, not the border color.
        messageLabel.color = hasError && displaysErrorMessage ? RCColor.dangerText : RCColor.textTertiary
        messageIcon.tintColor = RCColor.dangerText
    }

    /// Ring scaled down onto the field border, the start of the focus animation.
    private func collapsedRingTransform() -> CATransform3D {
        let box = boxFrame
        guard box.width > 0, box.height > 0 else { return CATransform3DIdentity }
        let inset = Self.ringWidth * 2
        return CATransform3DMakeScale(box.width / (box.width + inset), box.height / (box.height + inset), 1)
    }

    private static func transition(_ layer: CALayer, _ keyPath: String, to value: Any, animated: Bool, duration: TimeInterval = RCMotion.quickDuration) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        withoutImplicitAnimations { layer.setValue(value, forKeyPath: keyPath) }
        guard animated else {
            layer.removeAnimation(forKey: keyPath)
            return
        }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = RCMotion.easeOut
        layer.add(animation, forKey: keyPath)
    }

    private var displayedMessage: (text: String, isError: Bool)? {
        if let errorMessage, displaysErrorMessage, !errorMessage.isEmpty { return (errorMessage, true) }
        if let helperText, !helperText.isEmpty { return (helperText, false) }
        return nil
    }

    private func updateMessage(animated: Bool) {
        let message = displayedMessage
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = RCMotion.quickDuration
            messageLabel.layer.add(fade, forKey: "rc.crossfade")
            messageIcon.layer.add(fade, forKey: "rc.crossfade")
        }
        let oldHeight = bounds.height
        messageLabel.text = message?.text
        messageLabel.color = message?.isError == true ? RCColor.dangerText : RCColor.textTertiary
        messageIcon.isHidden = message?.isError != true
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        if bounds.width > 0, abs(sizeThatFits(bounds.size).height - oldHeight) > 0.5 {
            superview?.setNeedsLayout()
        }
    }

    private func updateClearButton(animated: Bool) {
        let visible = textField.isEditing && isEnabled && !text.isEmpty
        guard visible != isClearButtonShown else { return }
        isClearButtonShown = visible
        clearButton.isUserInteractionEnabled = visible
        clearButton.accessibilityElementsHidden = !visible
        let changes: @MainActor () -> Void = {
            self.clearButton.alpha = visible ? 1 : 0
            if !RCMotion.reduceMotion {
                self.clearButton.transform = visible ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
            }
        }
        if animated, window != nil {
            RCMotion.animate(RCMotion.snappy, animations: changes)
        } else {
            changes()
        }
    }

    private func updateAccessibility() {
        isAccessibilityElement = false
        textField.accessibilityLabel = label
        if let errorMessage, !errorMessage.isEmpty {
            textField.accessibilityHint = "Error: " + errorMessage
        } else {
            textField.accessibilityHint = helperText
        }
    }

    override var accessibilityElements: [Any]? {
        get { isClearButtonShown ? [textField, clearButton] : [textField] }
        set {}
    }

    // MARK: Layout

    /// Height of the bordered field (without the message) for the current traits.
    static func boxHeight(compatibleWith traits: UITraitCollection) -> CGFloat {
        let caption = RCTypography.lineHeight(.caption, compatibleWith: traits)
        let value = max(RCTypography.lineHeight(.body, compatibleWith: traits), RCTypography.lineHeight(.mono, compatibleWith: traits)) + 4
        return ceil(boxPadding.top + caption + value + boxPadding.bottom)
    }

    private var boxFrame: CGRect {
        CGRect(x: 0, y: 0, width: bounds.width, height: Self.boxHeight(compatibleWith: traitCollection))
    }

    private func messageTextX(isError: Bool) -> CGFloat {
        isError ? 2 + messageIconSide + 6 : 2
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: bounds.width > 0 ? sizeThatFits(bounds.size).height : Self.boxHeight(compatibleWith: traitCollection))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        var height = Self.boxHeight(compatibleWith: traitCollection)
        if let message = displayedMessage {
            let x = messageTextX(isError: message.isError)
            let width = max(0, size.width - x - 2)
            height += Self.messageSpacing + ceil(messageLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        }
        return CGSize(width: size.width, height: ceil(height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let box = boxFrame
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func place(_ rect: CGRect) -> CGRect {
            rtl ? CGRect(x: bounds.width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect
        }
        withoutImplicitAnimations {
            boxLayer.frame = box
            boxLayer.cornerRadius = RCRadius.md
            boxLayer.cornerCurve = .continuous
            let ringBounds = box.insetBy(dx: -Self.ringWidth, dy: -Self.ringWidth)
            ringLayer.bounds = CGRect(origin: .zero, size: ringBounds.size)
            ringLayer.position = CGPoint(x: box.midX, y: box.midY)
            ringLayer.cornerRadius = RCRadius.md + Self.ringWidth
            ringLayer.cornerCurve = .continuous
            if ringLayer.opacity == 0, !RCMotion.reduceMotion, ringLayer.animation(forKey: "transform") == nil {
                ringLayer.transform = collapsedRingTransform()
            }
        }
        let padding = Self.boxPadding
        let captionHeight = RCTypography.lineHeight(.caption, compatibleWith: traitCollection)
        let valueHeight = box.height - padding.top - padding.bottom - captionHeight
        var x = padding.left
        if !iconView.isHidden {
            iconView.frame = place(CGRect(x: x, y: ((box.height - iconSide) / 2).rounded(), width: iconSide, height: iconSide))
            x += iconSide + RCSpace.md
        }
        let valueY = padding.top + captionHeight
        let clearX = box.width - 8 - Self.clearButtonSide
        clearButton.bounds = CGRect(x: 0, y: 0, width: Self.clearButtonSide, height: Self.clearButtonSide)
        clearButton.center = place(CGRect(x: clearX, y: valueY + (valueHeight - Self.clearButtonSide) / 2, width: Self.clearButtonSide, height: Self.clearButtonSide)).center
        captionLabel.frame = place(CGRect(x: x, y: padding.top, width: max(0, box.width - x - padding.right), height: captionHeight))
        textField.frame = place(CGRect(x: x, y: valueY, width: max(0, clearX - 2 - x), height: valueHeight))

        if let message = displayedMessage {
            let messageX = messageTextX(isError: message.isError)
            let width = max(0, bounds.width - messageX - 2)
            let height = ceil(messageLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            let y = box.maxY + Self.messageSpacing
            messageLabel.frame = place(CGRect(x: messageX, y: y, width: width, height: height))
            let lineHeight = RCTypography.lineHeight(.footnote, compatibleWith: traitCollection)
            messageIcon.frame = place(CGRect(x: 2, y: y + ((lineHeight - messageIconSide) / 2).rounded(), width: messageIconSide, height: messageIconSide))
        }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

/// Small circular clear button (Lucide `x`) with a 44 pt hit area.
@MainActor
private final class ClearTextButton: RCControl {
    private let circle = CALayer()
    private let glyph = RCIconView(.x, pointSize: 12, strokeWidth: 2.5)
    private static let diameter: CGFloat = 20

    override func setUp() {
        isAccessibilityElement = true
        accessibilityLabel = "Clear text"
        accessibilityTraits = .button
        layer.addSublayer(circle)
        addSubview(glyph)
    }

    override func updateAppearance() {
        withoutImplicitAnimations {
            circle.backgroundColor = RCColor.lineStrong.cgColor(for: self)
        }
        glyph.tintColor = RCColor.textSecondary
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            let highlighted = isHighlighted
            RCMotion.animate(duration: highlighted ? RCMotion.pressDuration : RCMotion.releaseDuration) {
                self.circle.opacity = highlighted ? 0.6 : 1
                self.glyph.alpha = highlighted ? 0.6 : 1
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = Self.diameter
        withoutImplicitAnimations {
            circle.frame = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
            circle.cornerRadius = side / 2
        }
        glyph.frame = bounds
    }
}

/// Segmented control with a sliding thumb on a sunken track (shadcn `Tabs` list).
///
/// Tap a segment to select it; press the selected segment and drag to slide
/// the thumb across segments, committing on release (like
/// `UISegmentedControl`). Disabled segments are skipped.
///
/// **VoiceOver.** Each segment is its own button element ("View, selected,
/// button"), not one adjustable element. Segments here switch consequential
/// modes (View vs Control, which enables remote input): swiping through
/// explicit, individually activated options lets users hear every choice and
/// its disabled state before committing, whereas adjustable increments would
/// change the mode as a side effect of exploring. It also matches
/// `UISegmentedControl`, so the gesture model is familiar. The control's own
/// `accessibilityHint` is read on every segment.
@MainActor
final class RCSegmentedControl: RCControl {
    struct Item: Equatable {
        var title: String?
        var icon: RCIconGlyph?
        var accessibilityLabel: String
        init(title: String? = nil, icon: RCIconGlyph? = nil, accessibilityLabel: String? = nil) {
            self.title = title
            self.icon = icon
            self.accessibilityLabel = accessibilityLabel ?? title ?? ""
        }
    }

    enum Style: Sendable {
        /// Elevated thumb on a sunken track.
        case standard
        /// Accent-filled thumb for the listed segment indices (e.g. "Control").
        case accentOn(Set<Int>)
    }

    enum Size: Sendable {
        /// 36 pt track.
        case small
        /// 40 pt track (default).
        case regular

        var height: CGFloat {
            switch self {
            case .small: 36
            case .regular: 40
            }
        }
    }

    private(set) var items: [Item]
    private(set) var selectedIndex: Int
    var style: Style { didSet { applySelectionAppearance(animated: window != nil) } }
    /// Called after a user-initiated selection change.
    var onChange: ((Int) -> Void)?
    /// Hide titles and show icons only (compact layouts).
    var showsTitles = true {
        didSet {
            guard showsTitles != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }
    /// Track height. Grows with very large Dynamic Type so labels never clip.
    var size: Size = .regular {
        didSet {
            guard size != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    /// Gap between the track edge and the thumb.
    static let trackInset: CGFloat = 3
    private static let baseIconSide: CGFloat = 16
    private static let iconSpacing: CGFloat = 6
    private static let segmentPadding: CGFloat = 12
    private static let pressedAlpha: CGFloat = 0.4
    private static let thumbPressScale: CGFloat = 0.95

    private let thumbView = UIView()
    private var segmentLabels: [RCLabel] = []
    private var segmentIcons: [RCIconView] = []
    private var elements: [SegmentAccessibilityElement] = []
    private var disabled: Set<Int> = []

    /// Segment the thumb currently covers: `selectedIndex`, or the drag target while sliding.
    private var thumbIndex: Int
    private var isDraggingThumb = false
    private var pressedIndex: Int?
    private var appliedColors: [UIColor] = []

    init(items: [Item], selectedIndex: Int = 0, style: Style = .standard) {
        self.items = items
        let initial = items.indices.contains(selectedIndex) ? selectedIndex : 0
        self.selectedIndex = initial
        thumbIndex = initial
        self.style = style
        super.init(frame: .zero)
        rebuildSegments()
        updateAppearance()
    }

    override func setUp() {
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup
        thumbView.isUserInteractionEnabled = false
        addSubview(thumbView)
    }

    private func rebuildSegments() {
        segmentLabels.forEach { $0.removeFromSuperview() }
        segmentIcons.forEach { $0.removeFromSuperview() }
        segmentLabels = items.map { item in
            let label = RCLabel(item.title, style: .footnoteStrong, alignment: .center)
            addSubview(label)
            return label
        }
        segmentIcons = items.map { item in
            let icon = RCIconView(item.icon, pointSize: iconSide)
            icon.isHidden = item.icon == nil
            addSubview(icon)
            return icon
        }
        elements = items.indices.map { index in
            let element = SegmentAccessibilityElement(accessibilityContainer: self)
            element.onActivate = { [weak self] in self?.activateFromAccessibility(index) ?? false }
            return element
        }
        appliedColors = []
        updateAccessibilityElements()
    }

    func setSelectedIndex(_ index: Int, animated: Bool) {
        guard items.indices.contains(index), index != selectedIndex || thumbIndex != index else { return }
        selectedIndex = index
        thumbIndex = index
        if animated, window != nil {
            RCMotion.animate(RCMotion.snappy) { self.layoutThumb() }
            applySelectionAppearance(animated: true)
        } else {
            setNeedsLayout()
            applySelectionAppearance(animated: false)
        }
        updateAccessibilityElements()
    }

    func setEnabled(_ enabled: Bool, forSegmentAt index: Int) {
        if enabled { disabled.remove(index) } else { disabled.insert(index) }
        applySelectionAppearance(animated: false)
        updateAccessibilityElements()
    }

    func isEnabledForSegment(at index: Int) -> Bool { !disabled.contains(index) }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.45
            updateAccessibilityElements()
        }
    }

    // MARK: Appearance

    override func updateAppearance() {
        withoutImplicitAnimations {
            layer.backgroundColor = RCColor.surfaceSunken.cgColor(for: self)
            layer.borderColor = RCColor.line.cgColor(for: self)
            layer.borderWidth = RCLayout.hairline
        }
        applySelectionAppearance(animated: false)
        applyThumbShadow()
    }

    private var isAccentThumb: Bool {
        if case let .accentOn(indices) = style { return indices.contains(thumbIndex) }
        return false
    }

    private func applySelectionAppearance(animated requested: Bool) {
        guard segmentLabels.count == items.count else { return }
        let animated = requested && window != nil
        let accent = isAccentThumb
        let changes: @MainActor () -> Void = {
            self.thumbView.backgroundColor = accent ? RCColor.accent : RCColor.elevated
        }
        if animated {
            RCMotion.animate(duration: RCMotion.quickDuration, animations: changes)
        } else {
            changes()
        }
        withoutImplicitAnimations {
            thumbView.layer.borderWidth = accent ? 0 : RCLayout.hairline
            thumbView.layer.borderColor = RCColor.line.cgColor(for: self)
        }
        var colors: [UIColor] = []
        for index in items.indices {
            let color: UIColor
            if disabled.contains(index) {
                color = RCColor.textQuaternary
            } else if index == thumbIndex {
                color = accent ? RCColor.onAccent : RCColor.text
            } else {
                color = RCColor.textTertiary
            }
            colors.append(color)
            let changed = appliedColors.count != items.count || appliedColors[index] != color
            guard changed else { continue }
            let label = segmentLabels[index]
            let icon = segmentIcons[index]
            if animated {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = RCMotion.quickDuration
                label.layer.add(fade, forKey: "rc.crossfade")
                let from = icon.layer.presentation()?.value(forKey: "strokeColor")
                icon.tintColor = color
                if let from {
                    let tint = CABasicAnimation(keyPath: "strokeColor")
                    tint.fromValue = from
                    tint.duration = RCMotion.quickDuration
                    icon.layer.add(tint, forKey: "rc.tint")
                }
            } else {
                icon.tintColor = color
            }
            label.color = color
        }
        appliedColors = colors
    }

    private func applyThumbShadow() {
        guard thumbView.bounds.width > 0 else { return }
        let path = UIBezierPath.continuousRoundedRect(thumbView.bounds, radius: thumbCornerRadius).cgPath
        withoutImplicitAnimations {
            RCShadow.contact.apply(to: thumbView.layer, path: path, traits: traitCollection)
        }
    }

    // MARK: Layout

    private var trackHeight: CGFloat {
        max(size.height, ceil(RCTypography.lineHeight(.footnoteStrong, compatibleWith: traitCollection) + 14))
    }

    private var thumbCornerRadius: CGFloat { RCRadius.md - Self.trackInset }

    private var iconSide: CGFloat {
        (Self.baseIconSide * min(1.4, RCTypography.scale(for: .footnoteStrong, compatibleWith: traitCollection))).rounded()
    }

    override func updateTypography() {
        segmentIcons.forEach { $0.pointSize = iconSide }
    }

    override var intrinsicContentSize: CGSize { sizeThatFits(.zero) }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let widths = items.indices.map { naturalSegmentWidth(at: $0) }
        return CGSize(width: ceil((widths.max() ?? 0) * CGFloat(items.count) + Self.trackInset * 2), height: trackHeight)
    }

    private func naturalSegmentWidth(at index: Int) -> CGFloat {
        let showsTitle = showsTitles && items[index].title != nil
        let titleWidth = showsTitle ? segmentLabels[index].sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: trackHeight)).width : 0
        let iconWidth: CGFloat = items[index].icon == nil ? 0 : iconSide + (showsTitle ? Self.iconSpacing : 0)
        return max(RCLayout.minimumHitTarget, ceil(titleWidth + iconWidth + Self.segmentPadding * 2))
    }

    /// Segment index under `x` in a track of `width` (clamped to the ends).
    static func segmentIndex(atX x: CGFloat, width: CGFloat, count: Int, rightToLeft: Bool = false) -> Int? {
        guard count > 0 else { return nil }
        let inner = max(1, width - trackInset * 2)
        let slot = Int(((x - trackInset) / inner * CGFloat(count)).rounded(.down))
        let clamped = min(count - 1, max(0, slot))
        return rightToLeft ? count - 1 - clamped : clamped
    }

    private func segmentFrame(at index: Int) -> CGRect {
        let count = max(1, items.count)
        let width = (bounds.width - Self.trackInset * 2) / CGFloat(count)
        let slot = effectiveUserInterfaceLayoutDirection == .rightToLeft ? count - 1 - index : index
        return CGRect(x: Self.trackInset + CGFloat(slot) * width, y: Self.trackInset, width: width, height: bounds.height - Self.trackInset * 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCornerRadius(RCRadius.md)
        for index in items.indices {
            let frame = segmentFrame(at: index)
            let label = segmentLabels[index]
            let icon = segmentIcons[index]
            label.isHidden = !showsTitles || items[index].title == nil
            let iconWidth: CGFloat = icon.isHidden ? 0 : iconSide
            let gap: CGFloat = (!label.isHidden && !icon.isHidden) ? Self.iconSpacing : 0
            let maxLabelWidth = max(0, frame.width - 12 - iconWidth - gap)
            let labelSize = label.isHidden ? .zero : label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: frame.height))
            let labelWidth = min(labelSize.width, maxLabelWidth)
            let contentWidth = labelWidth + iconWidth + gap
            let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
            var x = frame.midX - contentWidth / 2
            let iconX = rtl ? x + contentWidth - iconWidth : x
            icon.frame = RCLayout.pixelAligned(CGRect(x: iconX, y: frame.midY - iconSide / 2, width: iconWidth, height: iconSide))
            x = rtl ? x : x + iconWidth + gap
            label.frame = RCLayout.pixelAligned(CGRect(x: x, y: frame.midY - labelSize.height / 2, width: labelWidth, height: labelSize.height))
            elements[index].accessibilityFrameInContainerSpace = frame.insetBy(dx: 0, dy: -Self.trackInset)
        }
        let previousThumbSize = thumbView.bounds.size
        layoutThumb()
        withoutImplicitAnimations { thumbView.layer.cornerRadius = thumbCornerRadius }
        thumbView.layer.cornerCurve = .continuous
        if thumbView.bounds.size != previousThumbSize { applyThumbShadow() }
    }

    private func layoutThumb() {
        guard items.indices.contains(thumbIndex) else { return }
        let frame = segmentFrame(at: thumbIndex)
        thumbView.bounds = CGRect(origin: .zero, size: frame.size)
        thumbView.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    // MARK: Tracking

    private func index(for touch: UITouch) -> Int {
        Self.segmentIndex(atX: touch.location(in: self).x, width: bounds.width, count: items.count, rightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft) ?? 0
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, !items.isEmpty else { return false }
        RCHaptics.prepare(.selection)
        let index = index(for: touch)
        if index == selectedIndex {
            isDraggingThumb = true
            setThumbPressed(true)
        } else {
            isDraggingThumb = false
            setPressedIndex(disabled.contains(index) ? nil : index)
        }
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let index = index(for: touch)
        if isDraggingThumb {
            if index != thumbIndex, !disabled.contains(index) { slideThumb(to: index) }
        } else {
            setPressedIndex(isTouchInside && !disabled.contains(index) ? index : nil)
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if isDraggingThumb {
            isDraggingThumb = false
            setThumbPressed(false)
            if thumbIndex != selectedIndex { commit(thumbIndex, playHaptic: false) }
        } else {
            setPressedIndex(nil)
            if let touch, isTouchInside {
                let index = index(for: touch)
                if index != selectedIndex, !disabled.contains(index) { commit(index, playHaptic: true) }
            }
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        setPressedIndex(nil)
        if isDraggingThumb {
            isDraggingThumb = false
            setThumbPressed(false)
            if thumbIndex != selectedIndex {
                thumbIndex = selectedIndex
                RCMotion.animate(RCMotion.snappy) { self.layoutThumb() }
                applySelectionAppearance(animated: true)
            }
        }
    }

    private func slideThumb(to index: Int) {
        thumbIndex = index
        RCHaptics.play(.selection)
        RCMotion.animate(RCMotion.snappy) { self.layoutThumb() }
        applySelectionAppearance(animated: true)
    }

    private func commit(_ index: Int, playHaptic: Bool) {
        if playHaptic { RCHaptics.play(.selection) }
        setSelectedIndex(index, animated: true)
        sendActions(for: .valueChanged)
        onChange?(index)
    }

    private func setThumbPressed(_ pressed: Bool) {
        guard !RCMotion.reduceMotion else { return }
        RCMotion.animate(RCMotion.snappy) {
            self.thumbView.transform = pressed ? CGAffineTransform(scaleX: Self.thumbPressScale, y: Self.thumbPressScale) : .identity
        }
    }

    private func setPressedIndex(_ index: Int?) {
        guard index != pressedIndex else { return }
        let previous = pressedIndex
        pressedIndex = index
        RCMotion.animate(duration: index == nil ? RCMotion.releaseDuration : RCMotion.pressDuration) {
            if let previous, self.items.indices.contains(previous) {
                self.segmentLabels[previous].alpha = 1
                self.segmentIcons[previous].alpha = 1
            }
            if let index {
                self.segmentLabels[index].alpha = Self.pressedAlpha
                self.segmentIcons[index].alpha = Self.pressedAlpha
            }
        }
    }

    // MARK: Accessibility

    override var accessibilityElements: [Any]? {
        get { elements }
        set {}
    }

    override var accessibilityHint: String? {
        didSet { updateAccessibilityElements() }
    }

    private func updateAccessibilityElements() {
        for (index, element) in elements.enumerated() where items.indices.contains(index) {
            element.accessibilityLabel = items[index].accessibilityLabel
            element.accessibilityHint = accessibilityHint
            var traits: UIAccessibilityTraits = .button
            if index == selectedIndex { traits.insert(.selected) }
            if !isEnabled || disabled.contains(index) { traits.insert(.notEnabled) }
            element.accessibilityTraits = traits
        }
    }

    private func activateFromAccessibility(_ index: Int) -> Bool {
        guard isEnabled, items.indices.contains(index), !disabled.contains(index) else { return false }
        if index != selectedIndex { commit(index, playHaptic: true) }
        return true
    }
}

@MainActor
private final class SegmentAccessibilityElement: UIAccessibilityElement {
    var onActivate: (() -> Bool)?

    override func accessibilityActivate() -> Bool {
        onActivate?() ?? false
    }
}
