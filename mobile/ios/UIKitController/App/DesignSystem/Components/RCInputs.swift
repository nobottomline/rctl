import UIKit

/// Labeled text input (shadcn `Input` + `Label`) with a focus ring and an
/// inline error state. Configure keyboard traits on `textField` directly.
@MainActor
final class RCTextField: RCView, UITextFieldDelegate {
    let textField = UITextField()
    var label: String { didSet { titleLabel.text = label } }
    var placeholder: String? { didSet { updatePlaceholder() } }
    var icon: RCIconGlyph? { didSet { iconView.glyph = icon; iconView.isHidden = icon == nil; setNeedsLayout() } }
    /// SF Mono input text (addresses).
    var isMonospaced = false { didSet { updateTypography() } }
    /// Non-nil shows the danger ring; the message itself is rendered by the caller (e.g. an `RCCallout`).
    var errorMessage: String? { didSet { updateAppearance(); accessibilityValue = errorMessage } }
    var text: String {
        get { textField.text ?? "" }
        set { textField.text = newValue }
    }
    var onChange: ((String) -> Void)?
    /// Return key handler. Return `true` to resign first responder.
    var onReturn: (() -> Bool)?

    private let titleLabel = RCLabel(style: .caption, color: RCColor.textTertiary)
    private let iconView = RCIconView(pointSize: 18)
    private let ring = CALayer()

    init(label: String, placeholder: String? = nil, icon: RCIconGlyph? = nil) {
        self.label = label
        self.placeholder = placeholder
        self.icon = icon
        super.init(frame: .zero)
        titleLabel.text = label
        iconView.glyph = icon
        iconView.isHidden = icon == nil
        updatePlaceholder()
    }

    override func setUp() {
        layer.addSublayer(ring)
        addSubview(iconView)
        addSubview(titleLabel)
        textField.delegate = self
        textField.borderStyle = .none
        textField.clearButtonMode = .whileEditing
        textField.addTarget(self, action: #selector(editingChanged), for: .editingChanged)
        textField.addTarget(self, action: #selector(focusChanged), for: [.editingDidBegin, .editingDidEnd])
        addSubview(textField)
        let tap = UITapGestureRecognizer(target: self, action: #selector(focus))
        addGestureRecognizer(tap)
    }

    override func updateTypography() {
        textField.font = RCTypography.font(isMonospaced ? .mono : .body, compatibleWith: traitCollection)
        updatePlaceholder()
    }

    override func updateAppearance() {
        textField.textColor = RCColor.text
        textField.tintColor = RCColor.accent
        iconView.tintColor = textField.isFirstResponder ? RCColor.accent : RCColor.textTertiary
        layer.backgroundColor = RCColor.elevated.cgColor(for: self)
        let borderColor: UIColor = errorMessage != nil ? RCColor.danger : (textField.isFirstResponder ? RCColor.accent : RCColor.lineStrong)
        layer.borderColor = borderColor.cgColor(for: self)
        layer.borderWidth = 1
        let ringColor: UIColor? = errorMessage != nil ? RCColor.dangerSoft : (textField.isFirstResponder ? RCColor.focusRing : nil)
        ring.borderColor = ringColor?.cgColor(for: self)
        ring.borderWidth = ringColor == nil ? 0 : 3
    }

    private func updatePlaceholder() {
        guard let placeholder else { textField.attributedPlaceholder = nil; return }
        textField.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: RCColor.textQuaternary,
            .font: RCTypography.font(isMonospaced ? .mono : .body, compatibleWith: traitCollection),
        ])
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 60) }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: max(60, ceil(RCTypography.lineHeight(.caption, compatibleWith: traitCollection) + RCTypography.lineHeight(.body, compatibleWith: traitCollection) + 22))) }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCornerRadius(RCRadius.md)
        withoutImplicitAnimations {
            ring.frame = bounds.insetBy(dx: -3, dy: -3)
            ring.cornerRadius = RCRadius.md + 3
            ring.cornerCurve = .continuous
        }
        var x: CGFloat = 14
        if !iconView.isHidden {
            iconView.frame = CGRect(x: x, y: (bounds.height - 18) / 2, width: 18, height: 18)
            x += 18 + 12
        }
        let captionHeight = RCTypography.lineHeight(.caption, compatibleWith: traitCollection)
        let bodyHeight = RCTypography.lineHeight(.body, compatibleWith: traitCollection) + 4
        let top = (bounds.height - captionHeight - bodyHeight) / 2
        titleLabel.frame = CGRect(x: x, y: top, width: bounds.width - x - 14, height: captionHeight)
        textField.frame = CGRect(x: x, y: top + captionHeight, width: bounds.width - x - 8, height: bodyHeight)
    }

    @objc private func focus() { textField.becomeFirstResponder() }

    @objc private func editingChanged() { onChange?(text) }

    @objc private func focusChanged() {
        RCMotion.animate(duration: RCMotion.quickDuration) { self.updateAppearance() }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let resign = onReturn?() ?? true
        if resign { textField.resignFirstResponder() }
        return false
    }
}

