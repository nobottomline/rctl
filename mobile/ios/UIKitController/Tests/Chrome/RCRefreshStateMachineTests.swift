import XCTest
@testable import RctlUIKit

final class RCRefreshStateMachineTests: XCTestCase {
    private func machine() -> RCRefreshStateMachine {
        RCRefreshStateMachine(threshold: 72, hysteresis: 10)
    }

    func testDragBelowThresholdAndReleaseDoesNothing() {
        var sut = machine()
        XCTAssertEqual(sut.scrolled(pull: 20, isDragging: true), [])
        XCTAssertEqual(sut.phase, .pulling)
        XCTAssertEqual(sut.progress, 20.0 / 72.0, accuracy: 0.0001)
        XCTAssertEqual(sut.scrolled(pull: 60, isDragging: true), [])
        XCTAssertEqual(sut.endDragging(pull: 60), [])
        XCTAssertEqual(sut.phase, .idle)
        XCTAssertFalse(sut.holdsInset)
    }

    func testCrossingThresholdPlaysHapticExactlyOnce() {
        var sut = machine()
        var effects: [RCRefreshStateMachine.Effect] = []
        for pull in stride(from: CGFloat(0), through: 140, by: 4) {
            effects += sut.scrolled(pull: pull, isDragging: true)
        }
        XCTAssertEqual(effects, [.thresholdHaptic])
        XCTAssertEqual(sut.phase, .armed)
        XCTAssertEqual(sut.progress, 1)
    }

    func testJitterAtThresholdDoesNotRepeatHaptic() {
        var sut = machine()
        var effects: [RCRefreshStateMachine.Effect] = []
        for pull: CGFloat in [70, 72, 71, 73, 66, 74, 65, 72] {
            effects += sut.scrolled(pull: pull, isDragging: true)
        }
        XCTAssertEqual(effects, [.thresholdHaptic], "Dips inside the hysteresis band must not re-arm")
    }

    func testDroppingWellBelowAndRecrossingIsANewCrossing() {
        var sut = machine()
        XCTAssertEqual(sut.scrolled(pull: 80, isDragging: true), [.thresholdHaptic])
        XCTAssertEqual(sut.scrolled(pull: 40, isDragging: true), [])
        XCTAssertEqual(sut.phase, .pulling)
        XCTAssertEqual(sut.endDragging(pull: 40), [], "Releasing after disarming does not refresh")
        XCTAssertEqual(sut.phase, .idle)
        XCTAssertEqual(sut.scrolled(pull: 10, isDragging: true), [])
        XCTAssertEqual(sut.scrolled(pull: 75, isDragging: true), [.thresholdHaptic])
    }

    func testMomentumPastThresholdNeverArms() {
        var sut = machine()
        XCTAssertEqual(sut.scrolled(pull: 120, isDragging: false), [])
        XCTAssertEqual(sut.phase, .idle)
        XCTAssertEqual(sut.endDragging(pull: 120), [])
        XCTAssertFalse(sut.isRefreshing)
    }

    func testReleaseWhileArmedStartsRefreshAndHoldsInsetWithoutAnimation() {
        var sut = machine()
        _ = sut.scrolled(pull: 90, isDragging: true)
        XCTAssertEqual(sut.endDragging(pull: 90), [.holdInset(animated: false), .startRefresh])
        XCTAssertTrue(sut.isRefreshing)
        XCTAssertTrue(sut.holdsInset)
        XCTAssertEqual(sut.progress, 1)
    }

    func testScrollingWhileRefreshingChangesNothing() {
        var sut = machine()
        _ = sut.scrolled(pull: 90, isDragging: true)
        _ = sut.endDragging(pull: 90)
        XCTAssertEqual(sut.scrolled(pull: 200, isDragging: true), [])
        XCTAssertEqual(sut.scrolled(pull: -300, isDragging: true), [])
        XCTAssertEqual(sut.endDragging(pull: 150), [])
        XCTAssertTrue(sut.isRefreshing)
    }

    func testFinishWhenNotDraggingReleasesInsetImmediately() {
        var sut = machine()
        _ = sut.begin()
        XCTAssertEqual(sut.finish(isDragging: false), [.stopIndicator, .releaseInset])
        XCTAssertEqual(sut.phase, .idle)
        XCTAssertFalse(sut.holdsInset)
    }

    func testFinishWhileDraggingDefersInsetUntilRelease() {
        var sut = machine()
        _ = sut.scrolled(pull: 90, isDragging: true)
        _ = sut.endDragging(pull: 90)
        _ = sut.scrolled(pull: 30, isDragging: true)
        XCTAssertEqual(sut.finish(isDragging: true), [.stopIndicator])
        XCTAssertEqual(sut.phase, .finishing)
        XCTAssertTrue(sut.holdsInset, "Inset stays while the finger is down")
        XCTAssertFalse(sut.isRefreshing)
        XCTAssertEqual(sut.scrolled(pull: 120, isDragging: true), [], "Cannot re-arm before the inset is released")
        XCTAssertEqual(sut.endDragging(pull: 120), [.releaseInset])
        XCTAssertEqual(sut.phase, .idle)
    }

    func testProgrammaticBeginAnimatesInsetAndIsIdempotent() {
        var sut = machine()
        XCTAssertEqual(sut.begin(), [.holdInset(animated: true), .startRefresh])
        XCTAssertEqual(sut.begin(), [])
        XCTAssertEqual(sut.finish(isDragging: false), [.stopIndicator, .releaseInset])
        XCTAssertEqual(sut.finish(isDragging: false), [], "Ending twice is harmless")
    }

    func testBeginDuringDeferredReleaseReusesHeldInset() {
        var sut = machine()
        _ = sut.begin()
        _ = sut.finish(isDragging: true)
        XCTAssertEqual(sut.begin(), [.startRefresh])
        XCTAssertTrue(sut.isRefreshing)
        XCTAssertEqual(sut.finish(isDragging: false), [.stopIndicator, .releaseInset])
    }

    func testNegativePullReportsZeroProgress() {
        var sut = machine()
        _ = sut.scrolled(pull: -40, isDragging: true)
        XCTAssertEqual(sut.phase, .idle)
        XCTAssertEqual(sut.progress, 0)
    }
}
