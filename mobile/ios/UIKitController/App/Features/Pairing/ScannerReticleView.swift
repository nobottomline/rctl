import UIKit

/// Reticle colors. These are camera-stage signal colors chosen for contrast
/// over arbitrary live video, not theme tokens: they must not change with the
/// appearance setting.
enum ScannerStageColor {
    static let searching = UIColor.white
    static let locked = UIColor(red: 0.42, green: 0.84, blue: 0.58, alpha: 1)
    static let rejected = UIColor(red: 1.0, green: 0.74, blue: 0.38, alpha: 1)

    static func color(for tone: ScannerPresentation.Tone) -> UIColor {
        switch tone {
        case .searching: searching
        case .locked: locked
        case .rejected: rejected
        }
    }
}

/// Dimmed scrim with a rounded window, a faint window outline and four corner
/// brackets that spring from the resting rect onto a detected code, plus the
/// lock badge and the foreign-code caption that travel with the window. While
/// a claim runs the window itself dims so the code reads as "taken". Lives in
/// the stage's full-bleed coordinate space.
///
/// Motion:
/// - Every target change is a `CASpringAnimation` on `path`/`position`
///   starting from the presentation value, so retargeting mid-flight never jumps.
/// - The idle breathing pulse runs on a separate container layer's transform,
///   pivoting on the resting center, and starts only after a running target
///   spring has visually settled. It is added and removed explicitly, so it
///   can never capture or replay a window change.
/// - Breathing is bounded: the container is only as large as the resting
///   window, it is rasterized once while it pulses (never while paths spring)
///   and it stops after a few breaths until the scanner searches again.
@MainActor
final class ScannerReticleView: RCView {
    private static let spring = RCMotion.Spring(response: 0.34, damping: 0.82)
    /// Visual settle time of `spring` (its mathematical settling duration is longer).
    private static let visualSettle: CFTimeInterval = 0.45
    private static let pathKey = "rc.reticle.path"
    private static let positionKey = "rc.reticle.position"
    private static let breatheKey = "rc.reticle.breathe"
    private static let dimKey = "rc.reticle.dim"
    private static let lineWidth: CGFloat = 4.5
    /// One breath is in and out (`breathHalfPeriod` each way).
    static let breathCycles: Float = 3
    static let breathHalfPeriod: CFTimeInterval = 1.7
    static let breathScale: CGFloat = 1.035
    /// Room around the resting window for the stroke, its halo and the pulse.
    private static let breathingPadding: CGFloat = 12

    /// Where the window rests; the breathing pulse pivots on its center.
    var restingRect: CGRect = .zero {
        didSet { if restingRect != oldValue { updateBreathingPivot() } }
    }

    /// Captions stay between these stage y values (below the copy, above the controls).
    var captionLimits: (top: CGFloat, bottom: CGFloat) = (0, .greatestFiniteMagnitude) {
        didSet { if captionLimits != oldValue, let target { placeFollowers(for: target, animated: false) } }
    }

    private(set) var target: CGRect?

    private let scrim = CAShapeLayer()
    private let windowDim = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let bracketGroup = CALayer()
    private let halo = CAShapeLayer()
    private let brackets = CAShapeLayer()
    private let badge = ScannerLockBadgeView()
    private let caption = ScannerCaptionPill(text: "Not a pairing code")

    private var tone: ScannerPresentation.Tone = .searching
    private var isBreathing = false
    private var showsBadge = false
    private var showsCaption = false
    private var dimsWindow = false
    private var springSettlesAt: CFTimeInterval = 0
    /// Invalidates scheduled rasterization changes from an earlier breathing run.
    private var breathGeneration = 0
    private var laidOutBounds: CGRect = .zero
    /// Hidden followers that animate with this update's target change.
    private var revealing: [CALayer] = []

