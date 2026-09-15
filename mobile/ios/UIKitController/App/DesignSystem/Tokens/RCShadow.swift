import UIKit

/// Elevation tokens. A shadow is only ever drawn from an explicit
/// `shadowPath` (never from layer contents) so Core Animation can cache it and
/// avoid offscreen passes. Two-layer elevations use a dedicated sublayer for
/// the ambient part (`RCShadowLayer`).
struct RCShadow: Sendable {
    let opacityLight: Float
    let opacityDark: Float
    let radius: CGFloat
    let offset: CGSize

    /// Resting cards and grouped lists: barely there.
    static let card = RCShadow(opacityLight: 0.05, opacityDark: 0.35, radius: 10, offset: CGSize(width: 0, height: 3))
    /// Tight contact shadow paired with `card`.
    static let contact = RCShadow(opacityLight: 0.06, opacityDark: 0.40, radius: 1.5, offset: CGSize(width: 0, height: 1))
    /// Filled buttons.
    static let button = RCShadow(opacityLight: 0.14, opacityDark: 0.45, radius: 8, offset: CGSize(width: 0, height: 4))
    /// Menus, popovers, toasts, lifted context previews.
    static let popover = RCShadow(opacityLight: 0.16, opacityDark: 0.60, radius: 28, offset: CGSize(width: 0, height: 14))
    /// Sheets and dialogs.
    static let modal = RCShadow(opacityLight: 0.18, opacityDark: 0.65, radius: 36, offset: CGSize(width: 0, height: 18))
    /// Floating surfaces over the stage that do not border the video area
    /// (chrome adjacent to video stays opaque and shadowless).
    static let floating = RCShadow(opacityLight: 0.30, opacityDark: 0.55, radius: 22, offset: CGSize(width: 0, height: 10))

    @MainActor
    func apply(to layer: CALayer, path: CGPath, traits: UITraitCollection) {
        layer.shadowColor = RCColor.shadow.resolvedColor(with: traits).cgColor
        layer.shadowOpacity = traits.userInterfaceStyle == .dark ? opacityDark : opacityLight
        layer.shadowRadius = radius
        layer.shadowOffset = offset
        layer.shadowPath = path
    }

    @MainActor
    static func clear(_ layer: CALayer) {
        layer.shadowOpacity = 0
        layer.shadowPath = nil
    }
}
