import UIKit

/// Base view for design-system components.
///
/// Subclasses build their hierarchy in `init` and resolve layer colors in
/// `updateAppearance()`, which runs once after `setUp()` and again whenever
/// the color appearance (light/dark, contrast) changes. Text metrics that
/// depend on Dynamic Type go in `updateTypography()`.
///
/// Rules for subclasses (performance):
/// - Never rebuild subviews on state changes; mutate existing views/layers.
/// - Prefer frame layout in `layoutSubviews` + an accurate `sizeThatFits`.
/// - Give every shadow an explicit `shadowPath` (`RCShadow.apply`).
/// - Wrap non-animated layer mutations in `withoutImplicitAnimations`.
@MainActor
class RCView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
        updateAppearance()
        updateTypography()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Build the view hierarchy. Called once from `init`.
    func setUp() {}

    /// Resolve dynamic colors into layers. Called on init and on appearance change.
    func updateAppearance() {}

    /// Refresh fonts after a content size category change.
    func updateTypography() {}

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            withoutImplicitAnimations { updateAppearance() }
        }
        if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory {
            updateTypography()
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }
}

/// Base control for design-system components; same lifecycle as `RCView`.
@MainActor
class RCControl: UIControl {
    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
        updateAppearance()
        updateTypography()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func setUp() {}
    func updateAppearance() {}
    func updateTypography() {}

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            withoutImplicitAnimations { updateAppearance() }
        }
        if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory {
            updateTypography()
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    /// Hit area of at least 44×44 pt regardless of the visual size.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = max(0, (RCLayout.minimumHitTarget - bounds.width) / 2)
        let dy = max(0, (RCLayout.minimumHitTarget - bounds.height) / 2)
        return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
    }
}

@MainActor
func withoutImplicitAnimations(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

extension UIView {
    /// Continuous ("squircle") corners without clipping content.
    func applyCornerRadius(_ radius: CGFloat, maskedCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]) {
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.maskedCorners = maskedCorners
    }

    /// Nearest view controller in the responder chain.
    var owningViewController: UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}

extension UIBezierPath {
    /// Continuous-corner rounded rect path matching `cornerCurve = .continuous`,
    /// for shadow paths and shape layers.
    static func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> UIBezierPath {
        UIBezierPath(roundedRect: rect, cornerRadius: min(radius, min(rect.width, rect.height) / 2))
    }
}
