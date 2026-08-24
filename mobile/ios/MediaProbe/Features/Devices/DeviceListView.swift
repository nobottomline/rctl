import RctlClient
import SwiftUI

struct DeviceListView: View {
    @ObservedObject var model: ProbeAppModel
    @State private var resetConfirmation = false

    var body: some View {
        NavigationStack {
            List(model.devices) { device in
                NavigationLink {
                    RemoteControlView(appModel: model, device: device)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: device.online ? "ipad.gen2" : "ipad.gen2")
                            .foregroundStyle(device.online ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name)
                                .font(.body.weight(.medium))
                            Text(status(for: device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .disabled(!device.online || !device.compatible)
            }
            .overlay {
                if model.devices.isEmpty, !model.isBusy {
                    VStack(spacing: 8) {
                        Image(systemName: "ipad.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No Devices")
                            .font(.headline)
                        Text("No approved devices are currently available.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(24)
                }
            }
            .navigationTitle("Devices")
            .refreshable { await model.refreshDevices() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) {
                        resetConfirmation = true
                    } label: {
                        Image(systemName: "person.crop.circle.badge.xmark")
                    }
                    .accessibilityLabel("Reset controller")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refreshDevices() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh devices")
                    .disabled(model.isBusy)
                }
            }
            .confirmationDialog(
                "Remove this controller from this iPhone?",
                isPresented: $resetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove Local Profile", role: .destructive) {
                    model.resetProfile()
                }
            } message: {
                Text("This does not revoke the controller in relay admin.")
            }
        }
    }

    private func status(for device: ControllerDevice) -> String {
        if !device.compatible { return device.compatibilityError ?? "Incompatible protocol" }
        if !device.online { return "Offline" }
        if let version = device.daemonVersion { return "Online · rctld \(version)" }
        return "Online"
    }
}
