import CoreGraphics
import XCTest
@testable import RctlUIKit

final class RemoteTouchTrackerTests: XCTestCase {
    private typealias Tracker = RemoteTouchTracker<Int>

    /// Video content occupies x 0…100, y 0…200 of the view.
    private var geometry: Tracker.Normalizer {
        { point, clamped in
            let content = CGRect(x: 0, y: 0, width: 100, height: 200)
            if !clamped, !content.contains(point) { return nil }
            return CGPoint(x: min(max(point.x / 100, 0), 1), y: min(max(point.y / 200, 0), 1))
        }
    }

    /// Geometry is gone (e.g. the track was cleared).
    private let noGeometry: Tracker.Normalizer = { _, _ in nil }

    func testFingersUseLowestFreeIdAndCapAtEleven() {
        var tracker = Tracker()
        for key in 0..<11 {
            XCTAssertEqual(tracker.begin(key, at: CGPoint(x: 10, y: 10), timestamp: 0, normalize: geometry)?.finger, key)
        }
        XCTAssertNil(tracker.begin(11, at: CGPoint(x: 10, y: 10), timestamp: 0, normalize: geometry), "Fingers are limited to 0…10")
        XCTAssertEqual(tracker.activeFingers, Set(0...10))

        XCTAssertEqual(tracker.end(3, at: CGPoint(x: 10, y: 10), normalize: geometry)?.finger, 3)
        XCTAssertEqual(tracker.begin(12, at: CGPoint(x: 20, y: 20), timestamp: 1, normalize: geometry)?.finger, 3, "Released ids are reused")
    }

    func testBeginOnlyInsideVideoContent() {
        var tracker = Tracker()
        XCTAssertNil(tracker.begin(1, at: CGPoint(x: 150, y: 10), timestamp: 0, normalize: geometry))
        XCTAssertEqual(tracker.activeCount, 0, "A rejected touch consumes no finger")
        let began = tracker.begin(2, at: CGPoint(x: 50, y: 100), timestamp: 0, normalize: geometry)
        XCTAssertEqual(began, RemoteTouchEvent(phase: .began, finger: 0, x: 0.5, y: 0.5))
        XCTAssertNil(tracker.begin(2, at: CGPoint(x: 50, y: 100), timestamp: 0, normalize: geometry), "A touch begins once")
    }

    func testMovesAreThrottledPerTouchAndClamped() {
        var tracker = Tracker()
        _ = tracker.begin(1, at: CGPoint(x: 10, y: 10), timestamp: 10, normalize: geometry)
        _ = tracker.begin(2, at: CGPoint(x: 20, y: 20), timestamp: 10, normalize: geometry)

        XCTAssertNil(tracker.move(1, to: CGPoint(x: 11, y: 11), timestamp: 10.008, normalize: geometry), "120 Hz samples are halved")
        // A 60 Hz sample with timestamp jitter still passes.
        let moved = tracker.move(1, to: CGPoint(x: 250, y: -40), timestamp: 10 + 1.0 / 60.0 - 0.0002, normalize: geometry)
        XCTAssertEqual(moved, RemoteTouchEvent(phase: .moved, finger: 0, x: 1, y: 0), "Moves are clamped to the content")
        XCTAssertNil(tracker.move(1, to: CGPoint(x: 12, y: 12), timestamp: 10.025, normalize: geometry), "The interval restarts at the last sent move")
        XCTAssertNotNil(tracker.move(2, to: CGPoint(x: 21, y: 21), timestamp: 10.017, normalize: geometry), "Throttling is per touch")
        XCTAssertNil(tracker.move(99, to: CGPoint(x: 1, y: 1), timestamp: 20, normalize: geometry), "Unknown touches are ignored")
    }

    func testMoveWithoutGeometryDoesNotAdvanceThrottle() {
        var tracker = Tracker()
        _ = tracker.begin(1, at: CGPoint(x: 10, y: 10), timestamp: 0, normalize: geometry)
        XCTAssertNil(tracker.move(1, to: CGPoint(x: 20, y: 20), timestamp: 0.02, normalize: noGeometry))
        XCTAssertNotNil(tracker.move(1, to: CGPoint(x: 20, y: 20), timestamp: 0.021, normalize: geometry))
    }

    func testEndIsClampedAndAlwaysCarriesACoordinate() {
        var tracker = Tracker()
        _ = tracker.begin(1, at: CGPoint(x: 50, y: 50), timestamp: 0, normalize: geometry)
        XCTAssertEqual(tracker.end(1, at: CGPoint(x: -30, y: 400), normalize: geometry), RemoteTouchEvent(phase: .ended, finger: 0, x: 0, y: 1))
        XCTAssertNil(tracker.end(1, at: .zero, normalize: geometry), "A touch ends once")

        _ = tracker.begin(2, at: CGPoint(x: 50, y: 100), timestamp: 0, normalize: geometry)
        _ = tracker.move(2, to: CGPoint(x: 25, y: 50), timestamp: 1, normalize: geometry)
        XCTAssertEqual(tracker.end(2, at: CGPoint(x: 90, y: 90), normalize: noGeometry), RemoteTouchEvent(phase: .ended, finger: 0, x: 0.25, y: 0.25), "Falls back to the last sent remote point")
        XCTAssertEqual(tracker.activeCount, 0)
    }

    func testCancelAllReleasesEveryTouchInFingerOrder() {
        var tracker = Tracker()
        _ = tracker.begin(7, at: CGPoint(x: 10, y: 20), timestamp: 0, normalize: geometry)
        _ = tracker.begin(3, at: CGPoint(x: 30, y: 40), timestamp: 0, normalize: geometry)
        _ = tracker.begin(5, at: CGPoint(x: 50, y: 60), timestamp: 0, normalize: geometry)
        _ = tracker.end(3, at: CGPoint(x: 30, y: 40), normalize: geometry)

        let releases = tracker.cancelAll(normalize: noGeometry)
        XCTAssertEqual(releases, [
            RemoteTouchEvent(phase: .ended, finger: 0, x: 0.1, y: 0.1),
            RemoteTouchEvent(phase: .ended, finger: 2, x: 0.5, y: 0.3),
        ])
        XCTAssertEqual(tracker.activeCount, 0)
        XCTAssertTrue(tracker.cancelAll(normalize: geometry).isEmpty)
    }
}
