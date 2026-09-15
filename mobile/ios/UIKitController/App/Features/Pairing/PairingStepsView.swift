import UIKit

/// The three relay-admin steps as a numbered timeline. Each step is a single
/// accessibility element ("Step N. Title. Text").
@MainActor
final class PairingStepsView: RCView {
    struct Step: Sendable {
        let title: String
        let text: String
    }

    static let steps: [Step] = [
        Step(title: "Open relay admin", text: "Sign in to your relay console on a computer."),
        Step(title: "Create a controller pairing", text: "Choose what this phone may do. The code is one-time and expires within minutes."),
        Step(title: "Scan the code", text: "Your controller key is created in the Secure Enclave and never leaves this device."),
    ]

    private static let rowSpacing: CGFloat = RCSpace.xl
    private let rows: [PairingStepRow]
    private let connectors: [CALayer]

    override init(frame: CGRect) {
        rows = Self.steps.enumerated().map { PairingStepRow(number: $0.offset + 1, step: $0.element) }
        connectors = Self.steps.dropLast().map { _ in CALayer() }
        super.init(frame: frame)
        connectors.forEach(layer.addSublayer)
        rows.forEach(addSubview)
        updateAppearance()
    }

    override func updateAppearance() {
        withoutImplicitAnimations {
            for connector in connectors {
                connector.backgroundColor = RCColor.lineStrong.cgColor(for: self)
            }
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let heights = rows.map { $0.sizeThatFits(CGSize(width: size.width, height: .greatestFiniteMagnitude)).height }
        return CGSize(width: size.width, height: ceil(heights.reduce(0, +) + Self.rowSpacing * CGFloat(max(0, rows.count - 1))))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var y: CGFloat = 0
        var frames: [CGRect] = []
        for row in rows {
            let height = ceil(row.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height)
            row.frame = CGRect(x: 0, y: y, width: bounds.width, height: height)
            frames.append(row.frame)
            y += height + Self.rowSpacing
        }
        withoutImplicitAnimations {
            for (index, connector) in connectors.enumerated() {
                let disc = rows[index].discFrame.offsetBy(dx: 0, dy: frames[index].minY)
                let nextDisc = rows[index + 1].discFrame.offsetBy(dx: 0, dy: frames[index + 1].minY)
                let top = disc.maxY + RCSpace.xs
                let bottom = nextDisc.minY - RCSpace.xs
                connector.frame = CGRect(x: RCLayout.pixelAligned(disc.midX - 0.5), y: top, width: 1, height: max(0, bottom - top))
            }
        }
    }
}

@MainActor
private final class PairingStepRow: RCView {
    private static let baseDisc: CGFloat = 28
    private static let gap: CGFloat = 14

    private let disc = CALayer()
    private let numberLabel = RCLabel(style: .footnoteStrong, color: RCColor.onAccent, alignment: .center)
    private let titleLabel = RCLabel(style: .calloutStrong, color: RCColor.text, lines: 0)
    private let textLabel = RCLabel(style: .subheadline, color: RCColor.textSecondary, lines: 0)

    init(number: Int, step: PairingStepsView.Step) {
        super.init(frame: .zero)
        numberLabel.usesMonospacedDigits = true
        numberLabel.text = "\(number)"
        titleLabel.text = step.title
        textLabel.text = step.text
        isAccessibilityElement = true
        accessibilityLabel = "Step \(number). \(step.title). \(step.text)"
        accessibilityTraits = .staticText
    }

    override func setUp() {
        isUserInteractionEnabled = false
        layer.addSublayer(disc)
        addSubview(numberLabel)
        addSubview(titleLabel)
        addSubview(textLabel)
    }

    override func updateAppearance() {
        withoutImplicitAnimations {
            disc.backgroundColor = RCColor.accent.cgColor(for: self)
        }
    }

    /// Disc grows with Dynamic Type but stays compact.
    private var discSide: CGFloat {
        ceil(Self.baseDisc * min(RCTypography.scale(for: .footnoteStrong, compatibleWith: traitCollection), 1.5))
    }

    var discFrame: CGRect {
        CGRect(x: 0, y: 0, width: discSide, height: discSide)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textWidth = max(0, size.width - discSide - Self.gap)
        let fit = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        let titleHeight = ceil(titleLabel.sizeThatFits(fit).height)
        let titleY = titleHeight < discSide ? (discSide - titleHeight) / 2 : 0
        let height = titleY + titleHeight + RCSpace.xxs + ceil(textLabel.sizeThatFits(fit).height)
        return CGSize(width: size.width, height: ceil(max(discSide, height)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = discSide
        withoutImplicitAnimations {
            disc.frame = CGRect(x: 0, y: 0, width: side, height: side)
            disc.cornerRadius = side / 2
        }
        let numberHeight = numberLabel.sizeThatFits(CGSize(width: side, height: side)).height
        numberLabel.frame = CGRect(x: 0, y: (side - numberHeight) / 2, width: side, height: numberHeight)
        let x = side + Self.gap
        let width = max(0, bounds.width - x)
        let fit = CGSize(width: width, height: .greatestFiniteMagnitude)
        let titleHeight = ceil(titleLabel.sizeThatFits(fit).height)
        // Center a single-line title on the disc; longer titles align to its top.
        let titleY = titleHeight < side ? (side - titleHeight) / 2 : 0
        titleLabel.frame = CGRect(x: x, y: titleY, width: width, height: titleHeight)
        textLabel.frame = CGRect(x: x, y: titleY + titleHeight + RCSpace.xxs, width: width, height: ceil(textLabel.sizeThatFits(fit).height))
    }
}
