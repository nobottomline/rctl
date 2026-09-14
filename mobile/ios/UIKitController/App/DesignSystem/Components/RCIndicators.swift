import UIKit

/// Arc spinner rotated on the render server (no per-frame main-thread work).
/// Color follows `tintColor`.
@MainActor
final class RCSpinner: RCView {
    private let arc = CAShapeLayer()
    private(set) var isAnimating = false
    var hidesWhenStopped = true
    let diameter: CGFloat
    let lineWidth: CGFloat

    init(diameter: CGFloat = 20, lineWidth: CGFloat = 2) {
        self.diameter = diameter
        self.lineWidth = lineWidth
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        isHidden = hidesWhenStopped
    }

    override func setUp() {
        isUserInteractionEnabled = false
        arc.fillColor = nil
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = 0.72
        layer.addSublayer(arc)
        tintColor = RCColor.textTertiary
    }

    override func updateAppearance() {
        arc.strokeColor = tintColor.cgColor(for: self)
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        withoutImplicitAnimations { updateAppearance() }
    }

    override var intrinsicContentSize: CGSize { CGSize(width: diameter, height: diameter) }
    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitAnimations {
            arc.frame = CGRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
            arc.lineWidth = lineWidth
            arc.path = UIBezierPath(ovalIn: arc.bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)).cgPath
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, isAnimating { addRotation() }
    }

    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        isHidden = false
        addRotation()
    }

    func stopAnimating() {
        guard isAnimating else { return }
        isAnimating = false
        arc.removeAnimation(forKey: "rc.spin")
        if hidesWhenStopped { isHidden = true }
    }

    private func addRotation() {
        guard arc.animation(forKey: "rc.spin") == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 0.8
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        arc.add(rotation, forKey: "rc.spin")
    }
}

/// Semantic status pill: dot + text, never color alone (shadcn `Badge`).
@MainActor
final class RCStatusBadge: RCView {
    enum Tone: Sendable { case success, attention, danger, neutral, accent }

    private(set) var text: String = ""
    private(set) var tone: Tone = .neutral
    private(set) var isBusy = false
    private(set) var isPulsing = false

    private let label = RCLabel(style: .caption)
    private let dot = CALayer()
    private let spinner = RCSpinner(diameter: 10, lineWidth: 1.5)

    init(text: String = "", tone: Tone = .neutral) {
        super.init(frame: .zero)
        configure(text: text, tone: tone)
    }

    override func setUp() {
        isAccessibilityElement = true
        layer.addSublayer(dot)
        addSubview(label)
        addSubview(spinner)
    }

    /// Updates content; `animated` crossfades text and tone changes.
    func configure(text: String, tone: Tone, busy: Bool = false, pulsing: Bool = false, animated: Bool = false) {
        guard text != self.text || tone != self.tone || busy != isBusy || pulsing != isPulsing else { return }
        self.text = text
        self.tone = tone
        isBusy = busy
        isPulsing = pulsing
        label.text = text
        accessibilityLabel = text
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        dot.isHidden = busy
        updateAppearance()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func updateAppearance() {
        let (foreground, background) = colors
        label.color = foreground
        spinner.tintColor = foreground
        withoutImplicitAnimations {
            dot.backgroundColor = foreground.cgColor(for: self)
            layer.backgroundColor = background.cgColor(for: self)
        }
    }

    private var colors: (UIColor, UIColor) {
        switch tone {
        case .success: (RCColor.success, RCColor.successSoft)
        case .attention, .accent: (RCColor.accent, RCColor.accentSoft)
        case .danger: (RCColor.danger, RCColor.dangerSoft)
        case .neutral: (RCColor.textSecondary, RCColor.surfaceSunken)
        }
    }

    override var intrinsicContentSize: CGSize { sizeThatFits(.zero) }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let labelSize = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 24))
        return CGSize(width: ceil(labelSize.width + 8 + 10 + 6 + 8), height: max(24, ceil(labelSize.height + 8)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = bounds.height
        withoutImplicitAnimations {
            layer.cornerRadius = height / 2
            dot.frame = CGRect(x: 9, y: (height - 6) / 2, width: 6, height: 6)
            dot.cornerRadius = 3
        }
        spinner.frame = CGRect(x: 7, y: (height - 10) / 2, width: 10, height: 10)
        let labelSize = label.sizeThatFits(bounds.size)
        label.frame = CGRect(x: 8 + 10 + 6, y: (height - labelSize.height) / 2, width: bounds.width - 24 - 8, height: labelSize.height)
    }
}

/// Loading placeholder block with a shimmer that only runs while on screen.
@MainActor
final class RCSkeletonView: RCView {
    var cornerRadius: CGFloat = RCRadius.sm { didSet { setNeedsLayout() } }

    override func setUp() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    override func updateAppearance() {
        layer.backgroundColor = RCColor.surfaceSunken.cgColor(for: self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyCornerRadius(min(cornerRadius, bounds.height / 2))
    }
}

/// One-pixel divider.
@MainActor
final class RCSeparator: RCView {
    var color: UIColor = RCColor.line { didSet { updateAppearance() } }

    override func setUp() { isUserInteractionEnabled = false }

    override func updateAppearance() {
        layer.backgroundColor = color.cgColor(for: self)
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: RCLayout.hairline) }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: RCLayout.hairline) }
}
