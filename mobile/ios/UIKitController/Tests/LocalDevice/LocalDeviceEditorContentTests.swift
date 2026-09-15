import RctlRealtime
import XCTest
@testable import RctlUIKit

final class LocalDeviceEditorContentTests: XCTestCase {
    private let savedID = UUID()

    private func saved() throws -> LocalDeviceProfile {
        LocalDeviceProfile(id: savedID, name: "Studio", address: try LocalDeviceAddress("192.168.1.2"))
    }

    private func discovered() throws -> LocalDeviceProfile {
        LocalDeviceProfile(id: UUID(), name: "Kitchen iPad", address: try LocalDeviceAddress("192.168.1.30:8080"))
    }

    func testAddMode() {
        let content = LocalDeviceEditorContent(editing: nil, suggested: nil)
        XCTAssertEqual(content.mode, .add)
        XCTAssertEqual(content.title, "Local device")
        XCTAssertEqual(content.intro, "Connect directly over the network you are on. The device needs the rctl package with LAN control enabled.")
        XCTAssertEqual(content.actionTitle, "Connect")
        XCTAssertEqual(content.initialAddress, "")
        XCTAssertEqual(content.initialName, "")
        XCTAssertNil(content.discoveryNotice)
        XCTAssertNil(content.addressChange)
    }

    func testSaveDiscoveredMode() throws {
        let suggested = try discovered()
        let content = LocalDeviceEditorContent(editing: nil, suggested: suggested)
        XCTAssertEqual(content.mode, .saveDiscovered)
        XCTAssertEqual(content.title, "Save device")
        XCTAssertEqual(content.intro, "Keep this device for next time. You can rename it; the address stays the one that answered.")
        XCTAssertEqual(content.actionTitle, "Save and connect")
        XCTAssertEqual(content.initialAddress, "192.168.1.30:8080")
        XCTAssertEqual(content.initialName, "Kitchen iPad")
        XCTAssertEqual(
            content.discoveryNotice,
            "Found on this network as “Kitchen iPad”. Discovery does not verify which device answered; use LAN control only on a network you trust."
        )
        XCTAssertNil(content.addressChange)
    }

    func testEditMode() throws {
        let editing = try saved()
        let content = LocalDeviceEditorContent(editing: editing, suggested: nil)
        XCTAssertEqual(content.mode, .edit)
        XCTAssertEqual(content.title, "Edit device")
        XCTAssertEqual(content.intro, LocalDeviceEditorContent(editing: nil, suggested: nil).intro)
        XCTAssertEqual(content.actionTitle, "Save and connect")
        XCTAssertEqual(content.initialAddress, "192.168.1.2:8080", "The saved address is shown in canonical display form")
        XCTAssertEqual(content.initialName, "Studio")
        XCTAssertNil(content.discoveryNotice)
        XCTAssertNil(content.addressChange)
    }

    func testReplaceAddressModeKeepsSavedNameAndOffersDiscoveredAddress() throws {
        let editing = try saved()
        let suggested = try discovered()
        let content = LocalDeviceEditorContent(editing: editing, suggested: suggested)
        XCTAssertEqual(content.mode, .replaceAddress)
        XCTAssertEqual(content.title, "Update address")
        XCTAssertEqual(content.intro, "Point a saved device at the address found on the network. Nothing changes until you save.")
        XCTAssertEqual(content.actionTitle, "Replace address and connect")
        XCTAssertEqual(content.initialAddress, "192.168.1.30:8080", "The discovered address is prefilled")
        XCTAssertEqual(content.initialName, "Studio", "The saved name wins over the advertised one")
        XCTAssertNil(content.discoveryNotice)
        XCTAssertEqual(content.addressChange, .init(
            deviceName: "Studio",
            discoveredName: "Kitchen iPad",
            currentAddress: "192.168.1.2:8080",
            newAddress: "192.168.1.30:8080"
        ))
    }

    func testSubmitRequiresAnAddressAndNoPendingCheck() {
        XCTAssertFalse(LocalDeviceEditorContent.canSubmit(address: "", isPending: false))
        XCTAssertFalse(LocalDeviceEditorContent.canSubmit(address: "  \n\t ", isPending: false))
        XCTAssertTrue(LocalDeviceEditorContent.canSubmit(address: "192.168.1.20", isPending: false))
        XCTAssertTrue(LocalDeviceEditorContent.canSubmit(address: " example.com ", isPending: false), "Validation happens on submit, not while typing")
        XCTAssertFalse(LocalDeviceEditorContent.canSubmit(address: "192.168.1.20", isPending: true))
    }

    @MainActor
    func testFailureMarksTheFieldItIsAbout() throws {
        func field(_ error: Error, address: String = "192.168.1.2", name: String = "", editingID: UUID? = nil, devices: [LocalDeviceProfile] = []) -> LocalDeviceEditorFailure.Field? {
            LocalDeviceEditorFailure(error: error, address: address, name: name, editingID: editingID, devices: devices).field
        }
        XCTAssertEqual(field(LocalConnectionError.invalidAddress), .address)
        XCTAssertEqual(field(LocalConnectionError.invalidResponse), .address)
        XCTAssertEqual(field(LocalConnectionError.redirect), .address)
        XCTAssertEqual(field(LocalConnectionError.http(404)), .address)
        XCTAssertNil(field(LocalConnectionError.incompatibleProtocol))
        XCTAssertNil(field(URLError(.timedOut)), "Unreachable devices are not necessarily a wrong address")

        struct StoreError: Error {}
        XCTAssertEqual(field(StoreError(), name: String(repeating: "n", count: 81)), .name)
        let other = LocalDeviceProfile(id: UUID(), name: "Other", address: try LocalDeviceAddress("192.168.1.9"))
        XCTAssertEqual(field(StoreError(), address: "192.168.1.9:8080", editingID: savedID, devices: [try saved(), other]), .address)
        XCTAssertNil(field(StoreError(), address: "192.168.1.9:8080", editingID: nil, devices: [other]), "Adding an existing address updates that entry")
    }
}
