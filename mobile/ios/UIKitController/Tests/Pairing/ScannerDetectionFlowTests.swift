import CoreGraphics
import XCTest
@testable import RctlUIKit

@MainActor
final class ScannerDetectionFlowTests: XCTestCase {
    private let pairingCode = #"{"v":1,"origin":"https://relay.example","pairing_id":"pair_1","secret":"s","expires_at":0,"protocol_major":1,"relay_id":"r"}"#
    private let otherPairingCode = #"{"v":1,"origin":"https://relay.example","pairing_id":"pair_2","secret":"t","expires_at":0,"protocol_major":1,"relay_id":"r"}"#

    private var clock: ManualScannerClock!
    private var flow: ScannerDetectionFlow!
    private var feedback: [ScannerDetectionFlow.Feedback] = []
    private var delivered: [String] = []
    private var stateChanges = 0

    override func setUp() async throws {
        clock = ManualScannerClock()
        flow = ScannerDetectionFlow(clock: clock)
        feedback = []
        delivered = []
        stateChanges = 0
        flow.onFeedback = { [unowned self] in self.feedback.append($0) }
        flow.onDeliver = { [unowned self] in self.delivered.append($0) }
        flow.onStateChange = { [unowned self] in self.stateChanges += 1 }
    }

    private func detection(_ payload: String, x: CGFloat = 100) -> ScannerDetection {
        ScannerDetection(payload: payload, bounds: CGRect(x: x, y: 200, width: 150, height: 150))
    }

    // MARK: - Lock and delivery

    func testPairingCodeLocksThenDeliversAfterHold() {
        flow.update(detection(pairingCode))
        XCTAssertEqual(flow.phase, .locked(payload: pairingCode))
        XCTAssertEqual(feedback, [.lock])

        clock.advance(by: 0.41)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(flow.phase, .locked(payload: pairingCode))

        clock.advance(by: 0.01)
        XCTAssertEqual(delivered, [pairingCode])
        XCTAssertEqual(flow.phase, .pairing)
        XCTAssertEqual(feedback, [.lock, .deliver])
    }

    func testReduceMotionShortensHold() {
        flow.reduceMotion = true
        flow.update(detection(pairingCode))
        clock.advance(by: 0.12)
        XCTAssertEqual(delivered, [pairingCode])
    }

    func testMovingCodeDoesNotRestartHold() {
        flow.update(detection(pairingCode, x: 100))
        clock.advance(by: 0.3)
        flow.update(detection(pairingCode, x: 140))
        XCTAssertEqual(feedback, [.lock], "Tracking the same code must not replay the lock cue")
        clock.advance(by: 0.12)
        XCTAssertEqual(delivered, [pairingCode])
    }

    func testLosingCodeBeforeHoldCancelsDelivery() {
        flow.update(detection(pairingCode))
        clock.advance(by: 0.2)
        flow.update(nil)
        XCTAssertEqual(flow.phase, .scanning)
        clock.advance(by: 2)
        XCTAssertTrue(delivered.isEmpty)
    }

    func testSwitchingToAnotherPairingCodeRelocks() {
        flow.update(detection(pairingCode))
        clock.advance(by: 0.3)
        flow.update(detection(otherPairingCode))
        XCTAssertEqual(flow.phase, .locked(payload: otherPairingCode))
        clock.advance(by: 0.2)
        XCTAssertTrue(delivered.isEmpty)
        clock.advance(by: 0.22)
        XCTAssertEqual(delivered, [otherPairingCode])
    }

    func testDetectionsAreIgnoredWhilePairing() {
        flow.update(detection(pairingCode))
        clock.advance(by: 0.42)
        flow.update(nil)
        flow.update(detection("https://example.com"))
        flow.update(detection(otherPairingCode))
        clock.advance(by: 2)
        XCTAssertEqual(flow.phase, .pairing)
        XCTAssertFalse(flow.isShowingForeignCode)
        XCTAssertEqual(delivered, [pairingCode])
    }

    func testDetectionIsStillReportedWhilePairingSoTheWindowFollowsTheCode() {
        flow.update(detection(pairingCode))
        clock.advance(by: 0.42)
        let moved = detection(pairingCode, x: 180)
        flow.update(moved)
        XCTAssertEqual(flow.detection, moved)
    }

