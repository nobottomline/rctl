import SwiftUI

struct ControllerRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: ControllerAppModel
    @StateObject private var localDevices = LocalDevicesModel()

    var body: some View {
        DeviceListView(model: model, localDevices: localDevices)
            .task {
                await model.restore()
            }
            .task(id: presenceIdentity) {
                guard scenePhase == .active, let profile = model.profile else { return }
                await model.maintainPresence(for: profile)
            }
            .alert(
                "Request failed",
                isPresented: Binding(
                    get: { model.presentedError != nil },
                    set: { if !$0 { model.presentedError = nil } }
                ),
                actions: {
                    Button("OK", role: .cancel) {}
                },
                message: {
                    Text(model.presentedError ?? "")
                }
            )
    }

    private var presenceIdentity: PresenceIdentity? {
        guard scenePhase == .active, let profile = model.profile else { return nil }
        return PresenceIdentity(relayID: profile.relayID, origin: profile.origin, controllerID: profile.controller.id)
    }

    private struct PresenceIdentity: Hashable {
        let relayID: String
        let origin: String
        let controllerID: String
    }
}
