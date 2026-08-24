import RctlRealtime
import SwiftUI

struct RemoteVideoRepresentable: UIViewRepresentable {
    let session: RctlRealtimeSession

    func makeUIView(context: Context) -> RctlRemoteVideoView {
        let view = RctlRemoteVideoView()
        session.attachVideo(to: view)
        return view
    }

    func updateUIView(_ uiView: RctlRemoteVideoView, context: Context) {}

    static func dismantleUIView(_ uiView: RctlRemoteVideoView, coordinator: ()) {
        // Session ownership belongs to the screen model. It detaches during
        // explicit disconnect so a replaced SwiftUI view cannot stop a new one.
    }
}
