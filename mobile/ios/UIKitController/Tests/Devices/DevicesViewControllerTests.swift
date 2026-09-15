import RctlRealtime
import XCTest
@testable import RctlUIKit

/// Hosted smoke tests for the Devices screen against disposable stores: the
/// first render builds the expected entry points without touching discovery.
@MainActor
final class DevicesViewControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "rctl.tests.devices.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeScreen() -> (DevicesViewController, LocalDevicesModel) {
        let localDevices = LocalDevicesModel(defaults: defaults)
        let environment = AppEnvironment(
            appModel: ControllerAppModel(profiles: ControllerProfileStore(defaults: defaults)),
            localDevices: localDevices,
            appearance: RCAppearanceStore(defaults: defaults)
        )
        let screen = DevicesViewController(environment: environment)
        screen.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        screen.view.layoutIfNeeded()
        return (screen, localDevices)
    }

    private func visibleView(identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier, !root.isHidden, root.window != nil || root.superview != nil,
           !hasHiddenAncestor(root) { return root }
        for child in root.subviews {
            if let found = visibleView(identifier: identifier, in: child) { return found }
        }
        return nil
    }

    private func hasHiddenAncestor(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate.isHidden || candidate.alpha == 0 { return true }
            current = candidate.superview
        }
        return false
    }

    func testFirstRunOffersDiscoveryPairingAndManualEntry() {
        let (screen, localDevices) = makeScreen()
        XCTAssertNotNil(visibleView(identifier: "find-nearby-devices", in: screen.view))
        XCTAssertNotNil(visibleView(identifier: "pair-relay", in: screen.view))
        XCTAssertNotNil(visibleView(identifier: "add-local-device", in: screen.view))
        XCTAssertNotNil(visibleView(identifier: "add-device-menu", in: screen.view))
        XCTAssertFalse(localDevices.discoveryEnabled, "Loading the screen must not opt into discovery")
    }

    func testSavedDeviceRendersPopulatedLayout() throws {
        let address = try LocalDeviceAddress("192.168.1.20:8080")
        defaults.set(try JSONEncoder().encode([LocalDeviceProfile(id: UUID(), name: "Den", address: address)]),
                     forKey: "rctl.controller.local-devices.v1")
        let (screen, localDevices) = makeScreen()
        XCTAssertEqual(localDevices.devices.count, 1)
        let row = allViews(in: screen.view).first { $0.accessibilityLabel == "Den" && !hasHiddenAncestor($0) }
        XCTAssertNotNil(row, "The saved device renders as a row")
        XCTAssertEqual(row?.accessibilityValue, "192.168.1.20:8080, Saved", "Address and status are spoken, not shown by color alone")
        XCTAssertEqual(row?.accessibilityHint, "Opens remote control")
        XCTAssertNotNil(visibleView(identifier: "add-local-device", in: screen.view))
        XCTAssertNotNil(visibleView(identifier: "find-nearby-devices", in: screen.view))
        // Relay invitation in the populated layout; the first-run Connect group is hidden.
        let pairRows = allViews(in: screen.view).filter { $0.accessibilityIdentifier == "pair-relay" && !hasHiddenAncestor($0) }
        XCTAssertEqual(pairRows.count, 1)
    }

    private func allViews(in root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap(allViews(in:))
    }
}