/// Segmented control with a sliding thumb (shadcn `Tabs` list).
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

    private(set) var items: [Item]
    private(set) var selectedIndex: Int
    var style: Style { didSet { updateAppearance() } }
    /// Called after a user-initiated selection change.
    var onChange: ((Int) -> Void)?
    /// Hide titles and show icons only (compact layouts).
    var showsTitles = true { didSet { setNeedsLayout() } }

    private let thumb = CALayer()
    private var segmentLabels: [RCLabel] = []
    private var segmentIcons: [RCIconView] = []
    private var disabled: Set<Int> = []

    init(items: [Item], selectedIndex: Int = 0, style: Style = .standard) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.style = style
        super.init(frame: .zero)
        rebuildSegments()
        updateAppearance()
    }

    override func setUp() {
        isAccessibilityElement = false
        layer.addSublayer(thumb)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
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
            let icon = RCIconView(item.icon, pointSize: 16)
            icon.isHidden = item.icon == nil
            addSubview(icon)
            return icon
        }
    }

    func setSelectedIndex(_ index: Int, animated: Bool) {
        guard items.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        if animated {
            RCMotion.animate(RCMotion.snappy) { self.layoutThumb(); self.updateAppearance() }
        } else {
            setNeedsLayout()
            updateAppearance()
        }
    }

    func setEnabled(_ enabled: Bool, forSegmentAt index: Int) {
        if enabled { disabled.remove(index) } else { disabled.insert(index) }
        updateAppearance()
    }

    func isEnabledForSegment(at index: Int) -> Bool { !disabled.contains(index) }

    override func updateAppearance() {
        layer.backgroundColor = RCColor.surfaceSunken.cgColor(for: self)
        layer.borderColor = RCColor.line.cgColor(for: self)
        layer.borderWidth = RCLayout.hairline
        let accent: Bool
        if case let .accentOn(indices) = style { accent = indices.contains(selectedIndex) } else { accent = false }
        thumb.backgroundColor = (accent ? RCColor.accent : RCColor.elevated).cgColor(for: self)
        for index in items.indices {
            let selected = index == selectedIndex
            let color: UIColor = disabled.contains(index) ? RCColor.textQuaternary : (selected ? (accent ? RCColor.onAccent : RCColor.text) : RCColor.textTertiary)
            segmentLabels[index].color = color
            segmentIcons[index].tintColor = color
        }
    }

    override var intrinsicContentSize: CGSize { sizeThatFits(.zero) }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let widths = items.indices.map { segmentWidth(at: $0) }
        return CGSize(width: ceil((widths.max() ?? 0) * CGFloat(items.count) + 6), height: 40)
    }

    private func segmentWidth(at index: Int) -> CGFloat {
        let titleWidth = showsTitles ? segmentLabels[index].sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 40)).width : 0
        let iconWidth: CGFloat = items[index].icon == nil ? 0 : 16 + (showsTitles && items[index].title != nil ? 6 : 0)
        return titleWidth + iconWidth + 24
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCornerRadius(RCRadius.md)
        let segment = (bounds.width - 6) / CGFloat(max(1, items.count))
        for index in items.indices {
            let frame = CGRect(x: 3 + CGFloat(index) * segment, y: 3, width: segment, height: bounds.height - 6)
            let label = segmentLabels[index]
            let icon = segmentIcons[index]
            label.isHidden = !showsTitles || items[index].title == nil
            let labelWidth = label.isHidden ? 0 : min(label.sizeThatFits(frame.size).width, frame.width - 12)
            let iconWidth: CGFloat = icon.isHidden ? 0 : 16
            let gap: CGFloat = (!label.isHidden && !icon.isHidden) ? 6 : 0
            var x = frame.midX - (labelWidth + iconWidth + gap) / 2
            icon.frame = CGRect(x: x, y: frame.midY - 8, width: iconWidth, height: 16)
            x += iconWidth + gap
            let labelHeight = label.sizeThatFits(frame.size).height
            label.frame = CGRect(x: x, y: frame.midY - labelHeight / 2, width: labelWidth, height: labelHeight)
        }
        withoutImplicitAnimations { layoutThumb() }
    }

    private func layoutThumb() {
        let segment = (bounds.width - 6) / CGFloat(max(1, items.count))
        thumb.frame = CGRect(x: 3 + CGFloat(selectedIndex) * segment, y: 3, width: segment, height: bounds.height - 6)
        thumb.cornerRadius = RCRadius.md - 3
        thumb.cornerCurve = .continuous
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard isEnabled, !items.isEmpty else { return }
        let segment = (bounds.width - 6) / CGFloat(items.count)
        let index = min(items.count - 1, max(0, Int((gesture.location(in: self).x - 3) / segment)))
        guard index != selectedIndex, !disabled.contains(index) else { return }
        RCHaptics.play(.selection)
        setSelectedIndex(index, animated: true)
        sendActions(for: .valueChanged)
        onChange?(index)
    }

    // MARK: Accessibility: expose each segment as its own element.

    override var accessibilityElements: [Any]? {
        get {
            items.indices.map { index in
                let element = UIAccessibilityElement(accessibilityContainer: self)
                element.accessibilityLabel = items[index].accessibilityLabel
                element.accessibilityTraits = index == selectedIndex ? [.button, .selected] : (disabled.contains(index) ? [.button, .notEnabled] : .button)
                let segment = (bounds.width - 6) / CGFloat(max(1, items.count))
                element.accessibilityFrameInContainerSpace = CGRect(x: 3 + CGFloat(index) * segment, y: 0, width: segment, height: bounds.height)
                return element
            }
        }
        set {}
    }
}
