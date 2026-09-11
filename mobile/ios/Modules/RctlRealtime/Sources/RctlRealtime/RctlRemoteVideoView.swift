#if canImport(UIKit)
import UIKit
@preconcurrency import LiveKitWebRTC

public final class RctlRemoteVideoView: UIView {
    private let presentationView: RctlMetalVideoView
    private let renderer: RctlMetalVideoRenderer
    private var frameObserver = VideoFrameObserver()
    private var track: LKRTCVideoTrack?

    public override init(frame: CGRect) {
        let presentationView = RctlMetalVideoView(frame: .zero)
        self.presentationView = presentationView
        renderer = RctlMetalVideoRenderer(view: presentationView)
        super.init(frame: frame)
        backgroundColor = .black
        presentationView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(presentationView)
        NSLayoutConstraint.activate([
            presentationView.leadingAnchor.constraint(equalTo: leadingAnchor),
            presentationView.trailingAnchor.constraint(equalTo: trailingAnchor),
            presentationView.topAnchor.constraint(equalTo: topAnchor),
            presentationView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    deinit {
        track?.remove(renderer)
        track?.remove(frameObserver)
        renderer.clear()
    }

    func setTrack(
        _ newTrack: LKRTCVideoTrack?,
        frameHandler: (@Sendable (TimeInterval) -> Void)? = nil
    ) {
        guard track !== newTrack else {
            frameObserver.updateHandler(frameHandler)
            return
        }
        track?.remove(renderer)
        track?.remove(frameObserver)
        // Do not let an in-flight callback from the old track read the new
        // track's handler and incorrectly renew its freshness.
        frameObserver.reset(handler: nil)
        frameObserver = VideoFrameObserver()
        frameObserver.reset(handler: frameHandler)
        track = newTrack
        if newTrack == nil {
            renderer.clear()
        }
        newTrack?.add(renderer)
        newTrack?.add(frameObserver)
    }

    public func normalizedRemotePoint(for point: CGPoint, clamped: Bool = false) -> CGPoint? {
        presentationView.normalizedRemotePoint(for: point, clamped: clamped)
    }

    public func setDeviceOrientation(_ orientation: Int?) {
        presentationView.setDeviceOrientation(orientation)
    }
}

private final class VideoFrameObserver: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var reportedAt: TimeInterval?
    private var handler: (@Sendable (TimeInterval) -> Void)?

    func reset(handler: (@Sendable (TimeInterval) -> Void)?) {
        lock.lock()
        reportedAt = nil
        self.handler = handler
        lock.unlock()
    }

    func updateHandler(_ handler: (@Sendable (TimeInterval) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard frame != nil else { return }
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let callback = reportedAt.map { now - $0 < 0.25 } == true ? nil : handler
        if callback != nil { reportedAt = now }
        lock.unlock()
        callback?(now)
    }
}
#endif
