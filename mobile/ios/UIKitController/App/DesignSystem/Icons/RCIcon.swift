import UIKit

/// Lucide stroke icons rendered natively. Geometry lives in `RCIconPaths.generated.swift`.
@MainActor
enum RCIcon {
    /// Edge length of Lucide's square viewBox.
    fileprivate static let viewBoxSize: CGFloat = 24

    /// Bounds of the bitmap caches (decoded RGBA bytes). A 20 pt glyph at 3x
    /// costs about 14 KB, so both hold every icon a screen realistically shows.
    static let imageCacheCountLimit = 256
    static let imageCacheCostLimit = 6 * 1024 * 1024
    static let bitmapCacheCountLimit = 384
    static let bitmapCacheCostLimit = 8 * 1024 * 1024

    private static var paths: [RCIconGlyph: CGPath] = [:]

    private static let images: NSCache<RCIconImageKey, UIImage> = {
        let cache = NSCache<RCIconImageKey, UIImage>()
        cache.name = "RCIcon.images"
        cache.countLimit = imageCacheCountLimit
        cache.totalCostLimit = imageCacheCostLimit
        return cache
    }()

    private static let bitmaps: NSCache<RCIconImageKey, CGImage> = {
        let cache = NSCache<RCIconImageKey, CGImage>()
        cache.name = "RCIcon.bitmaps"
        cache.countLimit = bitmapCacheCountLimit
        cache.totalCostLimit = bitmapCacheCostLimit
        return cache
    }()

    /// Template image (renders with tintColor), stroked with round caps/joins, cached.
    /// `strokeWidth` is in viewBox units (Lucide default 2); the rendered line width is strokeWidth * pointSize / 24.
    static func image(_ glyph: RCIconGlyph, pointSize: CGFloat = 20, strokeWidth: CGFloat = 2) -> UIImage {
        // A zero-sized renderer traps on recent iOS versions, so degenerate sizes clamp to 1 pt.
        let size = pointSize.isFinite ? max(pointSize, 1) : 1
        let lineWidth = sanitizedStrokeWidth(strokeWidth)
        let scale = UIScreen.main.scale
        let key = RCIconImageKey(glyph: glyph, pointSize: size, strokeWidth: lineWidth, scale: scale, color: nil)
        if let cached = images.object(forKey: key) {
            return cached
        }
        let image = render(glyph, pointSize: size, strokeWidth: lineWidth, scale: scale, color: .black)
            .withRenderingMode(.alwaysTemplate)
        images.setObject(image, forKey: key, cost: byteCost(pointSize: size, scale: scale))
        return image
    }

    /// The glyph stroked in `color` at `scale` pixels per point, on a
    /// `pointSize` square with the viewBox origin at its top-left corner;
    /// cached. Same geometry as `path(_:pointSize:)` stroked with
    /// `strokeWidth * pointSize / 24`, round caps and joins (what
    /// `RCIconView` displays at rest). Nil for an empty size.
    static func bitmap(_ glyph: RCIconGlyph, pointSize: CGFloat, strokeWidth: CGFloat, scale: CGFloat, color: RCIconColor) -> CGImage? {
        let size = sanitizedPointSize(pointSize)
        let scale = scale.isFinite ? min(max(scale, 1), 4) : 1
        guard size > 0 else { return nil }
        let lineWidth = sanitizedStrokeWidth(strokeWidth)
        let key = RCIconImageKey(glyph: glyph, pointSize: size, strokeWidth: lineWidth, scale: scale, color: color)
        if let cached = bitmaps.object(forKey: key) {
            return cached
        }
        guard let image = render(glyph, pointSize: size, strokeWidth: lineWidth, scale: scale, color: color.uiColor).cgImage else {
            return nil
        }
        bitmaps.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Cached CGPath in the 24×24 viewBox.
    static func path(_ glyph: RCIconGlyph) -> CGPath {
        if let cached = paths[glyph] {
            return cached
        }
        let made = glyph.makePath()
        paths[glyph] = made
        return made
    }

    /// Path scaled to fit a square of `pointSize`, for CAShapeLayer use.
    static func path(_ glyph: RCIconGlyph, pointSize: CGFloat) -> CGPath {
        path(glyph, pointSize: pointSize, origin: .zero)
    }

    /// Path scaled to `pointSize` with the square's top-left corner at `origin`.
    fileprivate static func path(_ glyph: RCIconGlyph, pointSize: CGFloat, origin: CGPoint) -> CGPath {
        let base = path(glyph)
        let factor = sanitizedPointSize(pointSize) / viewBoxSize
        var transform = CGAffineTransform(a: factor, b: 0, c: 0, d: factor, tx: origin.x, ty: origin.y)
        return base.copy(using: &transform) ?? base
    }

    private static func render(_ glyph: RCIconGlyph, pointSize size: CGFloat, strokeWidth lineWidth: CGFloat, scale: CGFloat, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard // Token colors are sRGB; no extended-range buffer.
        let glyphPath = path(glyph)
        let factor = size / viewBoxSize
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        return renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.scaleBy(x: factor, y: factor)
            context.addPath(glyphPath)
            context.setLineWidth(lineWidth) // viewBox units under the scaled CTM
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(color.cgColor)
            context.strokePath()
        }
    }

