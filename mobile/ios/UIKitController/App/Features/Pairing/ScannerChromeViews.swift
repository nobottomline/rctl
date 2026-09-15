import UIKit

/// Title and guidance at the top of the scanner; crossfades between phases.
@MainActor
final class ScannerInstructionView: RCView {
    private let titleLabel = RCLabel(style: .title2, color: RCColor.onStage, lines: 0, alignment: .center)
    private let messageLabel = RCLabel(style: .subheadline, color: RCColor.onStage.withAlphaComponent(0.78), lines: 0, alignment: .center)
    private static let spacing: CGFloat = 6

    private(set) var title = ""
    private(set) var message = ""
    private var fadeGeneration = 0
    /// Hidden twins that measure every phase's copy with the live traits.
    private let measureTitle = RCLabel(style: .title2, lines: 0, alignment: .center)
    private let measureMessage = RCLabel(style: .subheadline, lines: 0, alignment: .center)
    private var reservedCache: (width: CGFloat, category: UIContentSizeCategory, height: CGFloat)?

    override func setUp() {
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = [.staticText, .updatesFrequently]
        titleLabel.accessibilityTraits = .header
        addSubview(titleLabel)
        addSubview(messageLabel)
        for label in [measureTitle, measureMessage] {
            label.isHidden = true
            addSubview(label)
        }
    }

    /// Height of the tallest phase copy at `width`, so the reticle can rest
    /// below it without moving when the phase changes.
    func reservedHeight(width: CGFloat) -> CGFloat {
        let category = traitCollection.preferredContentSizeCategory
        if let reservedCache, reservedCache.width == width, reservedCache.category == category {
            return reservedCache.height
        }
        let fit = CGSize(width: width, height: .greatestFiniteMagnitude)
        let height = ScannerPresentation.allCopy.map { copy -> CGFloat in
            measureTitle.text = copy.title
            measureMessage.text = copy.message
            return ceil(measureTitle.sizeThatFits(fit).height) + Self.spacing + ceil(measureMessage.sizeThatFits(fit).height)
        }.max() ?? 0
        reservedCache = (width, category, height)
        return height
    }

    /// Returns true when the text changed.
    @discardableResult
    func setText(title: String, message: String, animated: Bool) -> Bool {
        guard title != self.title || message != self.message else { return false }
        self.title = title
        self.message = message
        accessibilityLabel = "\(title). \(message)"
        fadeGeneration += 1
        let generation = fadeGeneration
        guard animated, window != nil else {
            applyText()
            alpha = 1
            return true
        }
        // Out, swap, in: two overlapping sentences are unreadable mid-crossfade.
        RCMotion.animate(duration: 0.09, curve: RCMotion.easeIn) {
            self.alpha = 0
        } completion: { _ in
            guard generation == self.fadeGeneration else { return }
            self.applyText()
            RCMotion.animate(duration: 0.16) { self.alpha = 1 }
        }
        return true
    }

    private func applyText() {
        titleLabel.text = title
        messageLabel.text = message
        layoutLabels()
        superview?.setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fit = CGSize(width: size.width, height: .greatestFiniteMagnitude)
        let height = titleLabel.sizeThatFits(fit).height + Self.spacing + messageLabel.sizeThatFits(fit).height
        return CGSize(width: size.width, height: ceil(height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutLabels()
    }

    private func layoutLabels() {
        let fit = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        let titleHeight = ceil(titleLabel.sizeThatFits(fit).height)
        titleLabel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: titleHeight)
        let messageHeight = ceil(messageLabel.sizeThatFits(fit).height)
        messageLabel.frame = CGRect(x: 0, y: titleHeight + Self.spacing, width: bounds.width, height: messageHeight)
    }
}

/// Camera denied / unavailable: explanation plus the paste fallback.
@MainActor
final class ScannerCameraUnavailableView: RCView {
    enum Kind: Equatable {
        case denied
        case unavailable(reason: String)
    }

    let settingsButton = RCButton(title: "Open Settings", icon: .settings, variant: .primary, size: .large)
    let pasteButton = RCButton(title: "Paste pairing code", icon: .clipboardPaste, variant: .secondary, size: .large)

    private let halo = CAShapeLayer()
    private let tile = RCIconTile(glyph: .cameraOff, tone: .neutral, side: 64)
    private let titleLabel = RCLabel(style: .title2, color: RCColor.onStage, lines: 0, alignment: .center)
    private let messageLabel = RCLabel(style: .subheadline, color: RCColor.textSecondary, lines: 0, alignment: .center)
    private var kind: Kind?
    private static let columnWidth: CGFloat = 340

    override func setUp() {
        halo.fillColor = nil
        halo.lineWidth = 1
        layer.addSublayer(halo)
        addSubview(tile)
        titleLabel.accessibilityTraits = .header
        addSubview(titleLabel)
        addSubview(messageLabel)
        pasteButton.haptic = nil
        addSubview(settingsButton)
        addSubview(pasteButton)
    }

    override func updateAppearance() {
        halo.strokeColor = RCColor.line.cgColor(for: self)
    }

    func configure(_ next: Kind) {
        guard next != kind else { return }
        kind = next
        switch next {
        case .denied:
            tile.glyph = .cameraOff
            titleLabel.text = "Camera access needed"
            messageLabel.text = "Allow camera access in Settings to scan pairing codes, or paste the code instead."
            settingsButton.isHidden = false
        case let .unavailable(reason):
            tile.glyph = .camera
            titleLabel.text = "Camera unavailable"
            messageLabel.text = reason + " You can still paste the pairing code."
            settingsButton.isHidden = true
        }
        setNeedsLayout()
    }

    /// Height of the centered content block for a width.
    private func contentHeight(width: CGFloat) -> CGFloat {
        let fit = CGSize(width: width, height: .greatestFiniteMagnitude)
        var height: CGFloat = 64 + RCSpace.xxl
        height += titleLabel.sizeThatFits(fit).height + RCSpace.sm
        height += messageLabel.sizeThatFits(fit).height + RCSpace.xxl
        height += RCButton.Size.large.height
        if !settingsButton.isHidden { height += RCSpace.md + RCButton.Size.large.height }
        return ceil(height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width - 2 * RCSpace.xxl, Self.columnWidth)
        let x = (bounds.width - width) / 2
        var y = max(0, (bounds.height - contentHeight(width: width)) / 2)
        let tileFrame = CGRect(x: (bounds.width - 64) / 2, y: y, width: 64, height: 64)
        tile.frame = tileFrame
        withoutImplicitAnimations {
            halo.frame = bounds
            halo.path = UIBezierPath.continuousRoundedRect(tileFrame.insetBy(dx: -10, dy: -10), radius: 64 * 0.28 + 10).cgPath
        }
        y += 64 + RCSpace.xxl
        let fit = CGSize(width: width, height: .greatestFiniteMagnitude)
        let titleHeight = ceil(titleLabel.sizeThatFits(fit).height)
        titleLabel.frame = CGRect(x: x, y: y, width: width, height: titleHeight)
        y += titleHeight + RCSpace.sm
        let messageHeight = ceil(messageLabel.sizeThatFits(fit).height)
        messageLabel.frame = CGRect(x: x, y: y, width: width, height: messageHeight)
        y += messageHeight + RCSpace.xxl
        if !settingsButton.isHidden {
            settingsButton.frame = CGRect(x: x, y: y, width: width, height: RCButton.Size.large.height)
            y += RCButton.Size.large.height + RCSpace.md
        }
        pasteButton.frame = CGRect(x: x, y: y, width: width, height: RCButton.Size.large.height)
    }
}