    override func setUp() {
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true

        scrim.fillRule = .evenOdd
        scrim.fillColor = UIColor(white: 0, alpha: 0.48).cgColor
        windowDim.fillColor = UIColor(white: 0, alpha: 0.5).cgColor
        windowDim.opacity = 0
        outline.fillColor = nil
        outline.strokeColor = UIColor(white: 1, alpha: 0.10).cgColor
        outline.lineWidth = 1

        for shape in [halo, brackets] {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
        }
        // A thin dark edge keeps white brackets legible over bright paper or
        // screens without a blurred (offscreen) shadow.
        halo.strokeColor = UIColor(white: 0, alpha: 0.22).cgColor
        halo.lineWidth = Self.lineWidth + 2
        brackets.lineWidth = Self.lineWidth
        brackets.strokeColor = ScannerStageColor.searching.cgColor

        layer.addSublayer(scrim)
        layer.addSublayer(windowDim)
        layer.addSublayer(outline)
        bracketGroup.addSublayer(halo)
        bracketGroup.addSublayer(brackets)
        layer.addSublayer(bracketGroup)

        for follower in [badge, caption] as [UIView] {
            follower.layer.opacity = 0
            addSubview(follower)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Followers re-measure on every layout pass (Dynamic Type changes land here).
        for view in [badge, caption] as [UIView] {
            let size = view.sizeThatFits(bounds.size)
            if view.bounds.size != size { view.bounds.size = size }
        }
        guard bounds != laidOutBounds else { return }
        laidOutBounds = bounds
        withoutImplicitAnimations {
            for shape in [scrim, windowDim, outline] {
                shape.frame = bounds
            }
            updateBreathingPivot()
        }
        if let target {
            setTarget(target, animated: false)
        }
    }

    // MARK: - State

    /// Applies one rendered scanner state. Order matters: the window target is
    /// applied before breathing so a pulse that starts in the same update
    /// waits for the window spring.
    func apply(
        target next: CGRect,
        tone nextTone: ScannerPresentation.Tone,
        showsBadge nextBadge: Bool,
        showsCaption nextCaption: Bool,
        dimsWindow nextDim: Bool,
        breathing: Bool,
        animated: Bool
    ) {
        // Followers appearing in this update start where the window was, so
        // they travel with it instead of popping in at its destination.
        if animated, let previous = target {
            let centers = followerCenters(for: previous)
            withoutImplicitAnimations {
                for (view, reveal, center) in [(badge as UIView, nextBadge && !showsBadge, centers.badge),
                                               (caption, nextCaption && !showsCaption, centers.caption)] where reveal {
                    view.layer.removeAnimation(forKey: Self.positionKey)
                    view.layer.position = center
                    revealing.append(view.layer)
                }
            }
        }
        if ScannerGeometry.shouldRetarget(from: target, to: next) || !animated {
            setTarget(next, animated: animated && target != nil)
        }
        revealing.removeAll()
        setTone(nextTone, animated: animated)
        if nextBadge != showsBadge {
            showsBadge = nextBadge
            setVisible(badge, nextBadge, hiddenScale: 0.4, spring: RCMotion.bouncy, animated: animated)
        }
        if nextCaption != showsCaption {
            showsCaption = nextCaption
            setVisible(caption, nextCaption, hiddenScale: 0.92, spring: RCMotion.standard, animated: animated)
        }
        if nextDim != dimsWindow {
            dimsWindow = nextDim
            setDimmed(nextDim, animated: animated)
        }
        setBreathing(breathing)
    }

    /// Breathes again when capture restarts (screen appears, app returns to the
    /// foreground) if the scanner is still searching and the pulse is not running.
    func resumeMotion() {
        guard isBreathing, bracketGroup.animation(forKey: Self.breatheKey) == nil else { return }
        isBreathing = false
        setBreathing(true)
    }

    private func setTarget(_ rect: CGRect, animated: Bool) {
        target = rect
        let length = ScannerGeometry.bracketLength(forWindowWidth: rect.width)
        let radius = ScannerGeometry.windowCornerRadius
        let bracketPath = ScannerReticlePaths.brackets(in: rect, cornerRadius: radius, length: length)
        let animation = animated ? makeAnimation(keyPath: "path") : nil
        setPath(ScannerReticlePaths.scrim(bounds: bounds, window: rect, cornerRadius: radius), on: scrim, animation: animation)
        setPath(ScannerReticlePaths.roundedRect(rect, cornerRadius: radius), on: outline, animation: animation)
        setPath(bracketPath, on: halo, animation: animation)
        setPath(bracketPath, on: brackets, animation: animation)
        // The dim only springs while it is visible; hidden it just follows.
        setPath(ScannerReticlePaths.roundedRect(rect, cornerRadius: radius), on: windowDim, animation: windowDim.opacity > 0 ? animation : nil)
        if animated {
            springSettlesAt = CACurrentMediaTime() + (RCMotion.reduceMotion ? RCMotion.reducedDuration : Self.visualSettle)
        }
        placeFollowers(for: rect, animated: animated)
    }

    private func followerCenters(for rect: CGRect) -> (badge: CGPoint, caption: CGPoint) {
        let captionY = ScannerGeometry.captionCenterY(
            window: rect,
            captionHeight: caption.bounds.height,
            topLimit: captionLimits.top,
            bottomLimit: captionLimits.bottom
        )
        return (CGPoint(x: rect.midX, y: rect.minY - 30), CGPoint(x: rect.midX, y: captionY))
    }

    private func placeFollowers(for rect: CGRect, animated: Bool) {
        let centers = followerCenters(for: rect)
        move(badge.layer, to: centers.badge, animated: animated)
        move(caption.layer, to: centers.caption, animated: animated)
    }

    private func setDimmed(_ dimmed: Bool, animated: Bool) {
        let from = windowDim.presentation()?.opacity ?? windowDim.opacity
        withoutImplicitAnimations { windowDim.opacity = dimmed ? 1 : 0 }
        guard animated else {
            windowDim.removeAnimation(forKey: Self.dimKey)
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = windowDim.opacity
        fade.duration = dimmed ? 0.24 : 0.16
        fade.timingFunction = dimmed ? RCMotion.easeOut : RCMotion.easeIn
        windowDim.add(fade, forKey: Self.dimKey)
    }

    private func setTone(_ next: ScannerPresentation.Tone, animated: Bool) {
        guard next != tone else { return }
        tone = next
        let color = ScannerStageColor.color(for: next).cgColor
        let from = brackets.presentation()?.strokeColor ?? brackets.strokeColor
        withoutImplicitAnimations { brackets.strokeColor = color }
        guard animated, let from else { return }
        let fade = CABasicAnimation(keyPath: "strokeColor")
        fade.fromValue = from
        fade.toValue = color
        fade.duration = RCMotion.quickDuration
        fade.timingFunction = RCMotion.easeOut
        brackets.add(fade, forKey: "rc.reticle.tone")
    }

    // MARK: - Breathing

    private func setBreathing(_ on: Bool) {
        guard on != isBreathing else { return }
        isBreathing = on
        breathGeneration += 1
        let generation = breathGeneration
        if on {
            let now = CACurrentMediaTime()
            let delay = max(0, springSettlesAt - now)
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 1
            pulse.toValue = Self.breathScale
            pulse.duration = Self.breathHalfPeriod
            pulse.autoreverses = true
            // A few breaths say "looking"; an endless pulse would keep the
            // render server busy for as long as the scanner stays open.
            pulse.repeatCount = Self.breathCycles
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.beginTime = bracketGroup.convertTime(now, from: nil) + delay
            pulse.fillMode = .backwards
            pulse.isRemovedOnCompletion = true
            if #available(iOS 15.0, *) {
                // A 3.5 % scale moves edges by fractions of a point per frame;
                // 20 fps is indistinguishable and halves the composites.
                pulse.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 20)
            }
            bracketGroup.removeAnimation(forKey: Self.breatheKey + ".settle")
            bracketGroup.add(pulse, forKey: Self.breatheKey)
            let total = Self.breathHalfPeriod * 2 * CFTimeInterval(Self.breathCycles)
            // Rasterize only once the paths are still: a springing path would
            // invalidate the cached bitmap every frame.
            schedule(after: delay, generation: generation) { $0.setBreathingRasterized(true) }
            schedule(after: delay + total, generation: generation) { $0.setBreathingRasterized(false) }
        } else {
            setBreathingRasterized(false)
            let current = (bracketGroup.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
            bracketGroup.removeAnimation(forKey: Self.breatheKey)
            guard abs(current - 1) > 0.0005 else { return }
            let settle = CABasicAnimation(keyPath: "transform.scale")
            settle.fromValue = current
            settle.toValue = 1
            settle.duration = 0.25
            settle.timingFunction = RCMotion.easeOut
            bracketGroup.add(settle, forKey: Self.breatheKey + ".settle")
        }
    }

    private func schedule(after delay: CFTimeInterval, generation: Int, _ action: @escaping @MainActor (ScannerReticleView) -> Void) {
        guard delay > 0 else {
            action(self)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.breathGeneration == generation else { return }
                action(self)
            }
        }
    }

