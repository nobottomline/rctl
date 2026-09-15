import RctlRealtime
import UIKit

/// Letterboxed remote video plus direct multitouch input.
///
/// The video path is owned by RctlRealtime: this view only attaches the
/// `RctlRemoteVideoView` to the session while it is in a window and never adds
/// layers above it. Touches map through the video's content geometry and are
/// forwarded only while `inputEnabled` (screen source, Control allowed and
/// selected); disabling input or leaving the window releases every active touch.
@MainActor
final class RemoteViewportView: UIView {
    let videoView = RctlRemoteVideoView()

    /// Session whose video track renders here. Attached while in a window.
    var session: RctlRealtimeSession? {
        didSet {
            guard session !== oldValue else { return }
            if let oldValue { oldValue.detachVideo(from: videoView) }
            if window != nil { session?.attachVideo(to: videoView) }
        }
    }

    var onTouch: ((RemoteTouchEvent) -> Void)?

    var inputEnabled = false {
        didSet {
            guard inputEnabled != oldValue else { return }
            if !inputEnabled { cancelActiveTouches() }
            updateAccessibility()
        }
    }

    private var tracker = RemoteTouchTracker<ObjectIdentifier>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = RCColor.stage
        isOpaque = true
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = "Remote screen"
        addSubview(videoView)
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if videoView.frame != bounds { videoView.frame = bounds }
#if DEBUG
        demoPlaceholder?.frame = bounds
#endif
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            session?.attachVideo(to: videoView)
        } else {
            cancelActiveTouches()
            session?.detachVideo(from: videoView)
        }
    }

    private func updateAccessibility() {
        accessibilityTraits = inputEnabled ? .allowsDirectInteraction : .image
        accessibilityHint = inputEnabled ? "Touches control the remote device" : "Select Control to enable remote input"
    }

    // MARK: Touches

    private var normalize: RemoteTouchTracker<ObjectIdentifier>.Normalizer {
        { [videoView] point, clamped in videoView.normalizedRemotePoint(for: point, clamped: clamped) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard inputEnabled else { return }
        let normalize = normalize
        for touch in touches {
            if let sent = tracker.begin(ObjectIdentifier(touch), at: touch.location(in: videoView), timestamp: touch.timestamp, normalize: normalize) {
                onTouch?(sent)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard inputEnabled else { return }
        let normalize = normalize
        for touch in touches {
            if let sent = tracker.move(ObjectIdentifier(touch), to: touch.location(in: videoView), timestamp: touch.timestamp, normalize: normalize) {
                onTouch?(sent)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        let normalize = normalize
        for touch in touches {
            if let sent = tracker.end(ObjectIdentifier(touch), at: touch.location(in: videoView), normalize: normalize) {
                onTouch?(sent)
            }
        }
    }

    /// Sends a release for every active touch (mode change, detach, teardown).
    func cancelActiveTouches() {
        guard tracker.activeCount > 0 else { return }
        for release in tracker.cancelAll(normalize: normalize) {
            onTouch?(release)
        }
    }

#if DEBUG
    private var demoPlaceholder: UIImageView?

    /// Screenshot mode: a static stand-in for remote video (no session).
    func showDemoPlaceholder(_ image: UIImage) {
        let view = demoPlaceholder ?? UIImageView()
        view.image = image
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = false
        view.frame = bounds
        if view.superview == nil { addSubview(view) }
        demoPlaceholder = view
    }
#endif
}