    // MARK: - Claim results

    func testSuccessfulClaimStaysInPairing() {
        flow.update(detection(pairingCode))
        clock.advance(by: 0.42)
        flow.deliveryDidFinish(payload: pairingCode, paired: true)
        XCTAssertEqual(flow.phase, .pairing)
    }

    func testFailedClaimRejectsSamePayloadForSixSeconds() {
        flow.update(detection(pairingCode))
        clock.advance(by: 0.42)
        flow.deliveryDidFinish(payload: pairingCode, paired: false)
        XCTAssertEqual(flow.phase, .scanning)

        // Still in view, and seen again after moving away: ignored.
        flow.update(detection(pairingCode, x: 160))
        XCTAssertEqual(flow.phase, .scanning)
        flow.update(nil)
        clock.advance(by: 5.9)
        flow.update(detection(pairingCode))
        XCTAssertEqual(flow.phase, .scanning)
        XCTAssertEqual(feedback, [.lock, .deliver])

        flow.update(nil)
        clock.advance(by: 0.2)
        flow.update(detection(pairingCode))
        XCTAssertEqual(flow.phase, .locked(payload: pairingCode))
    }

    func testRejectionOnlyAppliesToTheFailedPayload() {
        flow.update(detection(pairingCode))
        clock.advance(by: 0.42)
        flow.deliveryDidFinish(payload: pairingCode, paired: false)
        flow.update(detection(otherPairingCode))
        XCTAssertEqual(flow.phase, .locked(payload: otherPairingCode))
    }

    // MARK: - Foreign codes

    func testForeignCodeShowsFeedbackOncePerCode() {
        flow.update(detection("https://example.com/menu"))
        XCTAssertTrue(flow.isShowingForeignCode)
        XCTAssertEqual(flow.phase, .scanning)
        XCTAssertEqual(feedback, [.foreign])

        flow.update(detection("https://example.com/menu", x: 130))
        XCTAssertEqual(feedback, [.foreign])
        XCTAssertTrue(delivered.isEmpty)
    }

    func testForeignFeedbackIsThrottled() {
        flow.update(detection("code-a"))
        clock.advance(by: 1)
        flow.update(detection("code-b"))
        XCTAssertEqual(feedback, [.foreign], "A new foreign code within 2.5 s stays silent")
        clock.advance(by: 1.6)
        flow.update(detection("code-c"))
        XCTAssertEqual(feedback, [.foreign, .foreign])
    }

    func testForeignMessageLingersAfterCodeLeaves() {
        flow.update(detection("code-a"))
        flow.update(nil)
        XCTAssertTrue(flow.isShowingForeignCode)
        clock.advance(by: 1.49)
        XCTAssertTrue(flow.isShowingForeignCode)
        clock.advance(by: 0.01)
        XCTAssertFalse(flow.isShowingForeignCode)
    }

    func testForeignCodeReturningCancelsLinger() {
        flow.update(detection("code-a"))
        flow.update(nil)
        clock.advance(by: 1)
        flow.update(detection("code-a"))
        clock.advance(by: 1)
        XCTAssertTrue(flow.isShowingForeignCode)
        XCTAssertEqual(feedback, [.foreign], "The same code coming back is not new")
    }

    func testPairingCodeClearsForeignImmediately() {
        flow.update(detection("code-a"))
        flow.update(detection(pairingCode))
        XCTAssertFalse(flow.isShowingForeignCode)
        XCTAssertEqual(flow.phase, .locked(payload: pairingCode))
    }

    // MARK: - Paste and suspension

    func testPasteDeliversImmediatelyOnce() {
        XCTAssertTrue(flow.deliverPasted("pasted"))
        XCTAssertEqual(flow.phase, .pairing)
        XCTAssertEqual(delivered, ["pasted"])
        XCTAssertEqual(feedback, [.deliver])
        XCTAssertFalse(flow.deliverPasted("again"))
        XCTAssertEqual(delivered, ["pasted"])
    }

    func testPasteCancelsPendingLock() {
        flow.update(detection(pairingCode))
        flow.deliverPasted("pasted")
        clock.advance(by: 1)
        XCTAssertEqual(delivered, ["pasted"])
    }