    private func setBreathingRasterized(_ rasterized: Bool) {
        guard bracketGroup.shouldRasterize != rasterized else { return }
        withoutImplicitAnimations {
            bracketGroup.shouldRasterize = rasterized
            // Rendered slightly above screen scale so the bitmap stays crisp at the pulse peak.
            bracketGroup.rasterizationScale = (window?.screen.scale ?? UIScreen.main.scale) * Self.breathScale
        }
    }

    /// The group covers the resting window (plus stroke room), centered on it,
    /// so the pulse scales and caches only that area. Its bounds origin equals
    /// its stage position, so the bracket paths keep stage coordinates and can
    /// still spring anywhere on the stage when a code is detected.
    private func updateBreathingPivot() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let resting = restingRect.isEmpty ? CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0) : restingRect
        let area = resting.insetBy(dx: -Self.breathingPadding, dy: -Self.breathingPadding)
        let center = CGPoint(x: area.midX, y: area.midY)
        withoutImplicitAnimations {
            bracketGroup.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bracketGroup.bounds = area
            bracketGroup.position = center
            for shape in [halo, brackets] {
                shape.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                shape.bounds = area
                shape.position = center
            }
        }
    }

#if DEBUG
    var breathingLayerForTesting: CALayer { bracketGroup }
    var bracketsLayerForTesting: CAShapeLayer { brackets }
    var windowDimLayerForTesting: CAShapeLayer { windowDim }
    static var breatheKeyForTesting: String { breatheKey }
