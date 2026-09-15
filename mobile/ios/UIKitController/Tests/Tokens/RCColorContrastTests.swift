import UIKit
import XCTest
@testable import RctlUIKit

/// WCAG 2.x contrast for every text / ground pairing the design system uses,
/// in Warm (light) and Console (dark).
///
/// Rules:
/// - Text tokens need 4.5:1 (AA for body-size text) on every ground they sit on.
/// - Exceptions, asserted with their real floors:
///   * `textQuaternary` is for placeholders beside an always-visible field
///     caption, disabled items and decoration (WCAG 1.4.3 exempts inactive
///     components and pure decoration). It sits at about 2–2.6:1 and must stay
///     below `textTertiary` so it never reads as content.
///   * `onAccent` on the Warm terracotta fill is 3.9:1; even pure white reaches
///     only 4.2:1, so no label color can fix it without changing the brand fill.
///     Increase Contrast darkens the fill, and that variant must reach 4.5:1.
/// - Grounds and fills are the web palette and must not drift (asserted too).
@MainActor
final class RCColorContrastTests: XCTestCase {
    private enum Appearance: String, CaseIterable {
        case warm, console

        var traits: UITraitCollection {
            UITraitCollection(userInterfaceStyle: self == .warm ? .light : .dark)
        }
    }

    private let grounds: [(String, UIColor)] = [
        ("background", RCColor.background),
        ("backgroundDeep", RCColor.backgroundDeep),
        ("surface", RCColor.surface),
        ("surfaceSunken", RCColor.surfaceSunken),
        ("elevated", RCColor.elevated),
    ]

    // MARK: Math

