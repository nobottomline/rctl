import XCTest

/// Real-touch smoke tests: taps, long presses, typing and swipes through the
/// system event pipeline, which unit tests cannot exercise. They never contact
/// a relay; the seeded LAN device uses an unroutable private address.
final class RctlUIKitSmokeUITests: XCTestCase {
    /// JSON for one saved local device, passed through the launch argument
    /// domain so no stored data is touched.
    private static let seededDeviceHex = "5b7b226964223a2236463941374437452d314232432d344535462d394138422d304331443245334634413542222c226e616d65223a2253747564696f2069506164222c2261646472657373223a2231302e3235352e3235352e313a38303830227d5d"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ arguments: [String] = [], seedDevice: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var launchArguments = ["--rctl-appearance=warm"] + arguments
        if seedDevice {
            launchArguments += ["-rctl.controller.local-devices.v1", "<\(Self.seededDeviceHex)>"]
        }
        app.launchArguments = launchArguments
        app.launch()
        return app
    }

    @MainActor
    func testAddMenuItemTapOpensLocalEditorAndBackReturns() {
        let app = launch()
        let add = app.buttons["add-device-menu"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let item = app.buttons["Add local device"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Tapping the + button must open its menu")
        item.tap()
        XCTAssertTrue(app.textFields["local-address"].waitForExistence(timeout: 5), "Menu actions must run after dismissal")
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
    }

    @MainActor
    func testFirstRunRowTapOpensPairing() {
        let app = launch()
        let pairRow = app.buttons["pair-relay"].firstMatch
        XCTAssertTrue(pairRow.waitForExistence(timeout: 10))
        pairRow.tap()
        XCTAssertTrue(app.buttons["scan-pairing-code"].waitForExistence(timeout: 5), "List rows must respond to real taps")
    }

    @MainActor
    func testEditorTypingAndSubmitShowsValidationError() {
        let app = launch(["--rctl-route=local"])
        let address = app.textFields["local-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText("example.com")
        let connect = app.buttons["local-connect"]
        XCTAssertTrue(connect.isEnabled)
        connect.tap()
        let error = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", "private IPv4")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5), "Invalid addresses must show the validation message")
    }

    @MainActor
    func testSavedDeviceLongPressShowsContextMenuAndEditOpensEditor() {
        let app = launch(seedDevice: true)
        let row = app.buttons["Studio iPad"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.0)
        let edit = app.buttons["Edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "Long press must lift the context menu")
        edit.tap()
        let name = app.textFields["local-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Studio iPad")
    }

    @MainActor
    func testPullToRefreshKeepsScreenResponsive() {
        let app = launch(seedDevice: true)
        let row = app.buttons["Studio iPad"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 260)))
        XCTAssertTrue(app.buttons["add-device-menu"].waitForExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    @MainActor
    func testRemoteDemoOpensAndClosesSessionControls() {
        let app = launch(["--rctl-route=remote", "--rctl-remote-demo=live"])
        let tools = app.buttons["Session controls"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 10))
        tools.tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "The tools button must present the Session controls sheet")
        done.tap()
        XCTAssertTrue(tools.waitForExistence(timeout: 5))
    }
}
