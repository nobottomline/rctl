import UIKit

/// Indeterminate arc spinner. The arc rotates and gently changes length
/// ("breathes") entirely on the render server; nothing runs on the main thread
/// per frame. Animations exist only while the spinner is animating and in a
/// window, and resume in phase with other spinners when it returns. Under
/// Reduce Motion it is a fixed arc turning slowly. Color follows `tintColor`.
@MainActor
final class RCSpinner: RCView {
    private(set) var isAnimating = false
    var hidesWhenStopped = true {
        didSet { if !isAnimating { isHidden = hidesWhenStopped } }
    }
    var diameter: CGFloat {
        didSet { if diameter != oldValue { invalidateIntrinsicContentSize(); setNeedsLayout() } }
    }
    var lineWidth: CGFloat {
        didSet { if lineWidth != oldValue { setNeedsLayout() } }
    }

    private let rotor = CALayer()
    private let arc = CAShapeLayer()
    private var pathGeometry: CGSize = .zero

    private static let rotationKey = "rc.spinner.rotation"
    private static let breathKey = "rc.spinner.breath"
    private static let restingLength: CGFloat = 0.72

    init(diameter: CGFloat = 20, lineWidth: CGFloat = 2) {
        self.diameter = diameter
        self.lineWidth = lineWidth
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        isHidden = hidesWhenStopped
    }

    override func setUp() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        arc.fillColor = nil
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = Self.restingLength
        rotor.addSublayer(arc)
        layer.addSublayer(rotor)
        tintColor = RCColor.textTertiary
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
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
        let side = diameter
        withoutImplicitAnimations {
            rotor.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            rotor.position = CGPoint(x: RCLayout.pixelAligned(bounds.midX), y: RCLayout.pixelAligned(bounds.midY))
            arc.frame = rotor.bounds
            arc.lineWidth = lineWidth
            let geometry = CGSize(width: side, height: lineWidth)
            if geometry != pathGeometry {
                pathGeometry = geometry
                let center = CGPoint(x: side / 2, y: side / 2)
                let radius = max(0, (side - lineWidth) / 2)
                arc.path = UIBezierPath(arcCenter: center, radius: radius, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true).cgPath
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimations()
    }

    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        isHidden = false
        updateAnimations()
    }

    func stopAnimating() {
        guard isAnimating else { return }
        isAnimating = false
        updateAnimations()
        if hidesWhenStopped { isHidden = true }
    }

#if DEBUG
    /// Whether render-server animations are currently installed (tests).
    var hasRunningAnimations: Bool { rotor.animation(forKey: Self.rotationKey) != nil }
#endif

    @objc private func reduceMotionChanged() {
        removeAnimations()
        updateAnimations()
    }

    private func updateAnimations() {
        guard isAnimating, window != nil else {
            removeAnimations()
            return
        }
        guard rotor.animation(forKey: Self.rotationKey) == nil else { return }
        let reduceMotion = RCMotion.reduceMotion
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = reduceMotion ? 1.8 : 0.9
        rotation.repeatCount = .infinity
        rotation.isRemovedOnCompletion = false
        rotation.beginTime = RCLayerAnimation.alignedBeginTime(period: rotation.duration, in: rotor)
        rotor.add(rotation, forKey: Self.rotationKey)
        guard !reduceMotion else { return }

        // The head swings ahead and falls back while the tail barely drifts, so
        // the arc grows and shrinks as it turns.
        let easing = CAMediaTimingFunction(name: .easeInEaseOut)
        let head = CAKeyframeAnimation(keyPath: "strokeEnd")
        head.values = [0.26, 0.80, 0.26]
        head.keyTimes = [0, 0.5, 1]
        head.timingFunctions = [easing, easing]
        let tail = CAKeyframeAnimation(keyPath: "strokeStart")
        tail.values = [0, 0.1, 0]
        tail.keyTimes = [0, 0.6, 1]
        tail.timingFunctions = [easing, easing]
        let breath = CAAnimationGroup()
        breath.animations = [head, tail]
        breath.duration = 1.8
        head.duration = breath.duration
        tail.duration = breath.duration
        breath.repeatCount = .infinity
        breath.isRemovedOnCompletion = false
        breath.beginTime = RCLayerAnimation.alignedBeginTime(period: breath.duration, in: arc)
        arc.add(breath, forKey: Self.breathKey)
    }

