import UIKit
import XCTest
@testable import RctlUIKit

/// Components use the AA text tokens where text sits on a soft wash, and
/// continuous indicators honor Reduce Motion.
@MainActor
final class RCAccessibilityFixTests: XCTestCase {
    private var host: PrimitiveTestHost!

    override func setUp() async throws {
        host = PrimitiveTestHost()
    }

    override func tearDown() async throws {
        RCMotion.reduceMotionOverride = nil
        NotificationCenter.default.post(name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        host.tearDown()
        host = nil
    }

    // MARK: Tone text

    func testBadgeToneTextUsesTheAATokens() {
        let expected: [(RCStatusBadge.Tone, UIColor, UIColor)] = [
            (.success, RCColor.successText, RCColor.successSoft),
            (.attention, RCColor.accentText, RCColor.accentSoft),
            (.accent, RCColor.accentText, RCColor.accentSoft),
            (.danger, RCColor.dangerText, RCColor.dangerSoft),
        ]
        for (tone, text, wash) in expected {
            let badge = RCStatusBadge(text: "Online", tone: tone)
            host.add(badge)
            let colors = badge.colorsForTesting
            XCTAssertTrue(colors.text === text, "\(tone) text")
            XCTAssertTrue(colors.dot === text, "\(tone) dot")
            XCTAssertTrue(colors.background === wash, "\(tone) wash is unchanged")
        }
    }

    func testCalloutToneIconsUseTheAATokensAndCopyStaysInk() {
        let expected: [(RCCallout.Tone, UIColor)] = [
            (.accent, RCColor.accentText),
            (.success, RCColor.successText),
            (.danger, RCColor.dangerText),
        ]
        for (tone, icon) in expected {
            let callout = RCCallout(text: "Paired with relay.", icon: .info, tone: tone)
            host.add(callout, frame: CGRect(x: 0, y: 0, width: 320, height: 60))
            XCTAssertTrue(callout.colorsForTesting.icon?.resolvedColor(with: callout.traitCollection) == icon.resolvedColor(with: callout.traitCollection), "\(tone) icon")
            XCTAssertTrue(callout.colorsForTesting.text === RCColor.text, "\(tone) copy")
        }
    }

    func testDestructiveSoftButtonUsesDangerText() {
        let button = RCButton(title: "Remove", variant: .destructiveSoft, size: .medium)
        host.add(button, frame: CGRect(x: 0, y: 0, width: 140, height: 44))
        XCTAssertEqual(button.appearanceForTesting.label, RCColor.dangerText.resolvedColor(with: button.traitCollection))
    }

    // MARK: Reduce Motion

    func testSpinnerTurnsSlowlyWithoutBreathingUnderReduceMotion() {
        let spinner = RCSpinner(diameter: 20, lineWidth: 2)
        host.add(spinner, frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        spinner.startAnimating()
        XCTAssertEqual(spinner.motionForTesting.turnDuration, 0.9)
        XCTAssertTrue(spinner.motionForTesting.breathes)

        RCMotion.reduceMotionOverride = true
        NotificationCenter.default.post(name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        let reduced = spinner.motionForTesting
        XCTAssertGreaterThanOrEqual(reduced.turnDuration ?? 0, 1.8, "a slow turn, not full speed")
        XCTAssertFalse(reduced.breathes, "no length change under Reduce Motion")

        RCMotion.reduceMotionOverride = false
        NotificationCenter.default.post(name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        XCTAssertEqual(spinner.motionForTesting.turnDuration, 0.9)
        XCTAssertTrue(spinner.motionForTesting.breathes)
    }

    func testSpinnerStartedUnderReduceMotionNeverBreathes() {
        RCMotion.reduceMotionOverride = true
        let spinner = RCSpinner(diameter: 16, lineWidth: 2)
        spinner.startAnimating()
        host.add(spinner, frame: CGRect(x: 0, y: 0, width: 16, height: 16))
        XCTAssertEqual(spinner.motionForTesting.turnDuration, 1.8)
        XCTAssertFalse(spinner.motionForTesting.breathes)
    }
}
