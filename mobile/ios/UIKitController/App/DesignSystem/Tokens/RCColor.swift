import UIKit

/// Semantic color tokens. Light values are the web client's `.warm` theme and
/// dark values its operator-console theme (`web/src/index.css`), so the native
/// and browser controllers share one palette. Never hard-code colors in
/// features; add a token here instead.
///
/// Every token is a dynamic `UIColor`. Layers need CGColors, which do not
/// update themselves: resolve them in `RCView.updateAppearance()`
/// (see `UIColor.resolved(for:)`).
///
/// Contrast (WCAG 2.x AA, verified by `Tests/Tokens/RCColorContrastTests`):
/// fills and grounds are the web values. Text tokens meet 4.5:1 on every
/// ground they are used on; where the web's tone color is too light for text
/// on its own soft wash, the native app uses a darker `…Text` variant
/// (`successText`, `accentText`, `dangerText`). Exceptions, documented in the
/// test: `textQuaternary` (placeholders beside a visible caption, disabled
/// items, decoration) and `onAccent` on the Warm terracotta fill, which no
/// label color can bring to 4.5:1; Increase Contrast darkens that fill.
enum RCColor {
    // MARK: Grounds
    /// Page canvas (`--color-bg`).
    static let background = dynamic(light: 0xF3EAD7, dark: 0x0A0B0D)
    /// Deeper canvas used at the top of gradients (`--color-bg-2`).
    static let backgroundDeep = dynamic(light: 0xEEE3CD, dark: 0x0D0F12)
    /// Grouped surfaces and sheets (`--color-surface`).
    static let surface = dynamic(light: 0xFBF5E8, dark: 0x101319)
    /// Sunken wells: segmented tracks, skeletons, icon tiles (`--color-surface-2`).
    static let surfaceSunken = dynamic(light: 0xF1E7D3, dark: 0x161A21)
    /// Cards, menus, dialogs, inputs (`--color-elevated`).
    static let elevated = dynamic(light: 0xFEFAF0, dark: 0x1B2029)

    // MARK: Lines
    /// Hairlines and card borders (`--color-line`).
    static let line = dynamic(light: 0xE6D9BF, dark: 0x232932)
    /// Control borders and emphasized dividers (`--color-line-2`).
    static let lineStrong = dynamic(light: 0xD9C7A7, dark: 0x2C333E)

    // MARK: Text
    /// Primary text and filled primary controls (`--color-fg`).
    static let text = dynamic(light: 0x2D2417, dark: 0xE9EBEF)
    /// Secondary text (`--color-fg-dim`).
    static let textSecondary = dynamic(light: 0x574A37, dark: 0xAAB1BD)
    /// Tertiary text, captions, inactive icons (`--color-muted`, darkened on
    /// Warm / lightened on Console just enough for 4.5:1 on every ground).
    static let textTertiary = dynamic(light: 0x725F48, dark: 0x808895)
    /// Placeholders, disabled glyphs and decoration only (`--color-faint`).
    /// Below 4.5:1 by design: never use it for text a person must read.
    static let textQuaternary = dynamic(light: 0xAD9B7F, dark: 0x4A515C)
    /// Text on a filled `text` (primary) control.
    static let onPrimary = dynamic(light: 0xFEFAF0, dark: 0x0A0B0D)

    // MARK: Accent
    /// Terracotta (warm) / amber (console) signal (`--color-signal`). Fills,
    /// borders and glyphs; for text on `accentSoft` use `accentText`. Under
    /// Increase Contrast the Warm fill darkens so `onAccent` labels reach 4.5:1.
    static let accent = dynamic(light: 0xC25E3A, dark: 0xF6A93B, highContrastLight: 0x9F482A)
    static let accentHigh = dynamic(light: 0xD4734C, dark: 0xFFC163)
    /// Tinted accent wash (`--color-signal-lo`).
    static let accentSoft = dynamic(light: 0xF1DDCA, dark: 0x1C160C)
    static let onAccent = dynamic(light: 0xFDF6EA, dark: 0x1A1206)
    /// Accent-toned text and glyphs on `accentSoft`, the canvas and cards (native AA variant).
    static let accentText = dynamic(light: 0x9F482A, dark: 0xF6A93B)

    // MARK: Status
    /// Healthy / online (`--color-online`). Dots, rings and glows; for text
    /// and glyphs on `successSoft` use `successText`.
    static let success = dynamic(light: 0x4F9A68, dark: 0x46D39A)
    static let successSoft = dynamic(light: 0xDCECE0, dark: 0x0E2219)
    /// Success-toned text and glyphs on `successSoft`, the canvas and cards (native AA variant).
    static let successText = dynamic(light: 0x387350, dark: 0x46D39A)
    /// Fills and borders; for text use `dangerText`.
    static let danger = dynamic(light: 0xBE4438, dark: 0xFB6F7D)
    static let dangerSoft = dynamic(light: 0xF4D8D2, dark: 0x1F1013)
    static let onDanger = dynamic(light: 0xFFF4F1, dark: 0x1A0A0C)
    /// Danger-toned text and glyphs on `dangerSoft`, the canvas and cards (native AA variant).
    static let dangerText = dynamic(light: 0xAB3D32, dark: 0xFB6F7D)

    // MARK: Effects
    /// Backdrop behind dialogs, sheets and context menus.
    static let scrim = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0, alpha: 0.56)
            : UIColor(rgb: 0x2D2417, alpha: 0.22)
    }
    /// Shadow ink; opacity comes from `RCShadow`.
    static let shadow = dynamic(light: 0x2D2417, dark: 0x000000)
    /// Pressed-state wash for rows and ghost controls.
    static let pressWash = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.06)
            : UIColor(rgb: 0x2D2417, alpha: 0.05)
    }
    /// Keyboard-focus / input ring (accent at low opacity).
    static let focusRing = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(rgb: 0xF6A93B, alpha: 0.28)
            : UIColor(rgb: 0xC25E3A, alpha: 0.20)
    }

    // MARK: Media stage (theme independent)
    /// The remote video stage and camera scanner are always black.
    static let stage = UIColor.black
    static let onStage = UIColor.white

    private static func dynamic(light: UInt32, dark: UInt32, highContrastLight: UInt32? = nil) -> UIColor {
        let lightColor = UIColor(rgb: light)
        let darkColor = UIColor(rgb: dark)
        guard let highContrastLight else {
            return UIColor { trait in trait.userInterfaceStyle == .dark ? darkColor : lightColor }
        }
        let highContrastColor = UIColor(rgb: highContrastLight)
        return UIColor { trait in
            if trait.userInterfaceStyle == .dark { return darkColor }
            return trait.accessibilityContrast == .high ? highContrastColor : lightColor
        }
    }
}

extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// Resolves a dynamic color for a view or trait environment. Use for
    /// `CALayer` colors, which do not track appearance changes on their own.
    @MainActor
    func resolved(for environment: UITraitEnvironment) -> UIColor {
        resolvedColor(with: environment.traitCollection)
    }

    @MainActor
    func cgColor(for environment: UITraitEnvironment) -> CGColor {
        resolvedColor(with: environment.traitCollection).cgColor
    }
}