    private func removeAnimations() {
        rotor.removeAnimation(forKey: Self.rotationKey)
        arc.removeAnimation(forKey: Self.breathKey)
    }
}

/// Semantic status pill: dot + text, never color alone (shadcn `Badge`).
///
/// `configure(…, animated: true)` crossfades text and tone while the pill
/// springs to its new width, even when the parent snaps the frame. `pulsing`
/// emits an expanding ring from the dot on the render server (a static ring
/// under Reduce Motion); `busy` swaps the dot for a small spinner.
@MainActor
final class RCStatusBadge: RCView {
    enum Tone: Sendable { case success, attention, danger, neutral, accent }

    private(set) var text: String = ""
    private(set) var tone: Tone = .neutral
    private(set) var isBusy = false
    private(set) var isPulsing = false

    private let label = RCLabel(style: .caption)
    /// Shows the previous text while it fades out during an animated change.
    private let outgoingLabel = RCLabel(style: .caption)
    /// Rectangular clip (a scissor rect, no offscreen pass) that keeps text
    /// inside the pill while its width springs.
    private let textClip = UIView()
    private let dot = CALayer()
    private let ring = CALayer()
    private let spinner = RCSpinner(diameter: 10, lineWidth: 1.5)
    /// Frame of the last layout pass; the start of a width animation.
    private var laidOutFrame: CGRect?
    /// Media time until which a frame change counts as the result of an
    /// animated configuration (the parent lays out within the same frame).
    private var resizeAnimationDeadline: CFTimeInterval = 0

    private static let pulseKey = "rc.badge.pulse"
    private static let pulsePeriod: CFTimeInterval = 2
    private static let resizeKeys = ("rc.badge.bounds", "rc.badge.position")

#if DEBUG
    /// Number of configurations that changed something (tests).
    private(set) var appliedConfigurationCount = 0
#endif

    init(text: String = "", tone: Tone = .neutral) {
        super.init(frame: .zero)
        configure(text: text, tone: tone)
    }

    override func setUp() {
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        ring.opacity = 0
        ring.borderWidth = 1.5
        layer.addSublayer(ring)
        layer.addSublayer(dot)
        label.isAccessibilityElement = false
        outgoingLabel.isAccessibilityElement = false
        outgoingLabel.alpha = 0
        textClip.clipsToBounds = true
        textClip.isUserInteractionEnabled = false
        textClip.addSubview(outgoingLabel)
        textClip.addSubview(label)
        addSubview(textClip)
        spinner.alpha = 0
        addSubview(spinner)
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    /// Updates content; `animated` crossfades text and tone changes and springs
    /// the width. Calling it with the current values does nothing.
    func configure(text: String, tone: Tone, busy: Bool = false, pulsing: Bool = false, animated: Bool = false) {
        guard text != self.text || tone != self.tone || busy != isBusy || pulsing != isPulsing else { return }
#if DEBUG
        appliedConfigurationCount += 1
#endif
        let animate = animated && window != nil
        let textChanged = text != self.text
        let toneChanged = tone != self.tone
        let busyChanged = busy != isBusy

        if animate, textChanged, !self.text.isEmpty {
            outgoingLabel.style = label.style
            outgoingLabel.color = label.color
            outgoingLabel.text = self.text
            outgoingLabel.frame = label.frame
            outgoingLabel.alpha = 1
            label.alpha = 0
            RCMotion.animate(duration: RCMotion.pressDuration) { self.outgoingLabel.alpha = 0 }
            RCMotion.animate(duration: RCMotion.quickDuration, delay: 0.04) { self.label.alpha = 1 }
        }

        self.text = text
        self.tone = tone
        isBusy = busy
        isPulsing = pulsing
        label.text = text
        accessibilityLabel = text
        accessibilityValue = busy ? "In progress" : nil

        if toneChanged || textChanged { applyColors(animated: animate && toneChanged) }
        if busyChanged { applyBusy(animated: animate) }
        updatePulse()

        if textChanged {
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            if animate {
                resizeAnimationDeadline = CACurrentMediaTime() + 0.25
            }
        }
    }

    override func updateAppearance() {
        applyColors(animated: false)
    }

    override func updateTypography() {
        updatePulse()
    }

    private var palette: (foreground: UIColor, background: UIColor, dot: UIColor) {
        switch tone {
        case .success: (RCColor.success, RCColor.successSoft, RCColor.success)
        case .attention, .accent: (RCColor.accent, RCColor.accentSoft, RCColor.accent)
        case .danger: (RCColor.danger, RCColor.dangerSoft, RCColor.danger)
        case .neutral: (RCColor.textSecondary, RCColor.surfaceSunken, RCColor.textTertiary)
        }
    }

    private func applyColors(animated: Bool) {
        let palette = palette
        let duration = animated && !RCMotion.reduceMotion ? RCMotion.quickDuration : (animated ? RCMotion.reducedDuration : 0)
        RCLayerAnimation.set(layer, "backgroundColor", to: palette.background.cgColor(for: self), duration: duration)
        RCLayerAnimation.set(dot, "backgroundColor", to: palette.dot.cgColor(for: self), duration: duration)
        withoutImplicitAnimations { ring.borderColor = palette.dot.cgColor(for: self) }
        // Tone text on the soft wash is below 4.5:1 in Warm; Increase Contrast gets ink.
        label.color = traitCollection.accessibilityContrast == .high ? RCColor.text : palette.foreground
        spinner.tintColor = palette.dot
    }

    private func applyBusy(animated: Bool) {
        if isBusy { spinner.startAnimating() }
        let busy = isBusy
        RCLayerAnimation.set(dot, "opacity", to: Float(busy ? 0 : 1), duration: animated ? RCMotion.quickDuration : 0)
        let changes: @MainActor () -> Void = { self.spinner.alpha = busy ? 1 : 0 }
        let finish: @MainActor (Bool) -> Void = { _ in
            if !self.isBusy { self.spinner.stopAnimating() }
        }
        if animated {
            RCMotion.animate(duration: RCMotion.quickDuration, animations: changes, completion: finish)
        } else {
            changes()
            finish(true)
        }
    }

    // MARK: Pulse

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePulse()
    }

#if DEBUG
    var hasPulseAnimation: Bool { ring.animation(forKey: Self.pulseKey) != nil }
#endif

