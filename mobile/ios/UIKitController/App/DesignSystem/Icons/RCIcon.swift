import UIKit

/// Lucide stroke icons rendered natively. Geometry lives in `RCIconPaths.generated.swift`.
@MainActor
enum RCIcon {
    /// Edge length of Lucide's square viewBox.
    fileprivate static let viewBoxSize: CGFloat = 24

    private static var paths: [RCIconGlyph: CGPath] = [:]

    private static let images: NSCache<RCIconImageKey, UIImage> = {
        let cache = NSCache<RCIconImageKey, UIImage>()
        cache.name = "RCIcon.images"
        cache.totalCostLimit = 24 * 1024 * 1024 // Decoded RGBA bytes.
        return cache
    }()

    /// Template image (renders with tintColor), stroked with round caps/joins, cached.
    /// `strokeWidth` is in viewBox units (Lucide default 2); the rendered line width is strokeWidth * pointSize / 24.
    static func image(_ glyph: RCIconGlyph, pointSize: CGFloat = 20, strokeWidth: CGFloat = 2) -> UIImage {
        // A zero-sized renderer traps on recent iOS versions, so degenerate sizes clamp to 1 pt.
        let size = pointSize.isFinite ? max(pointSize, 1) : 1
        let lineWidth = sanitizedStrokeWidth(strokeWidth)
        let scale = UIScreen.main.scale
        let key = RCIconImageKey(glyph: glyph, pointSize: size, strokeWidth: lineWidth, scale: scale)
        if let cached = images.object(forKey: key) {
            return cached
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard // A template mask needs no extended-range buffer.
        let glyphPath = path(glyph)
        let factor = size / viewBoxSize
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        let image = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.scaleBy(x: factor, y: factor)
            context.addPath(glyphPath)
            context.setLineWidth(lineWidth) // viewBox units under the scaled CTM
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(UIColor.black.cgColor)
            context.strokePath()
        }.withRenderingMode(.alwaysTemplate)

        let pixels = Int((size * scale).rounded(.up))
        images.setObject(image, forKey: key, cost: pixels * pixels * 4)
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

    fileprivate static func sanitizedPointSize(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(value, 0) : 0
    }

    fileprivate static func sanitizedStrokeWidth(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(value, 0) : 0
    }
}

private final class RCIconImageKey: NSObject {
    let glyph: RCIconGlyph
    let pointSize: CGFloat
    let strokeWidth: CGFloat
    let scale: CGFloat
    private let precomputedHash: Int

    init(glyph: RCIconGlyph, pointSize: CGFloat, strokeWidth: CGFloat, scale: CGFloat) {
        self.glyph = glyph
        self.pointSize = pointSize
        self.strokeWidth = strokeWidth
        self.scale = scale
        var hasher = Hasher()
        hasher.combine(glyph)
        hasher.combine(pointSize)
        hasher.combine(strokeWidth)
        hasher.combine(scale)
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
            && scale == other.scale
    }
}

/// Vector icon view backed by CAShapeLayer; stroke color follows tintColor (resolves dynamic colors on trait changes).
@MainActor
final class RCIconView: UIView {
    private static let ghostLayerName = "rc.icon.ghost"
    private static let glyphInPathKey = "rc.icon.glyphIn.path"
    private static let glyphInColorKey = "rc.icon.glyphIn.strokeColor"
    private static let drawInKey = "rc.icon.drawIn"
    private static let transitionDuration: CFTimeInterval = 0.18
    private static let transitionScale: CGFloat = 0.85

    /// Inputs of the shape layer path; the path is rebuilt only when these change.
    private struct Geometry: Equatable {
        var glyph: RCIconGlyph?
        var pointSize: CGFloat
        var bounds: CGRect
        var scale: CGFloat
    }

    override class var layerClass: AnyClass {
        CAShapeLayer.self
    }

    private var shapeLayer: CAShapeLayer {
        unsafeDowncast(layer, to: CAShapeLayer.self)
    }

    private var currentGlyph: RCIconGlyph?
    private var appliedGeometry: Geometry?

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
        }
    }

    /// 0...1, for draw-in animations (maps to CAShapeLayer.strokeEnd).
    var strokeEnd: CGFloat {
        get { shapeLayer.strokeEnd }
        set {
            shapeLayer.removeAnimation(forKey: Self.drawInKey)
            let clamped = newValue.isFinite ? min(max(newValue, 0), 1) : 1
            withoutActions { shapeLayer.strokeEnd = clamped }
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
        updatePathIfNeeded() // The screen scale used for pixel snapping may differ.
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
        let outgoingPath = shapeLayer.path
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

        if let incomingPath = shapeLayer.path {
            // Scale the geometry rather than the layer so the line width stays constant, and fade the
            // stroke color rather than layer opacity so the outgoing ghost sublayer is unaffected.
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
        guard duration > 0, duration.isFinite else { return }
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
        if let glyph = currentGlyph {
            let side = RCIcon.sanitizedPointSize(pointSize)
            let snap = { (value: CGFloat) -> CGFloat in scale > 0 ? (value * scale).rounded() / scale : value }
            let origin = CGPoint(x: snap(bounds.midX - side / 2), y: snap(bounds.midY - side / 2))
            newPath = RCIcon.path(glyph, pointSize: side, origin: origin)
        }
        withoutActions { shapeLayer.path = newPath }
    }

    private func updateLineWidth() {
        let width = RCIcon.sanitizedStrokeWidth(strokeWidth) * RCIcon.sanitizedPointSize(pointSize) / RCIcon.viewBoxSize
        withoutActions { shapeLayer.lineWidth = width }
    }

    private func updateStrokeColor() {
        let color = tintColor.resolvedColor(with: traitCollection).cgColor
        withoutActions { shapeLayer.strokeColor = color }
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
