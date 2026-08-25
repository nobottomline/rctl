import RctlRealtime
import SwiftUI

struct RemoteVideoRepresentable: UIViewRepresentable {
    let session: RctlRealtimeSession
    let inputEnabled: Bool
    let onTouch: (Int, Int, Double, Double) -> Void

    func makeUIView(context: Context) -> RemoteViewportView {
        let view = RemoteViewportView()
        view.onTouch = onTouch
        view.inputEnabled = inputEnabled
        session.attachVideo(to: view.videoView)
        return view
    }

    func updateUIView(_ uiView: RemoteViewportView, context: Context) {
        uiView.onTouch = onTouch
        uiView.inputEnabled = inputEnabled
        session.attachVideo(to: uiView.videoView)
    }

    static func dismantleUIView(_ uiView: RemoteViewportView, coordinator: Coordinator) {
        uiView.cancelActiveTouches()
        coordinator.session.detachVideo(from: uiView.videoView)
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

@MainActor
final class RemoteViewportView: UIView {
    let videoView = RctlRemoteVideoView()
    var onTouch: ((Int, Int, Double, Double) -> Void)?
    var inputEnabled = false {
        didSet {
            if !inputEnabled { cancelActiveTouches() }
            accessibilityTraits = inputEnabled ? [.allowsDirectInteraction] : [.image]
            accessibilityHint = inputEnabled
                ? "Touches control the remote device"
                : "Select Control to enable remote input"
        }
    }

    private struct ActiveTouch {
        let finger: Int
        var point: CGPoint
        var lastMoveTimestamp: TimeInterval
    }

    private var activeTouches: [ObjectIdentifier: ActiveTouch] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = "Remote screen"
        accessibilityTraits = [.image]
        accessibilityHint = "Select Control to enable remote input"
        videoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard inputEnabled else { return }
        for touch in touches {
            guard let finger = nextFinger() else { continue }
            let point = touch.location(in: videoView)
            guard let normalized = videoView.normalizedRemotePoint(for: point) else { continue }
            activeTouches[ObjectIdentifier(touch)] = ActiveTouch(
                finger: finger,
                point: point,
                lastMoveTimestamp: touch.timestamp
            )
            send(phase: 0, finger: finger, point: normalized)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard inputEnabled else { return }
        for touch in touches {
            let identifier = ObjectIdentifier(touch)
            guard var active = activeTouches[identifier],
                  touch.timestamp - active.lastMoveTimestamp >= 1.0 / 60.0 else { continue }
            let point = touch.location(in: videoView)
            guard let normalized = videoView.normalizedRemotePoint(for: point, clamped: true) else { continue }
            active.point = point
            active.lastMoveTimestamp = touch.timestamp
            activeTouches[identifier] = active
            send(phase: 1, finger: active.finger, point: normalized)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    func cancelActiveTouches() {
        for active in activeTouches.values {
            guard let normalized = videoView.normalizedRemotePoint(for: active.point, clamped: true) else { continue }
            send(phase: 2, finger: active.finger, point: normalized)
        }
        activeTouches.removeAll(keepingCapacity: true)
    }

    private func finish(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let active = activeTouches.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            let point = touch.location(in: videoView)
            let normalized = videoView.normalizedRemotePoint(for: point, clamped: true)
                ?? videoView.normalizedRemotePoint(for: active.point, clamped: true)
            if let normalized {
                send(phase: 2, finger: active.finger, point: normalized)
            }
        }
    }

    private func nextFinger() -> Int? {
        let used = Set(activeTouches.values.map(\.finger))
        return (0...10).first { !used.contains($0) }
    }

    private func send(phase: Int, finger: Int, point: CGPoint) {
        onTouch?(phase, finger, point.x, point.y)
    }
}