    @objc private func reduceMotionChanged() {
        updatePulse()
    }

    private func updatePulse() {
        ring.removeAnimation(forKey: Self.pulseKey)
        let side = metrics.dot
        let showsRing = isPulsing && !isBusy && window != nil
        guard showsRing else {
            withoutImplicitAnimations { ring.opacity = 0 }
            return
        }
        if RCMotion.reduceMotion {
            withoutImplicitAnimations {
                ring.bounds = CGRect(x: 0, y: 0, width: side * 2.2, height: side * 2.2)
                ring.cornerRadius = side * 1.1
                ring.opacity = 0.4
            }
            return
        }
        withoutImplicitAnimations {
            ring.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            ring.cornerRadius = side / 2
            ring.opacity = 0
        }
        let grow = CABasicAnimation(keyPath: "bounds.size")
        grow.fromValue = NSValue(cgSize: CGSize(width: side, height: side))
        grow.toValue = NSValue(cgSize: CGSize(width: side * 3, height: side * 3))
        let round = CABasicAnimation(keyPath: "cornerRadius")
        round.fromValue = side / 2
        round.toValue = side * 1.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 0
        for animation in [grow, round, fade] {
            animation.duration = 1.3
            animation.timingFunction = RCMotion.easeOut
        }
        let pulse = CAAnimationGroup()
        pulse.animations = [grow, round, fade]
        pulse.duration = Self.pulsePeriod
        pulse.repeatCount = .infinity
        pulse.isRemovedOnCompletion = false
        pulse.beginTime = RCLayerAnimation.alignedBeginTime(period: Self.pulsePeriod, in: ring)
        ring.add(pulse, forKey: Self.pulseKey)
    }

    // MARK: Layout

    private struct Metrics {
        let height: CGFloat
        let lineHeight: CGFloat
        let dot: CGFloat
        let spinner: CGFloat
        let leading: CGFloat
        let gap: CGFloat
        let trailing: CGFloat
    }