    private static func byteCost(pointSize: CGFloat, scale: CGFloat) -> Int {
        let pixels = Int((pointSize * scale).rounded(.up))
        return pixels * pixels * 4
    }

    fileprivate static func sanitizedPointSize(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(value, 0) : 0
    }

    fileprivate static func sanitizedStrokeWidth(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(value, 0) : 0
    }
}

/// A resolved tint as extended sRGB components: the cache identity of a tinted icon bitmap.
struct RCIconColor: Hashable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    /// Nil for colors without RGB components (e.g. pattern colors).
    init?(_ color: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

private final class RCIconImageKey: NSObject {
    let glyph: RCIconGlyph
    let pointSize: CGFloat
    let strokeWidth: CGFloat
    let scale: CGFloat
    let color: RCIconColor?
    private let precomputedHash: Int

    init(glyph: RCIconGlyph, pointSize: CGFloat, strokeWidth: CGFloat, scale: CGFloat, color: RCIconColor?) {
        self.glyph = glyph
        self.pointSize = pointSize
        self.strokeWidth = strokeWidth
        self.scale = scale
        self.color = color
        var hasher = Hasher()
        hasher.combine(glyph)
        hasher.combine(pointSize)
        hasher.combine(strokeWidth)
        hasher.combine(scale)
        hasher.combine(color)
        precomputedHash = hasher.finalize()
        super.init()
    }

    // Explicitly nonisolated so the NSObject overrides also compile under MainActor default isolation.
    nonisolated override var hash: Int {
        precomputedHash
    }

    nonisolated override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? RCIconImageKey else {
            return false
        }
        return glyph == other.glyph && pointSize == other.pointSize && strokeWidth == other.strokeWidth
            && scale == other.scale && color == other.color
    }
}

/// Stroke icon view whose color follows `tintColor` (dynamic colors resolve on trait changes).
///
/// At rest it displays a cached bitmap of the glyph in its resolved tint
/// (`RCIcon.bitmap`), so scaling, rotating or fading the icon (menus,
/// dialogs, toasts, context lifts, spinners) only moves a texture instead of
/// re-rasterizing a path every frame. The vector shape layer draws only
/// while a stroke animation is attached — `drawIn()`, an animated glyph swap,
/// or a `strokeColor`/`path`/`strokeEnd` animation a caller adds to `layer` —
/// or while `strokeEnd` < 1, then hands back to the bitmap.
///
/// `layer` stays a `CAShapeLayer` whose `strokeColor`, `lineWidth` and
/// `strokeEnd` always hold the current values, so callers can read them and
/// animate them as before.
@MainActor
final class RCIconView: UIView {
    private static let ghostLayerName = "rc.icon.ghost"
    private static let glyphInPathKey = "rc.icon.glyphIn.path"
    private static let glyphInColorKey = "rc.icon.glyphIn.strokeColor"
    private static let drawInKey = "rc.icon.drawIn"
    private static let transitionDuration: CFTimeInterval = 0.18
    private static let transitionScale: CGFloat = 0.85
    /// Grace after a stroke animation's expected end before the bitmap returns.
    private static let settleMargin: CFTimeInterval = 0.05

