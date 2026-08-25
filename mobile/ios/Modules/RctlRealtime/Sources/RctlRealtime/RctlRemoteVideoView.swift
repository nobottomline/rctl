#if canImport(UIKit)
import UIKit
@preconcurrency import LiveKitWebRTC

public final class RctlRemoteVideoView: UIView {
    private let presentationView: RctlMetalVideoView
    private let renderer: RctlMetalVideoRenderer
    private let frameObserver = FirstFrameRenderer()
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
        firstFrameHandler: (@Sendable () -> Void)? = nil
    ) {
        guard track !== newTrack else {
            frameObserver.updateHandler(firstFrameHandler)
            return
        }
        track?.remove(renderer)
        track?.remove(frameObserver)
        frameObserver.reset(handler: firstFrameHandler)
        track = newTrack
        if newTrack == nil {
            renderer.clear()
        }
        newTrack?.add(renderer)
        newTrack?.add(frameObserver)
    }
}

private final class FirstFrameRenderer: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var reported = false
    private var handler: (@Sendable () -> Void)?

    func reset(handler: (@Sendable () -> Void)?) {
        lock.lock()
        reported = false
        self.handler = handler
        lock.unlock()
    }

    func updateHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard frame != nil else { return }
        lock.lock()
        let callback = reported ? nil : handler
        reported = true
        lock.unlock()
        callback?()
    }
}
#endif