    func testSuspendDropsTransientStateButKeepsClaim() {
        flow.update(detection(pairingCode))
        flow.suspend()
        XCTAssertEqual(flow.phase, .scanning)
        XCTAssertNil(flow.detection)
        clock.advance(by: 1)
        XCTAssertTrue(delivered.isEmpty)

        flow.deliverPasted("pasted")
        flow.suspend()
        XCTAssertEqual(flow.phase, .pairing)
    }

    func testUnchangedDetectionDoesNotNotify() {
        flow.update(detection(pairingCode))
        let changes = stateChanges
        flow.update(detection(pairingCode))
        XCTAssertEqual(stateChanges, changes)
    }

    // MARK: - Presentation

    func testPresentationPerPhase() {
        let searching = ScannerPresentation(phase: .scanning, isShowingForeignCode: false, hasDetection: false, reduceMotion: false)
        XCTAssertEqual(searching.tone, .searching)
        XCTAssertEqual(searching.title, "Scan the pairing code")
        XCTAssertEqual(searching.message, "Point the camera at the QR code in relay admin.")
        XCTAssertTrue(searching.isBreathing)
        XCTAssertTrue(searching.controlsEnabled)
        XCTAssertFalse(searching.showsLockBadge)

        let foreign = ScannerPresentation(phase: .scanning, isShowingForeignCode: true, hasDetection: true, reduceMotion: false)
        XCTAssertEqual(foreign.tone, .rejected)
        XCTAssertEqual(foreign.title, "That is not a pairing code")
        XCTAssertEqual(foreign.message, "Show the controller pairing QR code from relay admin.")
        XCTAssertTrue(foreign.showsForeignCaption)
        XCTAssertFalse(foreign.isBreathing)

        let locked = ScannerPresentation(phase: .locked(payload: "p"), isShowingForeignCode: false, hasDetection: true, reduceMotion: false)
        XCTAssertEqual(locked.tone, .locked)
        XCTAssertEqual(locked.title, "Code found")
        XCTAssertTrue(locked.showsLockBadge)

        let pairing = ScannerPresentation(phase: .pairing, isShowingForeignCode: false, hasDetection: false, reduceMotion: false)
        XCTAssertEqual(pairing.title, "Pairing with relay")
        XCTAssertTrue(pairing.showsPairingProgress)
        XCTAssertFalse(searching.showsPairingProgress)
        XCTAssertFalse(pairing.controlsEnabled)
        XCTAssertFalse(pairing.isBreathing)
    }

    func testBreathingRules() {
        XCTAssertFalse(ScannerPresentation(phase: .scanning, isShowingForeignCode: false, hasDetection: true, reduceMotion: false).isBreathing,
                       "A rejected pairing code still in view keeps the window on it without pulsing")
        XCTAssertFalse(ScannerPresentation(phase: .scanning, isShowingForeignCode: true, hasDetection: false, reduceMotion: false).isBreathing,
                       "The lingering foreign message keeps the reticle still")
        XCTAssertFalse(ScannerPresentation(phase: .scanning, isShowingForeignCode: false, hasDetection: false, reduceMotion: true).isBreathing)
    }
}

/// Deterministic clock: timers fire in deadline order while advancing.
@MainActor
private final class ManualScannerClock: ScannerClock {
    private(set) var now: TimeInterval = 1_000
    private var timers: [(deadline: TimeInterval, order: Int, timer: ManualTimer)] = []
    private var order = 0

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScannerTimer {
        let timer = ManualTimer(action: action)
        order += 1
        timers.append((now + delay, order, timer))
        return timer
    }

    func advance(by interval: TimeInterval) {
        let end = now + interval
        // Tolerate floating-point drift from summing small steps.
        while let next = timers.filter({ $0.deadline <= end + 1e-9 && !$0.timer.isCancelled }).min(by: { ($0.deadline, $0.order) < ($1.deadline, $1.order) }) {
            timers.removeAll { $0.timer === next.timer }
            now = max(now, min(next.deadline, end))
            next.timer.fire()
        }
        timers.removeAll { $0.timer.isCancelled }
        now = end
    }
}

@MainActor
private final class ManualTimer: ScannerTimer {
    private var action: (@MainActor () -> Void)?
    var isCancelled: Bool { action == nil }

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func fire() {
        let pending = action
        action = nil
        pending?()
    }

    func cancel() {
        action = nil
    }
}