    /// Inputs of the glyph path; rebuilt only when these change. `scale` is
    /// the view's `contentScaleFactor`, which positions the glyph; bitmaps
    /// are rendered at the display scale.
    private struct Geometry: Equatable {
        var glyph: RCIconGlyph?
        var pointSize: CGFloat
        var bounds: CGRect
        var scale: CGFloat
    }

    /// Inputs of the displayed bitmap; re-rendered only when these change.
    private struct BitmapInputs: Equatable {
        var glyph: RCIconGlyph
        var pointSize: CGFloat
        var strokeWidth: CGFloat
        var scale: CGFloat
        var color: RCIconColor
    }

    override class var layerClass: AnyClass {
        RCIconShapeLayer.self
    }

    private var shapeLayer: CAShapeLayer {
        unsafeDowncast(layer, to: CAShapeLayer.self)
    }

    private let bitmapLayer = CALayer()
    private var currentGlyph: RCIconGlyph?
    private var appliedGeometry: Geometry?
    private var currentPath: CGPath?
    private var appliedBitmap: BitmapInputs?
    /// Stroke animations attached to the shape layer, with their expected end (media time).
    private var strokeAnimationEnds: [String: CFTimeInterval] = [:]
    private var isSettleScheduled = false

    /// True while the cached bitmap is on screen; false while the shape layer draws.
    private(set) var isShowingBitmap = false

#if DEBUG
    /// Bitmap resolution for tests rendering outside a window.
    var testDisplayScale: CGFloat? {
        didSet { updateRendering() }
    }
#endif

    /// Keeps the shape layer drawing even at rest (for callers that animate
    /// the stroke continuously).
    var prefersVectorRendering = false {
        didSet {
            guard prefersVectorRendering != oldValue else { return }
            updateRendering()
        }
    }

    var glyph: RCIconGlyph? {
        get { currentGlyph }
        set { setGlyph(newValue, animated: false) }
    }

    var pointSize: CGFloat {
        didSet {
            guard pointSize != oldValue else { return }
            invalidateIntrinsicContentSize()
            updateLineWidth()
            updatePathIfNeeded()
        }
    }

    var strokeWidth: CGFloat {
        didSet {
            guard strokeWidth != oldValue else { return }
            updateLineWidth()
            updateRendering()
        }
    }

    /// 0...1, for draw-in animations (maps to CAShapeLayer.strokeEnd).
    var strokeEnd: CGFloat {
        get { shapeLayer.strokeEnd }
        set {
            shapeLayer.removeAnimation(forKey: Self.drawInKey)
            let clamped = newValue.isFinite ? min(max(newValue, 0), 1) : 1
            withoutActions { shapeLayer.strokeEnd = clamped }
            updateRendering()
        }
    }

    init(_ glyph: RCIconGlyph? = nil, pointSize: CGFloat = 20, strokeWidth: CGFloat = 2) {
        currentGlyph = glyph
        self.pointSize = pointSize
        self.strokeWidth = strokeWidth
        let side = RCIcon.sanitizedPointSize(pointSize)
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        configure()
    }

    required init?(coder: NSCoder) {
        pointSize = 20
        strokeWidth = 2
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isUserInteractionEnabled = false
        isOpaque = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        withoutActions {
            shapeLayer.fillColor = nil
            shapeLayer.lineCap = .round
            shapeLayer.lineJoin = .round
            bitmapLayer.contentsGravity = .resize
            bitmapLayer.needsDisplayOnBoundsChange = false
            bitmapLayer.isHidden = true
            shapeLayer.addSublayer(bitmapLayer)
        }
        updateLineWidth()
        updateStrokeColor()
        updatePathIfNeeded()
    }