    private func components(_ color: UIColor, _ traits: UITraitCollection) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a))
        return (r, g, b, a)
    }

    /// Composites a translucent color over an opaque ground.
    private func over(_ top: UIColor, _ ground: UIColor, _ traits: UITraitCollection) -> UIColor {
        let t = components(top, traits)
        let g = components(ground, traits)
        return UIColor(red: t.r * t.a + g.r * (1 - t.a), green: t.g * t.a + g.g * (1 - t.a), blue: t.b * t.a + g.b * (1 - t.a), alpha: 1)
    }

    private func luminance(_ color: UIColor, _ traits: UITraitCollection) -> CGFloat {
        let c = components(color, traits)
        XCTAssertEqual(c.a, 1, accuracy: 0.001, "contrast is only defined for opaque colors")
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    private func contrast(_ foreground: UIColor, _ background: UIColor, _ traits: UITraitCollection) -> CGFloat {
        let a = luminance(foreground, traits)
        let b = luminance(background, traits)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func assertContrast(_ foreground: (String, UIColor), on background: (String, UIColor), atLeast minimum: CGFloat, _ appearance: Appearance, traits: UITraitCollection? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let ratio = contrast(foreground.1, background.1, traits ?? appearance.traits)
        XCTAssertGreaterThanOrEqual(ratio, minimum, "\(appearance): \(foreground.0) on \(background.0) is \(String(format: "%.2f", ratio)):1", file: file, line: line)
    }

    func testContrastMathMatchesTheWCAGReference() {
        let traits = Appearance.warm.traits
        XCTAssertEqual(contrast(.black, .white, traits), 21, accuracy: 0.01)
        XCTAssertEqual(contrast(.white, .white, traits), 1, accuracy: 0.001)
        // Reviewer measurement of the old Warm badge: #4F9A68 on #DCECE0.
        XCTAssertEqual(contrast(UIColor(rgb: 0x4F9A68), UIColor(rgb: 0xDCECE0), traits), 2.78, accuracy: 0.01)
    }

    // MARK: Text tiers

    func testTextTiersMeetAAOnEveryGround() {
        let tiers: [(String, UIColor)] = [
            ("text", RCColor.text),
            ("textSecondary", RCColor.textSecondary),
            ("textTertiary", RCColor.textTertiary),
        ]
        for appearance in Appearance.allCases {
            for tier in tiers {
                for ground in grounds {
                    assertContrast(tier, on: ground, atLeast: 4.5, appearance)
                }
            }
        }
    }

    func testQuaternaryIsAQuietExemptTierBelowTertiary() {
        for appearance in Appearance.allCases {
            for ground in grounds {
                let traits = appearance.traits
                let quaternary = contrast(RCColor.textQuaternary, ground.1, traits)
                XCTAssertGreaterThanOrEqual(quaternary, 2, "\(appearance): textQuaternary on \(ground.0) must stay perceivable")
                XCTAssertLessThan(quaternary, contrast(RCColor.textTertiary, ground.1, traits), "\(appearance): textQuaternary must stay below textTertiary on \(ground.0)")
            }
        }
    }

    // MARK: Tones

    func testToneTextMeetsAAOnItsWashAndOnCanvasAndCards() {
        let tones: [((String, UIColor), (String, UIColor))] = [
            (("successText", RCColor.successText), ("successSoft", RCColor.successSoft)),
            (("accentText", RCColor.accentText), ("accentSoft", RCColor.accentSoft)),
            (("dangerText", RCColor.dangerText), ("dangerSoft", RCColor.dangerSoft)),
        ]
        let cardsAndCanvas: [(String, UIColor)] = [("background", RCColor.background), ("surface", RCColor.surface), ("elevated", RCColor.elevated)]
        for appearance in Appearance.allCases {
            for (text, wash) in tones {
                assertContrast(text, on: wash, atLeast: 4.5, appearance)
                for ground in cardsAndCanvas {
                    assertContrast(text, on: ground, atLeast: 4.5, appearance)
                }
            }
        }
    }

    func testBadgeAndCalloutCopyMeetAA() {
        for appearance in Appearance.allCases {
            // Neutral badge text and callout copy.
            assertContrast(("textSecondary", RCColor.textSecondary), on: ("surfaceSunken", RCColor.surfaceSunken), atLeast: 4.5, appearance)
            assertContrast(("textSecondary", RCColor.textSecondary), on: ("elevated", RCColor.elevated), atLeast: 4.5, appearance)
            // Toned callouts keep ink copy on their wash.
            for wash in [("accentSoft", RCColor.accentSoft), ("successSoft", RCColor.successSoft), ("dangerSoft", RCColor.dangerSoft)] {
                assertContrast(("text", RCColor.text), on: wash, atLeast: 4.5, appearance)
            }
        }
    }

    func testDestructiveMenuRowsStayAAWhenHighlighted() {
        for appearance in Appearance.allCases {
            let traits = appearance.traits
            let highlighted = over(RCColor.pressWash, RCColor.elevated, traits)
            assertContrast(("dangerText", RCColor.dangerText), on: ("elevated + pressWash", highlighted), atLeast: 4.5, appearance)
            assertContrast(("text", RCColor.text), on: ("elevated + pressWash", highlighted), atLeast: 4.5, appearance)
        }
    }

    // MARK: Filled controls

    func testLabelsOnFilledControls() {
        for appearance in Appearance.allCases {
            assertContrast(("onPrimary", RCColor.onPrimary), on: ("text", RCColor.text), atLeast: 4.5, appearance)
            assertContrast(("onDanger", RCColor.onDanger), on: ("danger", RCColor.danger), atLeast: 4.5, appearance)
            // Disabled filled buttons: tertiary label on a sunken fill.
            assertContrast(("textTertiary", RCColor.textTertiary), on: ("surfaceSunken", RCColor.surfaceSunken), atLeast: 4.5, appearance)
        }
        assertContrast(("onAccent", RCColor.onAccent), on: ("accent", RCColor.accent), atLeast: 4.5, .console)
    }

    func testWarmAccentLabelExceptionAndIncreaseContrastVariant() {
        let warm = Appearance.warm
        // Documented exception: the brand fill caps any label below 4.5:1.
        assertContrast(("onAccent", RCColor.onAccent), on: ("accent", RCColor.accent), atLeast: 3, warm)
        XCTAssertLessThan(contrast(.white, RCColor.accent, warm.traits), 4.5, "if this fails the exception is obsolete: raise the assertion above")
        let highContrast = UITraitCollection(traitsFrom: [warm.traits, UITraitCollection(accessibilityContrast: .high)])
        assertContrast(("onAccent", RCColor.onAccent), on: ("accent (Increase Contrast)", RCColor.accent), atLeast: 4.5, warm, traits: highContrast)
    }

    // MARK: Palette stability

    func testGroundsAndFillsKeepTheWebPalette() {
        func hex(_ color: UIColor, _ traits: UITraitCollection) -> UInt32 {
            let c = components(color, traits)
            return (UInt32((c.r * 255).rounded()) << 16) | (UInt32((c.g * 255).rounded()) << 8) | UInt32((c.b * 255).rounded())
        }
        let expected: [(String, UIColor, UInt32, UInt32)] = [
            ("background", RCColor.background, 0xF3EAD7, 0x0A0B0D),
            ("backgroundDeep", RCColor.backgroundDeep, 0xEEE3CD, 0x0D0F12),
            ("surface", RCColor.surface, 0xFBF5E8, 0x101319),
            ("surfaceSunken", RCColor.surfaceSunken, 0xF1E7D3, 0x161A21),
            ("elevated", RCColor.elevated, 0xFEFAF0, 0x1B2029),
            ("accent", RCColor.accent, 0xC25E3A, 0xF6A93B),
            ("accentSoft", RCColor.accentSoft, 0xF1DDCA, 0x1C160C),
            ("success", RCColor.success, 0x4F9A68, 0x46D39A),
            ("successSoft", RCColor.successSoft, 0xDCECE0, 0x0E2219),
            ("danger", RCColor.danger, 0xBE4438, 0xFB6F7D),
            ("dangerSoft", RCColor.dangerSoft, 0xF4D8D2, 0x1F1013),
        ]
        for (name, color, light, dark) in expected {
            XCTAssertEqual(hex(color, Appearance.warm.traits), light, "Warm \(name)")
            XCTAssertEqual(hex(color, Appearance.console.traits), dark, "Console \(name)")
        }
    }
}
