import SwiftUI

struct ControllerRootView: View {
    @ObservedObject var model: ControllerAppModel
    @StateObject private var localDevices = LocalDevicesModel()

    var body: some View {
        DeviceListView(model: model, localDevices: localDevices)
        .task {
            await model.restore()
        }
        .alert(
            "Request Failed",
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
}
