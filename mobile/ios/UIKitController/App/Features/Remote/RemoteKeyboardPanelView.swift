import RctlProtocol
import UIKit

/// Text and special-key input for Control mode. Replaces the dock and rides
/// above the system keyboard. Text is sent as HID keystrokes through the
/// model; focus stays in the field after sends and key taps.
@MainActor
final class RemoteKeyboardPanelView: RCSurfaceView, UITextViewDelegate {
    var onSendText: ((String) -> RemoteTextInputResult)?
    var onSendKey: ((RemoteKeyboardKey) -> Void)?
    var onClose: (() -> Void)?
    /// The panel's preferred height changed (text wrapped or a message appeared).
    var onHeightChange: (() -> Void)?

    private let inputWell = UIView()
    private let textView = UITextView()
    private let placeholderLabel = RCLabel("Type on the device", style: .body, color: RCColor.textQuaternary)
    private let sendButton = RCIconButton(icon: .arrowUp, variant: .stage, shape: .rounded, diameter: 44, iconSize: 20, accessibilityLabel: "Send text to the device")
    private let closeButton = RCIconButton(icon: .x, variant: .stage, shape: .rounded, diameter: 44, iconSize: 18, accessibilityLabel: "Close keyboard")
    private let keyStrip = UIScrollView()
    private let keycaps: [RemoteKeycapButton] = RemoteKeyboardKey.allCases.map { RemoteKeycapButton($0) }
    private let messageLabel = RCLabel(style: .caption, color: RCColor.danger, lines: 0)

    private static let padding: CGFloat = 10
    private static let keyHeight: CGFloat = 44
    private static let textInsets = UIEdgeInsets(top: 11, left: 8, bottom: 11, right: 8)
    private static let maximumLines = 3
    private var lastInputHeight: CGFloat = 0

    init() {
        super.init(style: .floating, cornerRadius: RCRadius.xl)
    }

    override func setUp() {
        super.setUp()
        inputWell.isUserInteractionEnabled = true
        contentView.addSubview(inputWell)

        textView.delegate = self
        textView.backgroundColor = .clear
        textView.textContainerInset = Self.textInsets
        textView.textContainer.lineFragmentPadding = 4
        textView.isScrollEnabled = false
        textView.keyboardType = .asciiCapable
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.returnKeyType = .send
        textView.keyboardAppearance = .dark
        textView.accessibilityLabel = "Text to type on the device"
        inputWell.addSubview(textView)
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.isAccessibilityElement = false
        inputWell.addSubview(placeholderLabel)

        sendButton.isEnabled = false
        sendButton.haptic = nil
        sendButton.onTap = { [weak self] in self?.sendDraft() }
        closeButton.haptic = .selection
        closeButton.onTap = { [weak self] in self?.close() }
        contentView.addSubview(sendButton)
        contentView.addSubview(closeButton)

        keyStrip.showsHorizontalScrollIndicator = false
        keyStrip.alwaysBounceHorizontal = true
        keyStrip.clipsToBounds = true
        for keycap in keycaps {
            keycap.onTap = { [weak self] key in self?.sendKey(key) }
            keyStrip.addSubview(keycap)
        }
        contentView.addSubview(keyStrip)

        messageLabel.isHidden = true
        messageLabel.accessibilityTraits = .staticText
        contentView.addSubview(messageLabel)
    }

    override func updateAppearance() {
        super.updateAppearance()
        inputWell.layer.backgroundColor = RCColor.elevated.cgColor(for: self)
        inputWell.layer.borderWidth = 1
        inputWell.layer.borderColor = (messageLabel.isHidden ? RCColor.lineStrong : RCColor.danger).cgColor(for: self)
        textView.textColor = RCColor.text
        textView.tintColor = RCColor.accent
    }

    override func updateTypography() {
        super.updateTypography()
        textView.font = RCTypography.font(.body, compatibleWith: traitCollection)
    }

    // MARK: Focus

    /// Puts the caret in the text field (shows the system keyboard).
    func focus() {
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
    }

    func resignFocus() {
        if textView.isFirstResponder { textView.resignFirstResponder() }
    }

