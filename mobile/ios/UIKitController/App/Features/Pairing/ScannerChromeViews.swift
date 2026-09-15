import UIKit

/// Title and guidance at the top of the scanner; crossfades between phases.
/// While a claim runs a small spinner sits beside the title (or below the
/// message when the title has no room for it). Lines are balanced so short
/// sentences never end on a single word.
@MainActor
final class ScannerInstructionView: RCView {
    private let titleLabel = RCLabel(style: .title2, color: RCColor.onStage, lines: 0, alignment: .center)
    private let messageLabel = RCLabel(style: .subheadline, color: RCColor.onStage.withAlphaComponent(0.78), lines: 0, alignment: .center)
    private let spinner = RCSpinner(diameter: ScannerInstructionView.spinnerSide, lineWidth: 2)
    private static let spacing: CGFloat = 6
    private static let spinnerSide: CGFloat = 18
    private static let spinnerGap: CGFloat = 10

    private(set) var title = ""
    private(set) var message = ""
    private(set) var showsProgress = false
    private var fadeGeneration = 0
    /// Hidden twins that measure every phase's copy with the live traits.
    private let measureTitle = RCLabel(style: .title2, lines: 0, alignment: .center)
    private let measureMessage = RCLabel(style: .subheadline, lines: 0, alignment: .center)
    private var reservedCache: (width: CGFloat, category: UIContentSizeCategory, height: CGFloat)?

    private struct LayoutKey: Equatable {
        let width: CGFloat
        let category: UIContentSizeCategory
        let progress: Bool
        let title: String
        let message: String
    }
    private var liveCache: (key: LayoutKey, layout: Layout)?

    private struct Layout {
        var title: CGRect
        var message: CGRect
        var spinner: CGRect?
        var height: CGFloat
    }

    override func setUp() {
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = [.staticText, .updatesFrequently]
        titleLabel.accessibilityTraits = .header
        spinner.tintColor = RCColor.onStage
        addSubview(titleLabel)
        addSubview(messageLabel)
        addSubview(spinner)
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
        let height = ScannerPresentation.allCopy.map { copy -> CGFloat in
            measureTitle.text = copy.title
            measureMessage.text = copy.message
            return Self.layout(title: measureTitle, message: measureMessage, progress: copy.progress, width: width).height
        }.max() ?? 0
        reservedCache = (width, category, height)
        return height
    }

    /// Returns true when the copy changed.
    @discardableResult
    func setText(title: String, message: String, showsProgress: Bool, animated: Bool) -> Bool {
        guard title != self.title || message != self.message || showsProgress != self.showsProgress else { return false }
        self.title = title
        self.message = message
        self.showsProgress = showsProgress
        accessibilityLabel = "\(title). \(message)"
        accessibilityValue = showsProgress ? "In progress" : nil
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
        if showsProgress { spinner.startAnimating() } else { spinner.stopAnimating() }
        layoutLabels()
        superview?.setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: liveLayout(width: size.width).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutLabels()
    }

    /// The displayed copy's layout; balancing measures several widths, so the
    /// last result is reused until the copy, width or text size changes.
    private func liveLayout(width: CGFloat) -> Layout {
        let key = LayoutKey(width: width, category: traitCollection.preferredContentSizeCategory, progress: spinner.isAnimating,
                            title: titleLabel.text ?? "", message: messageLabel.text ?? "")
        if let liveCache, liveCache.key == key { return liveCache.layout }
        let layout = Self.layout(title: titleLabel, message: messageLabel, progress: key.progress, width: width)
        liveCache = (key, layout)
        return layout
    }

    private func layoutLabels() {
        let layout = liveLayout(width: bounds.width)
        titleLabel.frame = layout.title
        messageLabel.frame = layout.message
        if let frame = layout.spinner { spinner.frame = frame }
    }

    /// One pass for measuring and placing. The spinner leads a single-line
    /// title when both fit; otherwise it gets its own row under the message.
    private static func layout(title: RCLabel, message: RCLabel, progress: Bool, width: CGFloat) -> Layout {
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let natural = title.sizeThatFits(unbounded)
        let inline = progress && ceil(natural.width) + spinnerSide + spinnerGap <= width
        var titleFrame: CGRect
        var spinnerFrame: CGRect?
        if inline {
            let titleWidth = ceil(natural.width)
            let titleHeight = ceil(natural.height)
            let groupX = (width - (spinnerSide + spinnerGap + titleWidth)) / 2
            titleFrame = CGRect(x: groupX + spinnerSide + spinnerGap, y: 0, width: titleWidth, height: titleHeight)
            spinnerFrame = CGRect(x: groupX, y: (titleHeight - spinnerSide) / 2, width: spinnerSide, height: spinnerSide)
        } else {
            let titleWidth = PairingTextBalance.width(of: title, fitting: width)
            let titleHeight = ceil(title.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
            titleFrame = CGRect(x: (width - titleWidth) / 2, y: 0, width: titleWidth, height: titleHeight)
        }
        let messageWidth = PairingTextBalance.width(of: message, fitting: width)
        let messageHeight = ceil(message.sizeThatFits(CGSize(width: messageWidth, height: .greatestFiniteMagnitude)).height)
        let messageFrame = CGRect(x: (width - messageWidth) / 2, y: titleFrame.maxY + spacing, width: messageWidth, height: messageHeight)
        var height = messageFrame.maxY
        if progress, !inline {
            spinnerFrame = CGRect(x: (width - spinnerSide) / 2, y: height + spinnerGap, width: spinnerSide, height: spinnerSide)
            height += spinnerGap + spinnerSide
        }
        titleFrame = RCLayout.pixelAligned(titleFrame)
        return Layout(
            title: titleFrame,
            message: RCLayout.pixelAligned(messageFrame),
            spinner: spinnerFrame.map { RCLayout.pixelAligned($0) },
            height: ceil(height)
        )
    }
}