    private var metrics: Metrics {
        // Paddings grow a little with Dynamic Type so large text doesn't crowd the dot or spinner.
        let scale = min(RCTypography.scale(for: .caption, compatibleWith: traitCollection), 1.34)
        let lineHeight = RCTypography.lineHeight(.caption, compatibleWith: traitCollection)
        let dot = (6 * scale).rounded()
        return Metrics(
            height: max(24, lineHeight + 8),
            lineHeight: lineHeight,
            dot: dot,
            spinner: dot + 4,
            leading: (8 * scale).rounded(),
            gap: (6 * scale).rounded(),
            trailing: (10 * scale).rounded()
        )
    }

    override var intrinsicContentSize: CGSize { sizeThatFits(.zero) }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let metrics = metrics
        guard !text.isEmpty else { return CGSize(width: metrics.height, height: metrics.height) }
        let textWidth = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: metrics.lineHeight)).width
        let width = metrics.leading + max(metrics.dot, 0) + metrics.gap + textWidth + metrics.trailing
        return CGSize(width: RCPixelSnap.ceil(width), height: metrics.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let metrics = metrics
        let height = bounds.height
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let dotCenterX = text.isEmpty ? bounds.width / 2 : metrics.leading + metrics.dot / 2
        let center = CGPoint(
            x: RCLayout.pixelAligned(rtl ? bounds.width - dotCenterX : dotCenterX),
            y: RCLayout.pixelAligned(height / 2)
        )
        withoutImplicitAnimations {
            layer.cornerRadius = height / 2
            dot.bounds = CGRect(x: 0, y: 0, width: metrics.dot, height: metrics.dot)
            dot.cornerRadius = metrics.dot / 2
            dot.position = center
            ring.position = center
        }
        spinner.diameter = metrics.spinner
        spinner.lineWidth = metrics.spinner < 12 ? 1.5 : 2
        spinner.frame = CGRect(x: center.x - metrics.spinner / 2, y: center.y - metrics.spinner / 2, width: metrics.spinner, height: metrics.spinner)

        let textX = metrics.leading + metrics.dot + metrics.gap
        let labelWidth = max(0, bounds.width - textX - metrics.trailing)
        let labelY = RCLayout.pixelAligned((height - metrics.lineHeight) / 2)
        // The clip overhangs the text by the side padding so glyph overhangs never clip at rest.
        let overhang: CGFloat = 3
        let previousClip = textClip.frame
        textClip.frame = CGRect(x: (rtl ? metrics.trailing : textX) - overhang, y: 0, width: labelWidth + overhang * 2, height: height)
        label.frame = CGRect(x: overhang, y: labelY, width: labelWidth, height: metrics.lineHeight)
        if outgoingLabel.alpha > 0 {
            let width = outgoingLabel.bounds.width
            outgoingLabel.frame = CGRect(x: rtl ? textClip.bounds.width - overhang - width : overhang, y: labelY, width: width, height: metrics.lineHeight)
        }

        animateResizeIfNeeded(previousClip: previousClip)
        laidOutFrame = frame
    }

    /// Springs the pill from its previous frame when the parent applied the
    /// new size without an animation of its own.
    private func animateResizeIfNeeded(previousClip: CGRect) {
        guard CACurrentMediaTime() <= resizeAnimationDeadline, let old = laidOutFrame, old != frame else { return }
        resizeAnimationDeadline = 0
        guard transform.isIdentity, !RCMotion.reduceMotion,
              layer.animationKeys()?.contains(where: { $0.hasPrefix("bounds") }) != true else { return }
        let size = RCMotion.caSpring(keyPath: "bounds.size", spring: RCMotion.snappy)
        size.fromValue = NSValue(cgSize: old.size)
        size.toValue = NSValue(cgSize: bounds.size)
        layer.add(size, forKey: Self.resizeKeys.0)
        let position = RCMotion.caSpring(keyPath: "position", spring: RCMotion.snappy)
        position.fromValue = NSValue(cgPoint: CGPoint(x: old.midX, y: old.midY))
        position.toValue = NSValue(cgPoint: layer.position)
        layer.add(position, forKey: Self.resizeKeys.1)
        // The text clip follows the pill's edges so new text is revealed, not overflowing.
        guard previousClip.width > 0 else { return }
        let clipSize = RCMotion.caSpring(keyPath: "bounds.size", spring: RCMotion.snappy)
        clipSize.fromValue = NSValue(cgSize: previousClip.size)
        clipSize.toValue = NSValue(cgSize: textClip.bounds.size)
        textClip.layer.add(clipSize, forKey: Self.resizeKeys.0)
        let clipPosition = RCMotion.caSpring(keyPath: "position", spring: RCMotion.snappy)
        clipPosition.fromValue = NSValue(cgPoint: CGPoint(x: previousClip.midX, y: previousClip.midY))
        clipPosition.toValue = NSValue(cgPoint: textClip.layer.position)
        textClip.layer.add(clipPosition, forKey: Self.resizeKeys.1)
    }
}

