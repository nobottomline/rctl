import RctlClient
import SwiftUI

struct DeviceListView: View {
    private enum Sheet: Identifiable {
        case local(LocalDeviceProfile?)
        case relay
        var id: String {
            switch self {
            case let .local(profile): "local-\(profile?.id.uuidString ?? "new")"
            case .relay: "relay"
            }
        }
    }

    @ObservedObject var model: ControllerAppModel
    @ObservedObject var localDevices: LocalDevicesModel
    @State private var resetConfirmation = false
    @State private var removing: LocalDeviceProfile?
    @State private var sheet: Sheet?
    @State private var path: [LocalDeviceProfile] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Local Network") {
                    ForEach(localDevices.devices) { device in
                        NavigationLink(value: device) {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(device.name)
                                    Text(device.address.displayAddress).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "ipad") }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { removing = device } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            Button { sheet = .local(device) } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                        }
                        .contextMenu {
                            Button { sheet = .local(device) } label: { Label("Edit", systemImage: "pencil") }
                            Button(role: .destructive) { removing = device } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                    Button { sheet = .local(nil) } label: { Label("Add Local Device", systemImage: "plus") }
                        .accessibilityIdentifier("add-local-device")
                }
                Section("Relay") {
                    if model.profile != nil {
                        ForEach(model.devices) { device in
                            NavigationLink {
                                RemoteControlView(appModel: model, device: device)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(device.name)
                                        Text(status(for: device)).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "ipad").foregroundStyle(device.online ? Color.green : .secondary)
                                }
                            }
                            .disabled(!device.online || !device.compatible || !device.supportsNativeControllerSessions)
                        }
                        if model.devices.isEmpty {
                            if model.isBusy { ProgressView() }
                            else { Text("No approved devices").foregroundStyle(.secondary) }
                        }
                    } else {
                        Button { sheet = .relay } label: { Label("Pair Relay", systemImage: "qrcode") }
                    }
                }
            }
            .navigationTitle("Devices")
            .navigationDestination(for: LocalDeviceProfile.self) { device in
                RemoteControlView(appModel: model, localDevice: device, localClient: localDevices.client)
            }
            .refreshable { await model.refreshDevices() }
            .toolbar {
                if model.profile != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) { resetConfirmation = true } label: {
                            Image(systemName: "person.crop.circle.badge.xmark")
                        }
                        .accessibilityLabel("Reset relay controller")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { Task { await model.refreshDevices() } } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Refresh relay devices")
                            .disabled(model.isBusy)
                    }
                }
            }
            .sheet(item: $sheet) { destination in
                switch destination {
                case let .local(editing):
                    LocalDeviceEditor(model: localDevices, editing: editing) { device in path.append(device) }
                case .relay:
                    PairingView(model: model)
                }
            }
            .onChange(of: model.profile) { profile in
                if profile != nil, case .relay = sheet { sheet = nil }
            }
            .confirmationDialog("Remove this controller from this iPhone?", isPresented: $resetConfirmation, titleVisibility: .visible) {
                Button("Remove Relay Profile", role: .destructive) { model.resetProfile() }
            } message: { Text("This does not revoke the controller in relay admin or remove local devices.") }
            .confirmationDialog("Remove saved local device?", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }
            ), titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let removing { localDevices.remove(removing) }
                    removing = nil
                }
            } message: { Text("Only the saved address is removed. The iPad is not changed.") }
            .alert("Local Devices", isPresented: Binding(
                get: { localDevices.errorMessage != nil }, set: { if !$0 { localDevices.errorMessage = nil } }
            )) {
                Button("OK") { localDevices.errorMessage = nil }
            } message: { Text(localDevices.errorMessage ?? "") }
        }
    }

    private func status(for device: ControllerDevice) -> String {
        if !device.compatible { return device.compatibilityError ?? "Incompatible protocol" }
        if !device.online { return "Offline" }
        if !device.supportsNativeControllerSessions { return "Update required" }
        if let version = device.daemonVersion { return "Online · rctld \(version)" }
        return "Online"
    }
}
