import XCTest
@testable import RctlUIKit

/// Custom controls only receive `.touchUpInside` from real touches; the design
/// system must not rely on UIKit sending `.primaryActionTriggered` for them.
@MainActor
final class RCControlTapActionTests: XCTestCase {
    func testListRowRespondsToTouchUpInside() {
        let row = RCListRow(content: .init(title: "Kitchen iPad"))
        var taps = 0
        row.haptic = nil
        row.onTap = { taps += 1 }
        row.sendActions(for: .touchUpInside)
        XCTAssertEqual(taps, 1)
    }

    func testListRowRespondsToPrimaryActionForAssistiveActivation() {
        let row = RCListRow(content: .init(title: "Kitchen iPad"))
        var taps = 0
        row.haptic = nil
        row.onTap = { taps += 1 }
        row.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(taps, 1)
    }

    func testButtonsRespondToTouchUpInside() {
        let button = RCButton(title: "Connect")
        let iconButton = RCIconButton(icon: .plus, accessibilityLabel: "Add")
        var taps = 0
        button.haptic = nil
        iconButton.haptic = nil
        button.onTap = { taps += 1 }
        iconButton.onTap = { taps += 1 }
        button.sendActions(for: .touchUpInside)
        iconButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(taps, 2)
    }
}
