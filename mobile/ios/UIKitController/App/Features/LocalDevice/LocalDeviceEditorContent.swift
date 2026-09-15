import Foundation
import RctlRealtime

/// Which flow opened the LAN device editor. Discovery hands in a `suggested`
/// profile whose address answered a preflight moments ago; it is still only a
/// hint, and a saved entry is changed only by an explicit save.
enum LocalDeviceEditorMode: Equatable, Sendable {
    /// Manual entry of a new address.
    case add
    /// A discovered device the user wants to keep.
    case saveDiscovered
    /// Rename or re-address a saved device.
    case edit
    /// Point a saved device at the address discovery found.
    case replaceAddress

    init(editing: LocalDeviceProfile?, suggested: LocalDeviceProfile?) {
        switch (editing, suggested) {
        case (nil, nil): self = .add
        case (nil, .some): self = .saveDiscovered
        case (.some, nil): self = .edit
        case (.some, .some): self = .replaceAddress
        }
    }
}

/// Display values for the editor, derived from the route alone. Free of UIKit
/// so every mode can be unit-tested.
struct LocalDeviceEditorContent: Equatable, Sendable {
    /// What a confirmed address replacement changes, shown before saving.
    struct AddressChange: Equatable, Sendable {
        let deviceName: String
        let discoveredName: String
        let currentAddress: String
        let newAddress: String
    }

    let mode: LocalDeviceEditorMode
    let title: String
    let intro: String
    let actionTitle: String
    let initialAddress: String
    let initialName: String
    /// Trust notice for a device found by discovery (save mode only).
    let discoveryNotice: String?
    /// Present only in replace-address mode.
    let addressChange: AddressChange?

    static let pendingActionTitle = "Checking device…"
    static let trustNotice = "Local access has no authentication. Use it only on a trusted network. Port 8080 is used when none is given."
    static let addressLabel = "Address"
    static let addressPlaceholder = "192.168.1.20:8080"
    static let nameLabel = "Name"
    static let namePlaceholder = "Optional, for example Living room"
    static let addressChangeFootnote = "Nothing is saved until you tap Replace address and connect."

    init(editing: LocalDeviceProfile?, suggested: LocalDeviceProfile?) {
        let mode = LocalDeviceEditorMode(editing: editing, suggested: suggested)
        self.mode = mode
        switch mode {
        case .add:
            title = "Add device"
            actionTitle = "Connect"
        case .saveDiscovered:
            title = "Save device"
            actionTitle = "Save and connect"
        case .edit:
            title = "Edit device"
            actionTitle = "Save and connect"
        case .replaceAddress:
            title = "Update address"
            actionTitle = "Replace address and connect"
        }
        switch mode {
        case .add, .edit:
            intro = "Connect directly over the network you are on. The device needs the rctl package with LAN control enabled."
        case .saveDiscovered:
            intro = "Keep this device for next time. You can rename it; the address stays the one that answered."
        case .replaceAddress:
            intro = "Point a saved device at the address found on the network. Nothing changes until you save."
        }
        initialAddress = suggested?.address.displayAddress ?? editing?.address.displayAddress ?? ""
        initialName = editing?.name ?? suggested?.name ?? ""
        if mode == .saveDiscovered, let suggested {
            discoveryNotice = "Found on this network as “\(suggested.name)”. Discovery does not verify which device answered; use LAN control only on a network you trust."
        } else {
            discoveryNotice = nil
        }
        if mode == .replaceAddress, let editing, let suggested {
            addressChange = AddressChange(
                deviceName: editing.name,
                discoveredName: suggested.name,
                currentAddress: editing.address.displayAddress,
                newAddress: suggested.address.displayAddress
            )
        } else {
            addressChange = nil
        }
    }

    /// The primary action is available once an address is typed and no check is running.
    static func canSubmit(address: String, isPending: Bool) -> Bool {
        !isPending && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A failed save as the editor presents it: the model's user-facing message
/// and, when the failure is about one input, which field to mark.
struct LocalDeviceEditorFailure: Equatable, Sendable {
    enum Field: Equatable, Sendable { case address, name }

    /// Longest name `LocalDevicesModel.save` accepts.
    static let maximumNameLength = 80

    let message: String
    let field: Field?

    /// - Parameters:
    ///   - address/name: the submitted input.
    ///   - editingID: the saved device being edited, if any.
    ///   - devices: saved devices at the time of the failure.
    @MainActor
    init(error: Error, address: String, name: String, editingID: UUID?, devices: [LocalDeviceProfile]) {
        message = LocalDevicesModel.message(for: error)
        field = Self.field(for: error, address: address, name: name, editingID: editingID, devices: devices)
    }

    private static func field(for error: Error, address: String, name: String, editingID: UUID?, devices: [LocalDeviceProfile]) -> Field? {
        switch error {
        case let error as LocalConnectionError:
            switch error {
            case .invalidAddress, .redirect, .invalidResponse, .http: return .address
            case .responseTooLarge, .incompatibleProtocol, .unsupportedMedia: return nil
            }
        case is URLError, is CancellationError:
            // Reachability depends on the network and permissions, not only the address.
            return nil
        default:
            // The model's store validation errors are private to it; derive the
            // field from the same checks `save` performs, in the same order.
            if name.trimmingCharacters(in: .whitespacesAndNewlines).count > maximumNameLength { return .name }
            if let editingID, let parsed = try? LocalDeviceAddress(address),
               devices.contains(where: { $0.address == parsed && $0.id != editingID }) {
                return .address
            }
            return nil
        }
    }
}
