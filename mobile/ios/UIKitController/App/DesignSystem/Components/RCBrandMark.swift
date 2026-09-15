import UIKit

/// Product mark: a tablet outline with a touch point and ripple rings on an
/// ink plate, reproducing the app icon (`mobile/ios/Tools/RenderAppIcon.swift`)
/// from vector geometry so it stays crisp from 24 to 64 pt and beyond.
///
/// The mark is brand artwork, identical in every appearance. Geometry is in
/// unit space (0...1 of `side`, top-left origin) and mirrors the icon renderer.
///
/// Performance: the mark is static, so it is rendered once per size, screen
/// scale and appearance into a cached bitmap shown as the view's layer
/// `contents` (one layer, no gradients, masks or shadows to composite). A
/// `pulse()` temporarily splits the touch point and rings into shape layers
/// over a bitmap of the plate and tablet, and merges back when it ends.
@MainActor
final class RCBrandMark: RCView {
    let side: CGFloat

    /// Unit-space geometry shared with the icon renderer.
    enum Geometry {
        /// iOS app icon mask radius relative to the icon side.
        static let plateCornerRadius: CGFloat = 0.2237
        static let tabletRect = CGRect(x: 0.25, y: 0.14, width: 0.50, height: 0.72)
        static let tabletCornerRadius: CGFloat = 0.09
        static let tabletLineWidth: CGFloat = 0.05
        static let touchPoint = CGPoint(x: 0.5, y: 0.53)
        static let innerRing = (radius: CGFloat(0.135), lineWidth: CGFloat(0.036), alpha: CGFloat(0.9))
        static let outerRing = (radius: CGFloat(0.215), lineWidth: CGFloat(0.026), alpha: CGFloat(0.45))
        static let dotRadius: CGFloat = 0.065
        static let coreRadius: CGFloat = 0.026
    }

    /// Duration of the ripple; the shape layers are merged back after it.
    static let pulseDuration: CFTimeInterval = 1.1

    private var appliedArtwork: RCBrandMarkArtwork.Key?
    /// Touch point and rings as live layers, only while a pulse runs.
    private var pulseLayers: RCBrandMarkLayers?
    private var pulseGeneration = 0

    init(side: CGFloat = 32) {
        self.side = side
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
    }

    override func setUp() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        layer.contentsGravity = .resize
    }

    override func updateAppearance() {
        applyArtwork()
    }

    override var intrinsicContentSize: CGSize { CGSize(width: side, height: side) }
    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyArtwork()
        if let pulseLayers {
            withoutImplicitAnimations { pulseLayers.layout(in: bounds) }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyArtwork() // The screen scale may differ.
    }

    /// True while the static bitmap shows the whole mark (no pulse layers).
    var isShowingStaticArtwork: Bool { pulseLayers == nil && layer.contents != nil }

    private var renderScale: CGFloat {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
        return min(max(scale, 1), 4)
    }

    private func applyArtwork() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let key = RCBrandMarkArtwork.Key(
            size: size,
            scale: renderScale,
            isDark: traitCollection.userInterfaceStyle == .dark,
            includesMarks: pulseLayers == nil
        )
        guard key != appliedArtwork else { return }
        appliedArtwork = key
        withoutImplicitAnimations {
            layer.contents = RCBrandMarkArtwork.image(for: key)
            layer.contentsScale = key.scale
        }
    }

    // MARK: Pulse

    /// A single ripple leaving the touch point, as if the mark was just
    /// touched. Runs entirely on the render server; under Reduce Motion the
    /// touch point only brightens briefly.
    func pulse() {
        guard min(bounds.width, bounds.height) > 0 else { return }
        let parts = beginPulse()
        pulseGeneration += 1
        let generation = pulseGeneration
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.endPulse(generation: generation) }
        }
        if RCMotion.reduceMotion {
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values = [1, 0.55, 1]
            flash.keyTimes = [0, 0.4, 1]
            flash.duration = 0.5
            parts.innerRing.add(flash, forKey: "rc.pulse")
        } else {
            let s = min(bounds.width, bounds.height)
            let expand = CABasicAnimation(keyPath: "transform.scale")
            expand.fromValue = 1
            expand.toValue = Geometry.outerRing.radius * 1.55 / Geometry.innerRing.radius
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.85
            fade.toValue = 0
            let thin = CABasicAnimation(keyPath: "lineWidth")
            thin.fromValue = Geometry.innerRing.lineWidth * s
            thin.toValue = Geometry.outerRing.lineWidth * s * 0.4
            let group = CAAnimationGroup()
            group.animations = [expand, fade, thin]
            group.duration = Self.pulseDuration
            group.timingFunction = RCMotion.easeOut
            parts.ripple.add(group, forKey: "rc.pulse")

            let tap = CAKeyframeAnimation(keyPath: "transform.scale")
            tap.values = [1, 1.22, 1]
            tap.keyTimes = [0, 0.35, 1]
            tap.timingFunctions = [RCMotion.easeOut, CAMediaTimingFunction(name: .easeInEaseOut)]
            tap.duration = 0.42
            parts.dot.add(tap, forKey: "rc.pulse")
        }
        CATransaction.commit()
    }

    /// Swaps the static bitmap for the plate-only bitmap plus live marks.
    private func beginPulse() -> RCBrandMarkLayers {
        if let pulseLayers { return pulseLayers }
        let parts = RCBrandMarkLayers(includesBase: false, includesMarks: true)
        pulseLayers = parts
        withoutImplicitAnimations {
            parts.applyColors(isDark: traitCollection.userInterfaceStyle == .dark)
            parts.layout(in: bounds)
            parts.all.forEach(layer.addSublayer)
        }
        applyArtwork()
        return parts
    }

    private func endPulse(generation: Int) {
        guard generation == pulseGeneration, let parts = pulseLayers else { return }
        pulseLayers = nil
        withoutImplicitAnimations {
            parts.all.forEach { $0.removeFromSuperlayer() }
        }
        applyArtwork()
    }
}

