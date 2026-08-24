#if canImport(UIKit)
import UIKit
@preconcurrency import LiveKitWebRTC

public final class RctlRemoteVideoView: UIView {
    private let renderer = LKRTCMTLVideoView(frame: .zero)
    private var track: LKRTCVideoTrack?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        renderer.translatesAutoresizingMaskIntoConstraints = false
        renderer.videoContentMode = .scaleAspectFit
        addSubview(renderer)
        NSLayoutConstraint.activate([
            renderer.leadingAnchor.constraint(equalTo: leadingAnchor),
            renderer.trailingAnchor.constraint(equalTo: trailingAnchor),
            renderer.topAnchor.constraint(equalTo: topAnchor),
            renderer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    deinit {
        track?.remove(renderer)
    }

    func setTrack(_ newTrack: LKRTCVideoTrack?) {
        guard track !== newTrack else { return }
        track?.remove(renderer)
        track = newTrack
        newTrack?.add(renderer)
    }
}
#endif
