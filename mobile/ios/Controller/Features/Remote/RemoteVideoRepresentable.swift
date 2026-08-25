import RctlRealtime
import SwiftUI

struct RemoteVideoRepresentable: UIViewRepresentable {
    let session: RctlRealtimeSession

    func makeUIView(context: Context) -> RctlRemoteVideoView {
        let view = RctlRemoteVideoView()
        session.attachVideo(to: view)
        return view
    }

    func updateUIView(_ uiView: RctlRemoteVideoView, context: Context) {
        session.attachVideo(to: uiView)
    }

    static func dismantleUIView(_ uiView: RctlRemoteVideoView, coordinator: Coordinator) {
        coordinator.session.detachVideo(from: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    final class Coordinator {
        let session: RctlRealtimeSession

        init(session: RctlRealtimeSession) {
            self.session = session
        }
    }
}