// MARK: - Artwork

/// The mark's layers, built exactly as the artwork is specified. Rendered
/// into bitmaps by `RCBrandMarkArtwork`; the marks part is also used live
/// during a pulse.
@MainActor
final class RCBrandMarkLayers {
    let plate = CAGradientLayer()
    let signalGlow = CAGradientLayer()
    let onlineGlow = CAGradientLayer()
    let screenTint = CAGradientLayer()
    let tablet = CAShapeLayer()
    let outerRing = CAShapeLayer()
    let innerRing = CAShapeLayer()
    /// Pulse ring, invisible at rest.
    let ripple = CAShapeLayer()
    let dot = CAShapeLayer()
    let core = CAShapeLayer()

    let all: [CALayer]

    private typealias Geometry = RCBrandMark.Geometry

    /// Icon artwork colors. Signal, cream and sage are the Warm palette's
    /// `accentHigh`, `onAccent` and `success`; the two deep plate stops exist
    /// only in the icon and are kept here with it.
    private enum Palette {
        static let warmTraits = UITraitCollection(userInterfaceStyle: .light)
        static var signal: UIColor { RCColor.accentHigh.resolvedColor(with: warmTraits) }
        static var cream: UIColor { RCColor.onAccent.resolvedColor(with: warmTraits) }
        static var online: UIColor { RCColor.success.resolvedColor(with: warmTraits) }
        static var ink: UIColor { RCColor.text.resolvedColor(with: warmTraits) }
        static let plateHighlight = UIColor(red: 0.27, green: 0.215, blue: 0.15, alpha: 1)
        static let plateShade = UIColor(red: 0.12, green: 0.095, blue: 0.06, alpha: 1)
    }

    init(includesBase: Bool, includesMarks: Bool) {
        var layers: [CALayer] = []
        if includesBase {
            plate.locations = [0, 0.55, 1]
            plate.startPoint = CGPoint(x: 0, y: 0)
            plate.endPoint = CGPoint(x: 1, y: 1)

            // Radial glows use the plate's own unit space: center, then a point
            // one radius away along each axis.
            signalGlow.type = .radial
            signalGlow.startPoint = CGPoint(x: 0.82, y: 0.18)
            signalGlow.endPoint = CGPoint(x: 0.82 + 0.75, y: 0.18 + 0.75)
            onlineGlow.type = .radial
            onlineGlow.startPoint = CGPoint(x: 0.15, y: 0.88)
            onlineGlow.endPoint = CGPoint(x: 0.15 + 0.6, y: 0.88 + 0.6)

            let tabletRect = Geometry.tabletRect
            screenTint.startPoint = CGPoint(x: (0.3 - tabletRect.minX) / tabletRect.width, y: 0)
            screenTint.endPoint = CGPoint(x: (0.7 - tabletRect.minX) / tabletRect.width, y: 1)

            for gradient in [plate, signalGlow, onlineGlow, screenTint] {
                gradient.masksToBounds = true
            }
            tablet.fillColor = nil
            tablet.shadowColor = UIColor.black.cgColor
            tablet.shadowOpacity = 0.35
            layers += [plate, signalGlow, onlineGlow, screenTint, tablet]
        }
        if includesMarks {
            outerRing.fillColor = nil
            innerRing.fillColor = nil
            ripple.fillColor = nil
            ripple.opacity = 0
            layers += [outerRing, innerRing, ripple, dot, core]
        }
        all = layers
    }

    func applyColors(isDark: Bool) {
        let signal = Palette.signal
        plate.colors = [Palette.plateHighlight.cgColor, Palette.ink.cgColor, Palette.plateShade.cgColor]
        signalGlow.colors = [signal.withAlphaComponent(0.42).cgColor, signal.withAlphaComponent(0).cgColor]
        onlineGlow.colors = [Palette.online.withAlphaComponent(0.16).cgColor, Palette.online.withAlphaComponent(0).cgColor]
        screenTint.colors = [UIColor(white: 1, alpha: 0.10).cgColor, UIColor(white: 1, alpha: 0.02).cgColor]
        tablet.strokeColor = Palette.cream.withAlphaComponent(0.94).cgColor
        outerRing.strokeColor = signal.withAlphaComponent(Geometry.outerRing.alpha).cgColor
        innerRing.strokeColor = signal.withAlphaComponent(Geometry.innerRing.alpha).cgColor
        ripple.strokeColor = signal.cgColor
        dot.fillColor = signal.cgColor
        core.fillColor = Palette.cream.cgColor
        // On the dark console ground the ink plate needs a whisper of an
        // edge to read as a tile; on parchment it stands on its own.
        plate.borderColor = UIColor(white: 1, alpha: isDark ? 0.10 : 0).cgColor
        plate.borderWidth = isDark ? RCLayout.hairline : 0
    }

