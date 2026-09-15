import UIKit

/// Hero of the pairing intro: a QR glyph on an elevated plate with four accent
/// corner brackets. On first appearance the brackets grow out of their corners
/// and settle onto the code, echoing the scanner's lock-on; afterwards the
/// emblem is static (no continuous animation).
@MainActor
final class PairingEmblemView: RCView {
    /// Regular edge length; the geometry scales with the frame.
    static let side: CGFloat = 128
    /// Edge length on short phones.
    static let compactSide: CGFloat = 100
    private static let introKey = "rc.emblem.intro"

    private let ambientShadow = CALayer()
    private let plate = CALayer()
    private let well = CALayer()
    private let glyph = RCIconView(.qrCode, pointSize: 52, strokeWidth: 1.75)
    private var plateRadius: CGFloat { bounds.width * 0.25 }
    private let bracketGroup = CALayer()
    private let brackets: [CAShapeLayer] = ScannerReticlePaths.Corner.allCases.map { _ in CAShapeLayer() }
    private var hasPlayedIntro = false
    private var laidOutBounds: CGRect = .zero

    override func setUp() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        layer.addSublayer(ambientShadow)
        layer.addSublayer(plate)
        well.cornerCurve = .continuous
        plate.addSublayer(well)
        addSubview(glyph)
        for bracket in brackets {
            bracket.fillColor = nil
            bracket.lineCap = .round
            bracket.lineJoin = .round
            // Hidden until the intro draws them (they grow from the corner apex).
            bracket.strokeStart = 0.5
            bracket.strokeEnd = 0.5
            bracketGroup.addSublayer(bracket)
        }
        layer.addSublayer(bracketGroup)
        glyph.layer.opacity = 0.55
    }

    override func updateAppearance() {
        withoutImplicitAnimations {
            plate.backgroundColor = RCColor.elevated.cgColor(for: self)
            plate.borderColor = RCColor.line.cgColor(for: self)
            plate.borderWidth = RCLayout.hairline
            well.backgroundColor = RCColor.surfaceSunken.cgColor(for: self)
            for bracket in brackets {
                bracket.strokeColor = RCColor.accent.cgColor(for: self)
            }
            applyShadows()
        }
        glyph.tintColor = RCColor.text
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != laidOutBounds else { return }
        laidOutBounds = bounds
        let side = bounds.width
        withoutImplicitAnimations {
            ambientShadow.frame = bounds
            plate.frame = bounds
            plate.cornerRadius = plateRadius
            plate.cornerCurve = .continuous
            let wellInset = (side * 0.2).rounded()
            well.frame = bounds.insetBy(dx: wellInset, dy: wellInset)
            well.cornerRadius = side * 0.11
            bracketGroup.frame = bounds
            let bracketInset = (side * 0.11).rounded()
            let bracketRect = bounds.insetBy(dx: bracketInset, dy: bracketInset)
            for (bracket, corner) in zip(brackets, ScannerReticlePaths.Corner.allCases) {
                bracket.frame = bounds
                bracket.lineWidth = max(2.5, side * 0.0234)
                bracket.path = ScannerReticlePaths.bracket(corner, in: bracketRect, cornerRadius: side * 0.156, length: side * 0.14)
            }
            applyShadows()
        }
        glyph.pointSize = (side * 0.406).rounded()
        glyph.frame = bounds
    }

    private func applyShadows() {
        guard bounds.width > 0 else { return }
        let path = UIBezierPath.continuousRoundedRect(bounds, radius: plateRadius).cgPath
        RCShadow.contact.apply(to: plate, path: path, traits: traitCollection)
        RCShadow.card.apply(to: ambientShadow, path: path, traits: traitCollection)
        ambientShadow.shadowRadius = 18
        ambientShadow.shadowOffset = CGSize(width: 0, height: 8)
    }

    /// Draws the brackets in once. Call after the push transition completes.
    func playIntroIfNeeded() {
        guard !hasPlayedIntro else { return }
        hasPlayedIntro = true
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bracket in brackets {
            bracket.strokeStart = 0
            bracket.strokeEnd = 1
        }
        glyph.layer.opacity = 1

        guard !RCMotion.reduceMotion else {
            for layer in brackets + [glyph.layer] {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = layer === glyph.layer ? 0.55 : 0
                fade.toValue = 1
                fade.duration = RCMotion.reducedDuration
                layer.add(fade, forKey: Self.introKey)
            }
            CATransaction.commit()
            return
        }

        // Clockwise stagger from the top-left corner; each bracket grows from its apex.
        for (index, bracket) in brackets.enumerated() {
            let begin = bracket.convertTime(now, from: nil) + 0.05 * Double(index)
            for (keyPath, from, to) in [("strokeStart", 0.5, 0.0), ("strokeEnd", 0.5, 1.0)] {
                let grow = CABasicAnimation(keyPath: keyPath)
                grow.fromValue = from
                grow.toValue = to
                grow.duration = 0.46
                grow.beginTime = begin
                grow.fillMode = .backwards
                grow.timingFunction = RCMotion.easeOut
                bracket.add(grow, forKey: Self.introKey + "." + keyPath)
            }
        }
        // The frame starts slightly wide and closes onto the code.
        let settle = RCMotion.caSpring(keyPath: "transform.scale", spring: RCMotion.Spring(response: 0.55, damping: 0.78))
        settle.fromValue = 1.14
        settle.toValue = 1
        bracketGroup.add(settle, forKey: Self.introKey)

        // The code "comes into focus" as the brackets land.
        let focus = CABasicAnimation(keyPath: "opacity")
        focus.fromValue = 0.55
        focus.toValue = 1
        focus.duration = 0.36
        focus.beginTime = glyph.layer.convertTime(now, from: nil) + 0.22
        focus.fillMode = .backwards
        focus.timingFunction = RCMotion.easeOut
        glyph.layer.add(focus, forKey: Self.introKey)
        CATransaction.commit()
    }
}