    override var intrinsicContentSize: CGSize {
        let side = RCIcon.sanitizedPointSize(pointSize)
        return CGSize(width: side, height: side)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        intrinsicContentSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updatePathIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePathIfNeeded() // The scale used for pixel snapping may differ.
        updateRendering() // So may the screen scale of the bitmap.
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateStrokeColor()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateStrokeColor()
    }

    /// Crossfades + gently scales between glyphs (≈180 ms). Instant under Reduce Motion.
    func setGlyph(_ glyph: RCIconGlyph?, animated: Bool) {
        guard glyph != currentGlyph else { return }
        let outgoingPath = currentPath
        currentGlyph = glyph
        removeGlyphTransition()
        updatePathIfNeeded()
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else { return }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let timing = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if let outgoingPath {
            let ghost = CAShapeLayer()
            ghost.name = Self.ghostLayerName
            ghost.bounds = shapeLayer.bounds // Same coordinate space as the host layer.
            ghost.position = center
            ghost.contentsScale = shapeLayer.contentsScale
            ghost.fillColor = nil
            ghost.strokeColor = shapeLayer.strokeColor
            ghost.lineWidth = shapeLayer.lineWidth
            ghost.lineCap = .round
            ghost.lineJoin = .round
            ghost.strokeEnd = shapeLayer.strokeEnd
            ghost.path = Self.scaled(outgoingPath, by: Self.transitionScale, around: center)
            ghost.opacity = 0
            CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
            shapeLayer.addSublayer(ghost)

            let shrink = CABasicAnimation(keyPath: "path")
            shrink.fromValue = outgoingPath
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            for animation in [shrink, fade] {
                animation.duration = Self.transitionDuration
                animation.timingFunction = timing
                ghost.add(animation, forKey: animation.keyPath)
            }
        }

        if let incomingPath = currentPath {
            // Scale the geometry rather than the layer so the line width stays constant, and fade the
            // stroke color rather than layer opacity so the outgoing ghost sublayer is unaffected.
            // Adding these switches the host to vector drawing until they finish.
            let grow = CABasicAnimation(keyPath: "path")
            grow.fromValue = Self.scaled(incomingPath, by: Self.transitionScale, around: center)
            grow.duration = Self.transitionDuration
            grow.timingFunction = timing
            shapeLayer.add(grow, forKey: Self.glyphInPathKey)

            if let color = shapeLayer.strokeColor {
                let appear = CABasicAnimation(keyPath: "strokeColor")
                appear.fromValue = color.copy(alpha: 0)
                appear.duration = Self.transitionDuration
                appear.timingFunction = timing
                shapeLayer.add(appear, forKey: Self.glyphInColorKey)
            }
        }
        CATransaction.commit()
    }

    /// Animates strokeEnd 0→1 on the render server (Core Animation), duration default 0.35 s, ease-out.
    func drawIn(duration: CFTimeInterval = 0.35) {
        shapeLayer.removeAnimation(forKey: Self.drawInKey)
        withoutActions { shapeLayer.strokeEnd = 1 }
        // A zero duration would mean Core Animation's default duration, so draw instantly instead.
        guard duration > 0, duration.isFinite else {
            updateRendering()
            return
        }
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        shapeLayer.add(animation, forKey: Self.drawInKey)
    }

    // MARK: - Layer state

    private func updatePathIfNeeded() {
        let scale = contentScaleFactor
        let geometry = Geometry(glyph: currentGlyph, pointSize: pointSize, bounds: bounds, scale: scale)
        guard geometry != appliedGeometry else { return }
        appliedGeometry = geometry

        var newPath: CGPath?
        var glyphFrame = CGRect.zero
        if let glyph = currentGlyph {
            let side = RCIcon.sanitizedPointSize(pointSize)
            let snap = { (value: CGFloat) -> CGFloat in scale > 0 ? (value * scale).rounded() / scale : value }
            let origin = CGPoint(x: snap(bounds.midX - side / 2), y: snap(bounds.midY - side / 2))
            newPath = RCIcon.path(glyph, pointSize: side, origin: origin)
            glyphFrame = CGRect(origin: origin, size: CGSize(width: side, height: side))
        }
        currentPath = newPath
        withoutActions {
            bitmapLayer.frame = glyphFrame
            if !isShowingBitmap { shapeLayer.path = newPath }
        }
        updateRendering()
    }