/// Loading placeholder with a shimmer. The highlight band is positioned in
/// window coordinates and phase-aligned to the media clock, so every skeleton
/// on screen shimmers as one sweep. The gradient animates on the render server
/// and only while in a window; under Reduce Motion the block is static.
@MainActor
final class RCSkeletonView: RCView {
    var cornerRadius: CGFloat = RCRadius.sm { didSet { setNeedsLayout() } }

    override class var layerClass: AnyClass { CAGradientLayer.self }

    private var gradient: CAGradientLayer { unsafeDowncast(layer, to: CAGradientLayer.self) }

    private struct ShimmerGeometry: Equatable {
        let originX: CGFloat
        let width: CGFloat
        let span: CGFloat
        let rightToLeft: Bool
    }

    private var shimmerGeometry: ShimmerGeometry?
    private static let shimmerKey = "rc.skeleton.shimmer"
    private static let period: CFTimeInterval = 1.9
    private static let sweepDuration: CFTimeInterval = 1.3

    override func setUp() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        gradient.locations = [0, 0.5, 1]
        // At rest the band sits outside the block, so it shows the base color.
        gradient.startPoint = CGPoint(x: -2, y: 0.5)
        gradient.endPoint = CGPoint(x: -1, y: 0.5)
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    override func updateAppearance() {
        // The sunken token alone nearly vanishes on the canvas; lean toward the
        // hairline so blocks read on both canvas and cards, and sweep a lighter band.
        let dark = traitCollection.userInterfaceStyle == .dark
        let base = RCColor.surfaceSunken.resolved(for: self).rcMixed(with: RCColor.line.resolved(for: self), amount: dark ? 0.45 : 0.6)
        let highlight = base.rcMixed(with: (dark ? RCColor.lineStrong : RCColor.elevated).resolved(for: self), amount: dark ? 0.8 : 0.75)
        gradient.backgroundColor = base.cgColor
        gradient.colors = [base.cgColor, highlight.cgColor, base.cgColor]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitAnimations {
            gradient.cornerRadius = min(cornerRadius, bounds.height / 2)
            gradient.cornerCurve = .continuous
        }
        updateShimmer()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateShimmer()
    }

#if DEBUG
    var hasShimmerAnimation: Bool { gradient.animation(forKey: Self.shimmerKey) != nil }
#endif

    @objc private func reduceMotionChanged() {
        shimmerGeometry = nil
        updateShimmer()
    }

    private func updateShimmer() {
        guard let window, bounds.width > 0, !RCMotion.reduceMotion else {
            gradient.removeAnimation(forKey: Self.shimmerKey)
            shimmerGeometry = nil
            return
        }
        let geometry = ShimmerGeometry(
            originX: convert(CGPoint.zero, to: window).x,
            width: bounds.width,
            span: window.bounds.width,
            rightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft
        )
        guard geometry != shimmerGeometry || gradient.animation(forKey: Self.shimmerKey) == nil else { return }
        shimmerGeometry = geometry

        let band = min(max(geometry.span * 0.5, 140), 320)
        func unit(_ x: CGFloat) -> CGPoint { CGPoint(x: (x - geometry.originX) / geometry.width, y: 0.5) }
        var start = (from: unit(-band), to: unit(geometry.span))
        var end = (from: unit(0), to: unit(geometry.span + band))
        if geometry.rightToLeft {
            start = (start.to, start.from)
            end = (end.to, end.from)
        }
        let startAnimation = CABasicAnimation(keyPath: "startPoint")
        startAnimation.fromValue = NSValue(cgPoint: start.from)
        startAnimation.toValue = NSValue(cgPoint: start.to)
        let endAnimation = CABasicAnimation(keyPath: "endPoint")
        endAnimation.fromValue = NSValue(cgPoint: end.from)
        endAnimation.toValue = NSValue(cgPoint: end.to)
        for animation in [startAnimation, endAnimation] {
            animation.duration = Self.sweepDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }
        let shimmer = CAAnimationGroup()
        shimmer.animations = [startAnimation, endAnimation]
        shimmer.duration = Self.period
        shimmer.repeatCount = .infinity
        shimmer.isRemovedOnCompletion = false
        shimmer.beginTime = RCLayerAnimation.alignedBeginTime(period: Self.period, in: gradient)
        gradient.add(shimmer, forKey: Self.shimmerKey)
    }
}

