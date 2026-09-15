import RctlRealtime
import XCTest
@testable import RctlUIKit

/// Hosted editor tests. They use an isolated `UserDefaults` suite and an
/// address that fails validation before any request, so nothing touches the
/// network or stored devices.
@MainActor
final class LocalDeviceEditorSaveTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "rctl.uikit.local-editor.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testModelSaveFailureMapsToModelMessage() async {
        let model = LocalDevicesModel(defaults: defaults)
        do {
            _ = try await model.save(address: "example.com", name: "", editing: nil)
            XCTFail("A hostname must be rejected")
        } catch {
            let failure = LocalDeviceEditorFailure(error: error, address: "example.com", name: "", editingID: nil, devices: model.devices)
            XCTAssertEqual(failure.message, LocalDevicesModel.message(for: error))
            XCTAssertEqual(failure.message, LocalConnectionError.invalidAddress.errorDescription)
            XCTAssertEqual(failure.field, .address)
        }
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertNil(defaults.data(forKey: "rctl.controller.local-devices.v1"), "A failed save stores nothing")
    }

    func testEditorShowsModelMessageAfterFailedSave() async throws {
        let model = LocalDevicesModel(defaults: defaults)
        let environment = AppEnvironment(localDevices: model)
        let editor = LocalDeviceEditorViewController(environment: environment, editing: nil, suggested: nil)
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        editor.view.layoutIfNeeded()

        let addressField = try XCTUnwrap(editor.view.findTextField(identifier: "local-address"))
        addressField.text = "example.com"
        addressField.sendActions(for: .editingChanged)

        editor.submit()
        let pending = try XCTUnwrap(editor.pendingSave, "Submit starts the capability check")
        XCTAssertFalse(editor.allowsInteractivePop, "Back navigation is blocked while a save is pending")
        await pending.value

        XCTAssertNil(editor.pendingSave)
        XCTAssertTrue(editor.allowsInteractivePop)
        let expected = LocalDevicesModel.message(for: LocalConnectionError.invalidAddress)
        XCTAssertEqual(editor.failure?.message, expected)
        XCTAssertEqual(editor.failure?.field, .address)
        XCTAssertTrue(editor.view.containsAccessibleText(expected), "The message is displayed to the user")
        XCTAssertEqual(environment.router.routes, [], "A failed save does not navigate")
    }

    func testEmptyAddressDoesNotSubmit() {
        let environment = AppEnvironment(localDevices: LocalDevicesModel(defaults: defaults))
        let editor = LocalDeviceEditorViewController(environment: environment, editing: nil, suggested: nil)
        editor.loadViewIfNeeded()
        editor.submit()
        XCTAssertNil(editor.pendingSave)
        XCTAssertNil(editor.failure)
    }
}

private extension UIView {
    func findTextField(identifier: String) -> UITextField? {
        if let field = self as? UITextField, field.accessibilityIdentifier == identifier { return field }
        for subview in subviews {
            if let match = subview.findTextField(identifier: identifier) { return match }
        }
        return nil
    }

    func containsAccessibleText(_ text: String) -> Bool {
        if isAccessibilityElement, accessibilityLabel == text, !isHidden { return true }
        return subviews.contains { $0.containsAccessibleText(text) }
    }
}