    private func updateLineWidth() {
        let width = RCIcon.sanitizedStrokeWidth(strokeWidth) * RCIcon.sanitizedPointSize(pointSize) / RCIcon.viewBoxSize
        withoutActions { shapeLayer.lineWidth = width }
    }

    private func updateStrokeColor() {
        let color = tintColor.resolvedColor(with: traitCollection).cgColor
        withoutActions { shapeLayer.strokeColor = color }
        updateRendering()
    }

    /// Shows the bitmap unless something needs the vector shape.
    private func updateRendering() {
        let wantsVector = prefersVectorRendering || shapeLayer.strokeEnd < 1 || !strokeAnimationEnds.isEmpty
        withoutActions {
            if !wantsVector, applyBitmap() {
                if !isShowingBitmap {
                    isShowingBitmap = true
                    shapeLayer.path = nil
                }
                bitmapLayer.isHidden = currentGlyph == nil
            } else {
                if isShowingBitmap || shapeLayer.path !== currentPath {
                    shapeLayer.path = currentPath
                }
                isShowingBitmap = false
                bitmapLayer.isHidden = true
            }
        }
    }

    /// Puts the bitmap for the current inputs into the bitmap layer (cached).
    /// False when no bitmap can represent the glyph.
    private func applyBitmap() -> Bool {
        guard let glyph = currentGlyph else { return true }
        guard let color = RCIconColor(tintColor.resolvedColor(with: traitCollection)) else { return false }
        let scale = displayScale
        let inputs = BitmapInputs(glyph: glyph, pointSize: pointSize, strokeWidth: strokeWidth, scale: scale, color: color)
        guard inputs != appliedBitmap else { return true }
        guard let image = RCIcon.bitmap(glyph, pointSize: pointSize, strokeWidth: strokeWidth, scale: scale, color: color) else {
            return RCIcon.sanitizedPointSize(pointSize) == 0
        }
        bitmapLayer.contents = image
        bitmapLayer.contentsScale = scale
        appliedBitmap = inputs
        return true
    }

    /// Pixels per point of the screen showing the icon. (`contentScaleFactor`
    /// stays 1 for a view that does not draw its own content.)
    private var displayScale: CGFloat {
#if DEBUG
        if let testDisplayScale { return testDisplayScale }
#endif
        if let scale = window?.screen.scale { return scale }
        let trait = traitCollection.displayScale
        return trait > 0 ? trait : UIScreen.main.scale
    }

    // MARK: - Vector hand-off

    /// A stroke animation was attached to the shape layer.
    fileprivate func strokeAnimationAdded(forKey key: String, expectedEnd: CFTimeInterval) {
        holdVectorRendering(forKey: key, until: expectedEnd)
    }

    /// A stroke animation (or, with a nil key, every animation) was removed from the shape layer.
    fileprivate func strokeAnimationRemoved(forKey key: String?) {
        guard !strokeAnimationEnds.isEmpty else { return }
        if let key {
            guard strokeAnimationEnds.removeValue(forKey: key) != nil else { return }
        } else {
            strokeAnimationEnds.removeAll()
        }
        updateRendering()
    }

    private func holdVectorRendering(forKey key: String, until end: CFTimeInterval) {
        strokeAnimationEnds[key] = max(end, strokeAnimationEnds[key] ?? 0)
        updateRendering()
        scheduleSettle()
    }

