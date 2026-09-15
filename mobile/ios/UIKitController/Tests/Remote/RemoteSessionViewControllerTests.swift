import UIKit
import XCTest
@testable import RctlUIKit

@MainActor
final class RemoteSessionViewControllerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "rctl.remote.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func makeEnvironment() -> AppEnvironment {
        AppEnvironment(
            appModel: ControllerAppModel(profiles: ControllerProfileStore(defaults: defaults)),
            localDevices: LocalDevicesModel(defaults: defaults),
            appearance: RCAppearanceStore(defaults: defaults)
        )
    }

    private func subviews<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
        var found: [T] = []
        for subview in view.subviews {
            if let match = subview as? T { found.append(match) }
            found += subviews(of: type, in: subview)
        }
        return found
    }

    func testRelayDeviceMissingAtCreationExplainsAndNeverBuildsASession() {
        let controller = RemoteSessionViewController(environment: makeEnvironment(), target: .relay(deviceID: "gone"))
        XCTAssertEqual(controller.route, .relayControl(deviceID: "gone"))
        controller.loadViewIfNeeded()
        XCTAssertEqual(subviews(of: RCEmptyStateView.self, in: controller.view).count, 1)
        XCTAssertTrue(subviews(of: RemoteViewportView.self, in: controller.view).isEmpty, "No video or input surface without a device")
        XCTAssertTrue(controller.allowsInteractivePop)
    }
}
