import RctlClient
import RctlRealtime
import SwiftUI

struct RemoteControlView: View {
    @Environment(\.scenePhase) private var scenePhase
    let device: ControllerDevice
    @StateObject private var model: RemoteSessionModel

    init(appModel: ControllerAppModel, device: ControllerDevice) {
        self.device = device
        _model = StateObject(wrappedValue: RemoteSessionModel(appModel: appModel, deviceID: device.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            RemoteVideoRepresentable(session: model.session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .overlay {
                    if !model.videoAvailable {
                        ProgressView()
                            .tint(.white)
                    }
                }

            HStack(spacing: 12) {
                Picker("Media", selection: Binding(
                    get: { model.media },
                    set: { value in Task { await model.selectMedia(value) } }
                )) {
                    Text("Screen").tag(ControllerMediaRole.screen)
                    Text("Camera").tag(ControllerMediaRole.camera)
                }
                .pickerStyle(.segmented)

                Button {
                    model.sendHome()
                } label: {
                    Image(systemName: "circle")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Home")
                .disabled(model.channelStates["control"] != .open || model.media == .camera)

                Button {
                    Task { await model.connect() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Reconnect")
            }
            .padding(12)
            .background(.bar)
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(device.name)
                        .font(.headline)
                    Text(model.state.rawValue.capitalized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await model.connect() }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                Task { await model.resume() }
            case .inactive, .background:
                model.suspend()
            @unknown default:
                model.suspend()
            }
        }
        .onDisappear { model.disconnect() }
        .alert(
            "Session Failed",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.dismissError() } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