    var hasFocus: Bool { textView.isFirstResponder }

    // MARK: Actions

    private var draft: String { textView.text ?? "" }

    private func sendDraft() {
        guard !draft.isEmpty, let onSendText else { return }
        switch onSendText(draft) {
        case .sent:
            RCHaptics.play(.light)
            textView.text = ""
            textDidChange(enforceLimit: false)
            setMessage(nil)
        case let .rejected(message):
            RCHaptics.play(.warning)
            setMessage(message)
        }
        focus()
    }

    private func sendKey(_ key: RemoteKeyboardKey) {
        onSendKey?(key)
        focus()
    }

    private func close() {
        resignFocus()
        onClose?()
    }

    // MARK: UITextViewDelegate

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // The return key sends, like the SwiftUI field's submit; pasted newlines are kept.
        guard text == "\n" else { return true }
        sendDraft()
        return false
    }

    func textViewDidChange(_ textView: UITextView) {
        textDidChange(enforceLimit: true)
    }

    private func textDidChange(enforceLimit: Bool) {
        if enforceLimit {
            let limit = HIDKeyboard.maximumTextCharacters
            if draft.count > limit {
                textView.text = String(draft.prefix(limit))
                setMessage("Text is limited to \(limit) characters per send.")
            } else {
                setMessage(nil)
            }
        }
        placeholderLabel.isHidden = !draft.isEmpty
        let hasText = !draft.isEmpty
        if sendButton.isEnabled != hasText {
            sendButton.isEnabled = hasText
            sendButton.variant = hasText ? .accent : .stage
        }
        if abs(inputHeight(for: bounds.width) - lastInputHeight) > 0.5 {
            onHeightChange?()
        }
    }

    private func setMessage(_ message: String?) {
        guard message != messageLabel.text || (message == nil) != messageLabel.isHidden else { return }
        messageLabel.text = message
        messageLabel.isHidden = message == nil
        withoutImplicitAnimations { updateAppearance() }
        if let message {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        onHeightChange?()
    }

    // MARK: Layout

    private func inputHeight(for width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - Self.padding * 2 - 44 * 2 - 8 * 2)
        let font = textView.font ?? RCTypography.font(.body, compatibleWith: traitCollection)
        let lineHeight = font.lineHeight
        let minimum = ceil(lineHeight + Self.textInsets.top + Self.textInsets.bottom)
        let maximum = ceil(lineHeight * CGFloat(Self.maximumLines) + Self.textInsets.top + Self.textInsets.bottom)
        let fitted = ceil(textView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        return min(max(max(44, minimum), fitted), maximum)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        var height = Self.padding + inputHeight(for: size.width) + 8 + Self.keyHeight + Self.padding
        if !messageLabel.isHidden {
            height += 6 + messageLabel.sizeThatFits(CGSize(width: size.width - Self.padding * 2 - 4, height: .greatestFiniteMagnitude)).height
        }
        return CGSize(width: size.width, height: ceil(height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let padding = Self.padding
        let inputHeight = inputHeight(for: bounds.width)
        lastInputHeight = inputHeight
        closeButton.frame = CGRect(x: bounds.width - padding - 44, y: padding + inputHeight - 44, width: 44, height: 44)
        sendButton.frame = CGRect(x: closeButton.frame.minX - 8 - 44, y: closeButton.frame.minY, width: 44, height: 44)
        inputWell.frame = CGRect(x: padding, y: padding, width: max(0, sendButton.frame.minX - 8 - padding), height: inputHeight)
        inputWell.applyCornerRadius(RCRadius.md)
        textView.frame = inputWell.bounds
        textView.isScrollEnabled = textView.contentSize.height > inputHeight + 1
        let placeholderHeight = RCTypography.lineHeight(.body, compatibleWith: traitCollection)
        placeholderLabel.frame = CGRect(
            x: Self.textInsets.left + textView.textContainer.lineFragmentPadding,
            y: Self.textInsets.top + ((textView.font?.lineHeight ?? placeholderHeight) - placeholderHeight) / 2,
            width: max(0, inputWell.bounds.width - Self.textInsets.left - Self.textInsets.right),
            height: placeholderHeight
        )

        var y = padding + inputHeight + 8
        keyStrip.frame = CGRect(x: 0, y: y, width: bounds.width, height: Self.keyHeight)
        var x = padding
        for keycap in keycaps {
            let width = keycap.sizeThatFits(CGSize(width: 0, height: Self.keyHeight)).width
            keycap.frame = CGRect(x: x, y: 0, width: width, height: Self.keyHeight)
            x += width + 6
        }
        keyStrip.contentSize = CGSize(width: x - 6 + padding, height: Self.keyHeight)
        y += Self.keyHeight
        if !messageLabel.isHidden {
            let width = bounds.width - padding * 2 - 4
            let height = messageLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            messageLabel.frame = CGRect(x: padding + 2, y: y + 6, width: width, height: height)
        }
    }
}

/// Keycap for the special-key strip. Does not take first responder, so the
/// text field keeps focus.
@MainActor
private final class RemoteKeycapButton: RCControl {
    let key: RemoteKeyboardKey
    var onTap: ((RemoteKeyboardKey) -> Void)?

    private let label = RCLabel(style: .footnoteStrong, color: RCColor.text)
    private let iconView = RCIconView(pointSize: 18)

    init(_ key: RemoteKeyboardKey) {
        self.key = key
        super.init(frame: .zero)
        switch key.face {
        case let .text(text):
            label.text = text
            iconView.isHidden = true
        case let .glyph(glyph, mirrored):
            iconView.glyph = glyph
            iconView.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
            label.isHidden = true
        }
        accessibilityLabel = key.accessibilityLabel
    }

    override func setUp() {
        isAccessibilityElement = true
        accessibilityTraits = [.button, .keyboardKey]
        addSubview(label)
        addSubview(iconView)
        addTarget(self, action: #selector(handleTap), for: .primaryActionTriggered)
    }

    override func updateAppearance() {
        layer.backgroundColor = RCColor.elevated.cgColor(for: self)
        layer.borderColor = RCColor.line.cgColor(for: self)
        layer.borderWidth = 1
        iconView.tintColor = RCColor.text
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            if isHighlighted { RCHaptics.prepare(.light) }
            let highlighted = isHighlighted
            RCMotion.animate(duration: highlighted ? RCMotion.pressDuration : RCMotion.releaseDuration) {
                self.transform = highlighted && !RCMotion.reduceMotion ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
                self.layer.backgroundColor = (highlighted ? RCColor.lineStrong : RCColor.elevated).cgColor(for: self)
            }
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let content = label.isHidden ? 18 : label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 44)).width
        return CGSize(width: max(52, ceil(content + 28)), height: 44)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCornerRadius(RCRadius.sm)
        let transform = iconView.transform
        iconView.transform = .identity
        iconView.frame = bounds
        iconView.transform = transform
        let labelSize = label.sizeThatFits(bounds.size)
        label.frame = CGRect(x: (bounds.width - labelSize.width) / 2, y: (bounds.height - labelSize.height) / 2, width: labelSize.width, height: labelSize.height)
    }

    @objc private func handleTap() {
        RCHaptics.play(.light)
        onTap?(key)
    }
}

private extension RemoteKeyboardKey {
    enum Face {
        case text(String)
        case glyph(RCIconGlyph, mirrored: Bool)
    }

    var face: Face {
        switch self {
        case .escape: .text("esc")
        case .tab: .text("tab")
        case .enter: .glyph(.cornerDownLeft, mirrored: false)
        case .backspace: .glyph(.delete, mirrored: false)
        case .deleteForward: .glyph(.delete, mirrored: true)
        case .left: .glyph(.arrowLeft, mirrored: false)
        case .up: .glyph(.arrowUp, mirrored: false)
        case .down: .glyph(.arrowDown, mirrored: false)
        case .right: .glyph(.arrowRight, mirrored: false)
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .enter: "Return"
        case .backspace: "Backspace"
        case .deleteForward: "Forward delete"
        case .left: "Left arrow"
        case .up: "Up arrow"
        case .down: "Down arrow"
        case .right: "Right arrow"
        }
    }
}