    private func scheduleSettle() {
        guard !isSettleScheduled, let next = strokeAnimationEnds.values.filter(\.isFinite).min() else { return }
        isSettleScheduled = true
        let delay = max(next - CACurrentMediaTime(), 0) + Self.settleMargin
        perform(#selector(settleVectorRendering), with: nil, afterDelay: delay, inModes: [.common])
    }

    /// Returns to the bitmap once the stroke animations are over. An
    /// animation still attached past its expected end (its transaction
    /// committed late) is checked again shortly.
    @objc private func settleVectorRendering() {
        isSettleScheduled = false
        let now = CACurrentMediaTime()
        for (key, end) in strokeAnimationEnds where end.isFinite && end + Self.settleMargin <= now + 0.001 {
            if shapeLayer.animation(forKey: key) != nil {
                strokeAnimationEnds[key] = now
            } else {
                strokeAnimationEnds.removeValue(forKey: key)
            }
        }
        updateRendering()
        scheduleSettle()
    }

    private func removeGlyphTransition() {
        shapeLayer.removeAnimation(forKey: Self.glyphInPathKey)
        shapeLayer.removeAnimation(forKey: Self.glyphInColorKey)
        let ghosts = shapeLayer.sublayers?.filter { $0.name == Self.ghostLayerName } ?? []
        for ghost in ghosts {
            ghost.removeFromSuperlayer()
        }
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    private static func scaled(_ path: CGPath, by factor: CGFloat, around center: CGPoint) -> CGPath {
        var transform = CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: factor, y: factor)
            .translatedBy(x: -center.x, y: -center.y)
        return path.copy(using: &transform) ?? path
    }
}

/// Host layer of `RCIconView`. Reports stroke animations being attached or
/// removed so the view draws with the shape layer exactly while they run.
final class RCIconShapeLayer: CAShapeLayer {
    private static let strokeKeyPaths: Set<String> = [
        "path", "strokeColor", "strokeStart", "strokeEnd", "lineWidth", "lineDashPhase", "lineDashPattern", "fillColor", "miterLimit",
    ]
    /// Core Animation's duration for an animation that leaves it at 0.
    private static let defaultDuration: CFTimeInterval = 0.25

    override func add(_ anim: CAAnimation, forKey key: String?) {
        super.add(anim, forKey: key)
        guard Thread.isMainThread, Self.affectsStroke(anim) else { return }
        let key = key ?? "rc.icon.anonymous.\(UUID().uuidString)"
        let end = Self.expectedEnd(of: anim, now: CACurrentMediaTime())
        let view = delegate as? RCIconView
        MainActor.assumeIsolated {
            view?.strokeAnimationAdded(forKey: key, expectedEnd: end)
        }
    }

    override func removeAnimation(forKey key: String) {
        super.removeAnimation(forKey: key)
        guard Thread.isMainThread else { return }
        let view = delegate as? RCIconView
        MainActor.assumeIsolated {
            view?.strokeAnimationRemoved(forKey: key)
        }
    }

    override func removeAllAnimations() {
        super.removeAllAnimations()
        guard Thread.isMainThread else { return }
        let view = delegate as? RCIconView
        MainActor.assumeIsolated {
            view?.strokeAnimationRemoved(forKey: nil)
        }
    }

    private static func affectsStroke(_ animation: CAAnimation) -> Bool {
        if let property = animation as? CAPropertyAnimation {
            return property.keyPath.map(strokeKeyPaths.contains) ?? false
        }
        if let group = animation as? CAAnimationGroup {
            return group.animations?.contains(where: affectsStroke) ?? false
        }
        // Transitions redraw the layer's content, which may be the shape.
        return animation is CATransition
    }

    /// When an animation added now should be over (media time); infinite for
    /// animations that repeat forever, are frozen, or stay attached when done.
    private static func expectedEnd(of animation: CAAnimation, now: CFTimeInterval) -> CFTimeInterval {
        guard animation.isRemovedOnCompletion, animation.speed != 0 else { return .infinity }
        let duration = animation.duration > 0 ? animation.duration : defaultDuration
        var active: CFTimeInterval
        if animation.repeatDuration > 0 {
            active = animation.repeatDuration
        } else {
            active = duration * CFTimeInterval(max(animation.repeatCount, 1))
            if animation.autoreverses { active *= 2 }
        }
        guard active.isFinite else { return .infinity }
        let start = animation.beginTime > now ? animation.beginTime : now
        return start + active / CFTimeInterval(abs(animation.speed))
    }
}