    func layout(in bounds: CGRect) {
        let s = min(bounds.width, bounds.height)
        guard s > 0 else { return }
        let origin = CGPoint(x: bounds.minX + (bounds.width - s) / 2, y: bounds.minY + (bounds.height - s) / 2)
        let touch = CGPoint(x: origin.x + Geometry.touchPoint.x * s, y: origin.y + Geometry.touchPoint.y * s)
        func unit(_ rect: CGRect) -> CGRect {
            CGRect(x: origin.x + rect.minX * s, y: origin.y + rect.minY * s, width: rect.width * s, height: rect.height * s)
        }
        func circle(_ radius: CGFloat) -> CGPath {
            CGPath(ellipseIn: CGRect(x: touch.x - radius * s, y: touch.y - radius * s, width: radius * s * 2, height: radius * s * 2), transform: nil)
        }

        let plateFrame = CGRect(origin: origin, size: CGSize(width: s, height: s))
        for gradient in [plate, signalGlow, onlineGlow] {
            gradient.frame = plateFrame
            gradient.cornerRadius = s * Geometry.plateCornerRadius
            gradient.cornerCurve = .continuous
        }

        let tabletFrame = unit(Geometry.tabletRect)
        let tabletRadius = Geometry.tabletCornerRadius * s
        screenTint.frame = tabletFrame
        screenTint.cornerRadius = tabletRadius
        let tabletPath = CGPath(roundedRect: tabletFrame, cornerWidth: tabletRadius, cornerHeight: tabletRadius, transform: nil)
        tablet.frame = bounds
        tablet.path = tabletPath
        tablet.lineWidth = Geometry.tabletLineWidth * s
        tablet.shadowPath = tabletPath.copy(strokingWithWidth: tablet.lineWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        tablet.shadowOffset = CGSize(width: 0, height: s * 0.02)
        tablet.shadowRadius = s * 0.03

        for (ring, spec) in [(outerRing, Geometry.outerRing), (innerRing, Geometry.innerRing)] {
            ring.frame = bounds
            ring.path = circle(spec.radius)
            ring.lineWidth = spec.lineWidth * s
        }
        dot.frame = bounds
        dot.path = circle(Geometry.dotRadius)
        core.frame = bounds
        core.path = circle(Geometry.coreRadius)

        // Own frame centered on the touch point so scaling expands from it.
        let radius = Geometry.innerRing.radius * s
        ripple.frame = CGRect(x: touch.x - radius, y: touch.y - radius, width: radius * 2, height: radius * 2)
        ripple.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2), transform: nil)
        ripple.lineWidth = Geometry.innerRing.lineWidth * s
    }
}

/// Cached bitmaps of the mark.
@MainActor
enum RCBrandMarkArtwork {
    struct Key: Hashable {
        var size: CGSize
        var scale: CGFloat
        var isDark: Bool
        /// False renders only the plate and tablet (the ground under a pulse).
        var includesMarks: Bool

        func hash(into hasher: inout Hasher) {
            hasher.combine(size.width)
            hasher.combine(size.height)
            hasher.combine(scale)
            hasher.combine(isDark)
            hasher.combine(includesMarks)
        }

        fileprivate var cacheKey: NSString {
            "\(size.width)x\(size.height)@\(scale)\(isDark ? "d" : "l")\(includesMarks ? "m" : "b")" as NSString
        }
    }

    static let cacheCountLimit = 24

    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.name = "RCBrandMark.artwork"
        cache.countLimit = cacheCountLimit
        return cache
    }()

    static func image(for key: Key) -> CGImage? {
        if let cached = cache.object(forKey: key.cacheKey) { return cached }
        guard let image = render(key) else { return nil }
        cache.setObject(image, forKey: key.cacheKey)
        return image
    }

    /// Renders the artwork layer tree into a bitmap of the key's size and scale.
    static func render(_ key: Key) -> CGImage? {
        guard key.size.width > 0, key.size.height > 0 else { return nil }
        let bounds = CGRect(origin: .zero, size: key.size)
        let parts = RCBrandMarkLayers(includesBase: true, includesMarks: key.includesMarks)
        let container = CALayer()
        container.bounds = bounds
        parts.applyColors(isDark: key.isDark)
        parts.layout(in: bounds)
        parts.all.forEach(container.addSublayer)
        let format = UIGraphicsImageRendererFormat()
        format.scale = key.scale
        format.opaque = false
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: key.size, format: format).image { context in
            container.render(in: context.cgContext)
        }.cgImage
    }
}