/// One-pixel divider.
@MainActor
final class RCSeparator: RCView {
    var color: UIColor = RCColor.line { didSet { updateAppearance() } }

    override func setUp() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    override func updateAppearance() {
        layer.backgroundColor = color.cgColor(for: self)
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: RCLayout.hairline) }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: RCLayout.hairline) }
}

// MARK: - Shared layer motion helpers (design-system primitives)

@MainActor
enum RCLayerAnimation {
    /// Sets `value` at `keyPath` without an implicit action; with a positive
    /// `duration`, animates from what is currently on screen, so interrupted
    /// transitions continue from their in-flight value.
    static func set(_ layer: CALayer, _ keyPath: String, to value: Any?, duration: CFTimeInterval, timing: CAMediaTimingFunction = RCMotion.easeOut) {
        let from = duration > 0 ? (layer.presentation() ?? layer).value(forKeyPath: keyPath) : nil
        withoutImplicitAnimations { layer.setValue(value, forKeyPath: keyPath) }
        guard duration > 0 else {
            layer.removeAnimation(forKey: keyPath)
            return
        }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: keyPath)
    }

    /// Begin time, in `layer`'s time space, of the current cycle of a
    /// repeating animation with `period` on the shared media clock. Animations
    /// that use it run in phase no matter when they were added.
    static func alignedBeginTime(period: CFTimeInterval, in layer: CALayer) -> CFTimeInterval {
        let now = CACurrentMediaTime()
        return layer.convertTime(now - fmod(now, period), from: nil)
    }

    /// When layout runs inside a UIKit animation, UIKit has just added a bounds
    /// animation to `reference`. Animates `keyPath` on `layer` from `from` to
    /// `to` with the same timing — a copy of that animation, so duration,
    /// begin time, curve and spring parameters match (e.g. a shadow path that
    /// must track animated bounds). Without a bounds animation but inside an
    /// animation block, uses the inherited duration. Returns false outside
    /// animation blocks (even if an earlier resize is still in flight), where
    /// the caller's instant change stands.
    @discardableResult
    static func follow(boundsAnimationOf reference: CALayer, on layer: CALayer, keyPath: String, from: Any?, to: Any?) -> Bool {
        guard UIView.areAnimationsEnabled, UIView.inheritedAnimationDuration > 0 else { return false }
        let animation: CABasicAnimation
        if let key = reference.animationKeys()?.first(where: { $0.hasPrefix("bounds") }),
           let source = reference.animation(forKey: key) as? CABasicAnimation,
           let copy = source.copy() as? CABasicAnimation {
            animation = copy
            animation.keyPath = keyPath
            animation.isAdditive = false
        } else {
            animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = UIView.inheritedAnimationDuration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }
        animation.fromValue = from
        animation.toValue = to
        animation.fillMode = .backwards
        layer.add(animation, forKey: keyPath)
        return true
    }
}

/// Pixel-grid rounding used by primitive sizing (`RCLayout.pixelAligned` rounds to nearest).
@MainActor
enum RCPixelSnap {
    /// Rounds up to the device pixel grid, for sizes that must fit their content.
    static func ceil(_ value: CGFloat) -> CGFloat {
        let scale = UIScreen.main.scale
        return (value * scale).rounded(.up) / scale
    }
}

private extension UIColor {
    /// Linear sRGB mix of two resolved colors (`amount` 0 = self, 1 = other).
    func rcMixed(with other: UIColor, amount: CGFloat) -> UIColor {
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1), other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return self }
        let t = min(max(amount, 0), 1)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }
}