#endif

    // MARK: - Animation helpers

    private func makeAnimation(keyPath: String) -> CABasicAnimation {
        if RCMotion.reduceMotion {
            let fade = CABasicAnimation(keyPath: keyPath)
            fade.duration = RCMotion.reducedDuration
            fade.timingFunction = RCMotion.easeOut
            return fade
        }
        return RCMotion.caSpring(keyPath: keyPath, spring: Self.spring)
    }

    private func setPath(_ path: CGPath, on shape: CAShapeLayer, animation: CABasicAnimation?) {
        let from = shape.animation(forKey: Self.pathKey) != nil ? (shape.presentation()?.path ?? shape.path) : shape.path
        withoutImplicitAnimations { shape.path = path }
        guard let animation, let from, let copy = animation.copy() as? CABasicAnimation else {
            shape.removeAnimation(forKey: Self.pathKey)
            return
        }
        copy.fromValue = from
        copy.toValue = path
        shape.add(copy, forKey: Self.pathKey)
    }

    private func move(_ target: CALayer, to point: CGPoint, animated: Bool) {
        let from = target.animation(forKey: Self.positionKey) != nil ? (target.presentation()?.position ?? target.position) : target.position
        withoutImplicitAnimations { target.position = point }
        // A hidden follower snaps so it never flies in from a stale window.
        guard animated, target.opacity > 0 || revealing.contains(where: { $0 === target }), from != point else {
            target.removeAnimation(forKey: Self.positionKey)
            return
        }
        let animation = makeAnimation(keyPath: "position")
        animation.fromValue = NSValue(cgPoint: from)
        animation.toValue = NSValue(cgPoint: point)
        target.add(animation, forKey: Self.positionKey)
    }

    private func setVisible(
        _ view: UIView,
        _ visible: Bool,
        hiddenScale: CGFloat,
        spring: RCMotion.Spring,
        animated: Bool
    ) {
        let layer = view.layer
        let currentOpacity = layer.presentation()?.opacity ?? layer.opacity
        let currentScale = (layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? (visible ? hiddenScale : 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = visible ? 1 : 0
        layer.transform = visible ? CATransform3DIdentity : CATransform3DMakeScale(hiddenScale, hiddenScale, 1)
        if animated {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = currentOpacity
            fade.toValue = visible ? 1 : 0
            fade.duration = visible ? RCMotion.quickDuration : 0.14
            fade.timingFunction = visible ? RCMotion.easeOut : RCMotion.easeIn
            layer.add(fade, forKey: "rc.reticle.fade")
            if !RCMotion.reduceMotion {
                let scale: CABasicAnimation
                if visible {
                    scale = RCMotion.caSpring(keyPath: "transform.scale", spring: spring)
                } else {
                    scale = CABasicAnimation(keyPath: "transform.scale")
                    scale.duration = 0.14
                    scale.timingFunction = RCMotion.easeIn
                }
                scale.fromValue = currentOpacity > 0.01 ? currentScale : hiddenScale
                scale.toValue = visible ? 1 : hiddenScale
                layer.add(scale, forKey: "rc.reticle.scale")
            }
        } else {
            layer.removeAnimation(forKey: "rc.reticle.fade")
            layer.removeAnimation(forKey: "rc.reticle.scale")
        }
        CATransaction.commit()
    }
}

/// Check disc shown above a locked window.
@MainActor
private final class ScannerLockBadgeView: RCView {
    private static let side: CGFloat = 32
    private let disc = CAShapeLayer()
    private let check = RCIconView(.check, pointSize: 18, strokeWidth: 3)

    override func setUp() {
        isUserInteractionEnabled = false
        disc.lineWidth = 2
        layer.addSublayer(disc)
        check.tintColor = RCColor.stage
        addSubview(check)
    }

    override func updateAppearance() {
        withoutImplicitAnimations {
            disc.fillColor = ScannerStageColor.locked.cgColor
            disc.strokeColor = UIColor(white: 0, alpha: 0.35).cgColor
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: Self.side, height: Self.side)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitAnimations {
            disc.frame = bounds
            disc.path = UIBezierPath(ovalIn: bounds.insetBy(dx: -1, dy: -1)).cgPath
        }
        check.frame = bounds
    }
}

/// Amber capsule explaining a rejected code.
@MainActor
private final class ScannerCaptionPill: RCView {
    private static let height: CGFloat = 34
    private let icon = RCIconView(.circleX, pointSize: 16)
    private let label = RCLabel(style: .footnoteStrong, color: ScannerStageColor.rejected)
    private let fill = CAShapeLayer()

    init(text: String) {
        super.init(frame: .zero)
        label.text = text
    }

    override func setUp() {
        isUserInteractionEnabled = false
        fill.fillColor = UIColor(white: 0, alpha: 0.6).cgColor
        fill.strokeColor = ScannerStageColor.rejected.withAlphaComponent(0.4).cgColor
        fill.lineWidth = 1
        layer.addSublayer(fill)
        icon.tintColor = ScannerStageColor.rejected
        addSubview(icon)
        addSubview(label)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: Self.height))
        let height = max(Self.height, ceil(text.height) + 12)
        return CGSize(width: min(size.width - 32, ceil(12 + 16 + 6 + text.width + 14)), height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitAnimations {
            fill.frame = bounds
            fill.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: bounds.height / 2).cgPath
        }
        icon.frame = CGRect(x: 12, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let textSize = label.sizeThatFits(bounds.size)
        label.frame = CGRect(x: 34, y: (bounds.height - textSize.height) / 2, width: max(0, bounds.width - 34 - 14), height: textSize.height)
    }
}
