import SwiftUI

struct ProbeRootView: View {
    @ObservedObject var model: ProbeAppModel

    var body: some View {
        Group {
            if model.profile == nil {
                PairingView(model: model)
            } else {
                DeviceListView(model: model)
            }
        }
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
