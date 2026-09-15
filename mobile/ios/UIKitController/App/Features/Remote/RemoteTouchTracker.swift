import CoreGraphics
import Foundation

/// One touch message for `RemoteSessionModel.sendTouch(phase:finger:x:y:)`.
struct RemoteTouchEvent: Equatable {
    enum Phase: Int {
        case began = 0
        case moved = 1
        case ended = 2
    }

    let phase: Phase
    let finger: Int
    let x: Double
    let y: Double
}

/// Finger allocation and move throttling for the remote viewport, independent
/// of UIKit. `Key` identifies a platform touch (e.g. `ObjectIdentifier(UITouch)`).
///
/// Rules (matching the SwiftUI controller's viewport):
/// - fingers are the lowest free id in `0...10`; extra touches are ignored;
/// - a touch begins only inside the video content (unclamped mapping);
/// - moves are clamped to the content and sent at most every 1/60 s per touch;
/// - ends are clamped and always carry a coordinate, falling back to the last
///   sent remote point when the video geometry is gone, so a release is never
///   skipped;
/// - `cancelAll` releases every active touch (input disabled, view detached).
struct RemoteTouchTracker<Key: Hashable> {
    /// Maps a view point to normalized remote coordinates; `clamped` pins
    /// points outside the video content to its edge instead of returning nil.
    typealias Normalizer = (_ point: CGPoint, _ clamped: Bool) -> CGPoint?

    static var fingers: ClosedRange<Int> { 0...10 }
    static var moveInterval: TimeInterval { 1.0 / 60.0 }
    /// Absorbs timestamp jitter so a 60 Hz digitizer is not halved to 30 Hz.
    static var moveTolerance: TimeInterval { 0.0005 }

    private struct Active {
        let finger: Int
        var point: CGPoint
        var remote: CGPoint
        var lastMoveTimestamp: TimeInterval
    }

    private var active: [Key: Active] = [:]

    var activeCount: Int { active.count }
    var activeFingers: Set<Int> { Set(active.values.map(\.finger)) }

    mutating func begin(_ key: Key, at point: CGPoint, timestamp: TimeInterval, normalize: Normalizer) -> RemoteTouchEvent? {
        guard active[key] == nil, let finger = nextFinger(), let remote = normalize(point, false) else { return nil }
        active[key] = Active(finger: finger, point: point, remote: remote, lastMoveTimestamp: timestamp)
        return RemoteTouchEvent(phase: .began, finger: finger, remote: remote)
    }

    mutating func move(_ key: Key, to point: CGPoint, timestamp: TimeInterval, normalize: Normalizer) -> RemoteTouchEvent? {
        guard var touch = active[key],
              timestamp - touch.lastMoveTimestamp >= Self.moveInterval - Self.moveTolerance,
              let remote = normalize(point, true) else { return nil }
        touch.point = point
        touch.remote = remote
        touch.lastMoveTimestamp = timestamp
        active[key] = touch
        return RemoteTouchEvent(phase: .moved, finger: touch.finger, remote: remote)
    }

    mutating func end(_ key: Key, at point: CGPoint, normalize: Normalizer) -> RemoteTouchEvent? {
        guard let touch = active.removeValue(forKey: key) else { return nil }
        let remote = normalize(point, true) ?? normalize(touch.point, true) ?? touch.remote
        return RemoteTouchEvent(phase: .ended, finger: touch.finger, remote: remote)
    }

    /// Releases for every active touch, ordered by finger id.
    mutating func cancelAll(normalize: Normalizer) -> [RemoteTouchEvent] {
        let events = active.values
            .sorted { $0.finger < $1.finger }
            .map { touch in
                RemoteTouchEvent(phase: .ended, finger: touch.finger, remote: normalize(touch.point, true) ?? touch.remote)
            }
        active.removeAll(keepingCapacity: true)
        return events
    }

    private func nextFinger() -> Int? {
        let used = activeFingers
        return Self.fingers.first { !used.contains($0) }
    }
}

private extension RemoteTouchEvent {
    init(phase: Phase, finger: Int, remote: CGPoint) {
        self.init(phase: phase, finger: finger, x: Double(remote.x), y: Double(remote.y))
    }
}
