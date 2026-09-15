import UIKit

/// Product mark: a tablet outline with a touch point and ripple rings on an
/// ink plate, reproducing the app icon (`mobile/ios/Tools/RenderAppIcon.swift`)
/// with vector layers so it stays crisp from 24 to 64 pt and beyond.
///
/// The mark is brand artwork, identical in every appearance. Geometry is in
/// unit space (0...1 of `side`, top-left origin) and mirrors the icon renderer.
@MainActor
final class RCBrandMark: RCView {
    let side: CGFloat

    private let plate = CAGradientLayer()
    private let signalGlow = CAGradientLayer()
    private let onlineGlow = CAGradientLayer()
    private let screenTint = CAGradientLayer()
    private let tablet = CAShapeLayer()
    private let outerRing = CAShapeLayer()
    private let innerRing = CAShapeLayer()
    private let dot = CAShapeLayer()
    private let core = CAShapeLayer()
    private var ripple: CAShapeLayer?
    private var laidOutSide: CGFloat = 0

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

    init(side: CGFloat = 32) {
        self.side = side
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
    }

    override func setUp() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true

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
        outerRing.fillColor = nil
        innerRing.fillColor = nil
        [plate, signalGlow, onlineGlow, screenTint, tablet, outerRing, innerRing, dot, core].forEach(layer.addSublayer)
    }

    override func updateAppearance() {
        let signal = Palette.signal
        withoutImplicitAnimations {
            plate.colors = [Palette.plateHighlight.cgColor, Palette.ink.cgColor, Palette.plateShade.cgColor]
            signalGlow.colors = [signal.withAlphaComponent(0.42).cgColor, signal.withAlphaComponent(0).cgColor]
            onlineGlow.colors = [Palette.online.withAlphaComponent(0.16).cgColor, Palette.online.withAlphaComponent(0).cgColor]
            screenTint.colors = [UIColor(white: 1, alpha: 0.10).cgColor, UIColor(white: 1, alpha: 0.02).cgColor]
            tablet.strokeColor = Palette.cream.withAlphaComponent(0.94).cgColor
            outerRing.strokeColor = signal.withAlphaComponent(Geometry.outerRing.alpha).cgColor
            innerRing.strokeColor = signal.withAlphaComponent(Geometry.innerRing.alpha).cgColor
            dot.fillColor = signal.cgColor
            core.fillColor = Palette.cream.cgColor
            ripple?.strokeColor = signal.cgColor
            // On the dark console ground the ink plate needs a whisper of an
            // edge to read as a tile; on parchment it stands on its own.
            let dark = traitCollection.userInterfaceStyle == .dark
            plate.borderColor = UIColor(white: 1, alpha: dark ? 0.10 : 0).cgColor
            plate.borderWidth = dark ? RCLayout.hairline : 0
        }
    }

    override var intrinsicContentSize: CGSize { CGSize(width: side, height: side) }
    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = min(bounds.width, bounds.height)
        guard s > 0 else { return }
        let origin = CGPoint(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2)
        guard s != laidOutSide || plate.frame.origin != origin else { return }
        laidOutSide = s

        func unit(_ rect: CGRect) -> CGRect {
            CGRect(x: origin.x + rect.minX * s, y: origin.y + rect.minY * s, width: rect.width * s, height: rect.height * s)
        }
        func circle(_ radius: CGFloat) -> CGPath {
            let c = CGPoint(x: origin.x + Geometry.touchPoint.x * s, y: origin.y + Geometry.touchPoint.y * s)
            return CGPath(ellipseIn: CGRect(x: c.x - radius * s, y: c.y - radius * s, width: radius * s * 2, height: radius * s * 2), transform: nil)
        }

        withoutImplicitAnimations {
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
            layoutRipple(side: s, origin: origin)
        }
    }

    // MARK: Pulse

    /// A single ripple leaving the touch point, as if the mark was just
    /// touched. Runs entirely on the render server; under Reduce Motion the
    /// touch point only brightens briefly.
    func pulse() {
        guard laidOutSide > 0 else { return }
        if RCMotion.reduceMotion {
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values = [1, 0.55, 1]
            flash.keyTimes = [0, 0.4, 1]
            flash.duration = 0.5
            innerRing.add(flash, forKey: "rc.pulse")
            return
        }
        let ripple = ensureRipple()
        let expand = CABasicAnimation(keyPath: "transform.scale")
        expand.fromValue = 1
        expand.toValue = Geometry.outerRing.radius * 1.55 / Geometry.innerRing.radius
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.85
        fade.toValue = 0
        let thin = CABasicAnimation(keyPath: "lineWidth")
        thin.fromValue = Geometry.innerRing.lineWidth * laidOutSide
        thin.toValue = Geometry.outerRing.lineWidth * laidOutSide * 0.4
        let group = CAAnimationGroup()
        group.animations = [expand, fade, thin]
        group.duration = 1.1
        group.timingFunction = RCMotion.easeOut
        ripple.add(group, forKey: "rc.pulse")

        let tap = CAKeyframeAnimation(keyPath: "transform.scale")
        tap.values = [1, 1.22, 1]
        tap.keyTimes = [0, 0.35, 1]
        tap.timingFunctions = [RCMotion.easeOut, CAMediaTimingFunction(name: .easeInEaseOut)]
        tap.duration = 0.42
        dot.add(tap, forKey: "rc.pulse")
    }

    private func ensureRipple() -> CAShapeLayer {
        if let ripple { return ripple }
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.opacity = 0
        layer.strokeColor = Palette.signal.cgColor
        self.layer.insertSublayer(layer, below: dot)
        ripple = layer
        withoutImplicitAnimations {
            layoutRipple(side: laidOutSide, origin: CGPoint(x: (bounds.width - laidOutSide) / 2, y: (bounds.height - laidOutSide) / 2))
        }
        return layer
    }

    private func layoutRipple(side s: CGFloat, origin: CGPoint) {
        guard let ripple else { return }
        // Own frame centered on the touch point so scaling expands from it.
        let radius = Geometry.innerRing.radius * s
        let center = CGPoint(x: origin.x + Geometry.touchPoint.x * s, y: origin.y + Geometry.touchPoint.y * s)
        ripple.frame = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        ripple.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2), transform: nil)
        ripple.lineWidth = Geometry.innerRing.lineWidth * s
    }
}
