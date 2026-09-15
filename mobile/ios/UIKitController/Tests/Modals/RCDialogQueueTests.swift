import UIKit
import XCTest
@testable import RctlUIKit

@MainActor
final class RCDialogQueueTests: XCTestCase {
    private var host: ModalTestHost!

    override func setUp() async throws {
        RCModalSupport.animationsEnabled = false
        host = try ModalTestHost()
    }

    override func tearDown() async throws {
        await host.tearDown()
        host = nil
        RCModalSupport.animationsEnabled = true
    }

    private var visibleDialog: RCDialogViewController? {
        host.root.presentedViewController as? RCDialogViewController
    }

    func testSecondDialogWaitsAndHandlersRunAfterDismissal() async throws {
        var log: [String] = []
        RCDialog.present(title: "A", actions: [RCDialogAction("OK") { log.append("A:\(self.host.root.presentedViewController == nil)") }], from: host.root)
        RCDialog.present(title: "B", actions: [RCDialogAction("OK") { log.append("B") }], from: host.root)

        let first = await waitUntil { self.visibleDialog?.content.title == "A" }
        XCTAssertTrue(first)
        XCTAssertEqual(RCModalQueue.shared.pending.count, 1, "B is queued, not dropped")

        let request = try XCTUnwrap(RCModalQueue.shared.active as? RCDialogRequest)
        XCTAssertTrue(request.choose(0))
        XCTAssertFalse(request.choose(0), "A second tap is ignored")

        let second = await waitUntil { self.visibleDialog?.content.title == "B" }
        XCTAssertTrue(second)
        XCTAssertEqual(log, ["A:true"], "A's handler ran once, after A left the screen")

        try XCTUnwrap(RCModalQueue.shared.active as? RCDialogRequest).choose(0)
        _ = await waitUntil { RCModalQueue.shared.isIdle }
        XCTAssertEqual(log, ["A:true", "B"])
    }

    func testScrimTriggersCancelOnlyWhenPresent() async throws {
        var log: [String] = []
        RCDialog.present(title: "Info", actions: [RCDialogAction("OK") { log.append("ok") }], from: host.root)
        _ = await waitUntil { self.visibleDialog != nil }
        visibleDialog?.handleScrimTap()
        XCTAssertFalse(try XCTUnwrap(visibleDialog).cardView.accessibilityPerformEscape())
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(visibleDialog, "Without a cancel action the backdrop does nothing")
        try XCTUnwrap(RCModalQueue.shared.active as? RCDialogRequest).choose(0)
        _ = await waitUntil { RCModalQueue.shared.isIdle }

        RCDialog.present(title: "Delete?", tone: .danger, actions: [
            RCDialogAction("Delete", style: .destructive) { log.append("delete") },
            RCDialogAction("Cancel", style: .cancel) { log.append("cancel") },
        ], from: host.root)
        _ = await waitUntil { self.visibleDialog?.content.title == "Delete?" }
        visibleDialog?.handleScrimTap()
        _ = await waitUntil { RCModalQueue.shared.isIdle }
        XCTAssertEqual(log, ["ok", "cancel"])
    }

    func testEscapeTriggersCancel() async throws {
        var log: [String] = []
        RCDialog.present(title: "Leave?", actions: [
            RCDialogAction("Stay", style: .cancel) { log.append("stay") },
            RCDialogAction("Leave") { log.append("leave") },
        ], from: host.root)
        _ = await waitUntil { self.visibleDialog != nil }
        XCTAssertTrue(try XCTUnwrap(visibleDialog).cardView.accessibilityPerformEscape())
        _ = await waitUntil { RCModalQueue.shared.isIdle }
        XCTAssertEqual(log, ["stay"])
    }

    func testDialogAdoptsDarkPresenter() async throws {
        let stage = UIViewController()
        stage.overrideUserInterfaceStyle = .dark
        host.root.addChild(stage)
        host.root.view.addSubview(stage.view)
        stage.didMove(toParent: host.root)
        RCDialog.present(title: "Lock?", actions: [RCDialogAction("OK")], from: stage)
        _ = await waitUntil { self.visibleDialog != nil }
        XCTAssertEqual(visibleDialog?.traitCollection.userInterfaceStyle, .dark)
    }

    func testProgressHonorsMinimumVisibleTime() async throws {
        let clock = ManualModalClock()
        var completed = false
        let handle = RCDialog.presentProgress(title: "Saving", message: nil, from: host.root, clock: clock)
        let shown = await waitUntil { (RCModalQueue.shared.active as? RCProgressRequest)?.state == .visible }
        XCTAssertTrue(shown)
        clock.advance(by: 0.1)
        handle.dismiss { completed = true }
        handle.dismiss()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(host.root.presentedViewController is RCProgressViewController, "Still visible before 450 ms")
        clock.advance(by: 0.3)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(host.root.presentedViewController is RCProgressViewController)
        XCTAssertFalse(completed)
        clock.advance(by: 0.06)
        let gone = await waitUntil { self.host.root.presentedViewController == nil && completed }
        XCTAssertTrue(gone)
        XCTAssertFalse(handle.isActive)
        var late = false
        handle.dismiss { late = true }
        XCTAssertTrue(late, "Dismissing a finished handle completes immediately")
    }

    func testQueuedProgressDismissedBeforeShowingNeverAppears() async throws {
        let clock = ManualModalClock()
        RCDialog.present(title: "Blocking", actions: [RCDialogAction("OK")], from: host.root)
        _ = await waitUntil { self.visibleDialog != nil }
        var completed = false
        let handle = RCDialog.presentProgress(title: "Quick", message: nil, from: host.root, clock: clock)
        XCTAssertEqual(RCModalQueue.shared.pending.count, 1)
        handle.dismiss { completed = true }
        XCTAssertTrue(completed)
        XCTAssertTrue(RCModalQueue.shared.pending.isEmpty)
        try XCTUnwrap(RCModalQueue.shared.active as? RCDialogRequest).choose(0)
        _ = await waitUntil { RCModalQueue.shared.isIdle }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(host.root.presentedViewController)
    }
}

@MainActor
final class RCMinimumDisplayGateTests: XCTestCase {
    func testReleaseWaitsForRemainingMinimum() {
        let clock = ManualModalClock()
        let gate = RCMinimumDisplayGate(minimum: 0.45, clock: clock)
        var fired = 0
        gate.markShown()
        clock.advance(by: 0.2)
        gate.requestRelease { fired += 1 }
        gate.requestRelease { fired += 100 }
        clock.advance(by: 0.24)
        XCTAssertEqual(fired, 0)
        clock.advance(by: 0.02)
        XCTAssertEqual(fired, 1, "Fires once, after 450 ms on screen")
        clock.advance(by: 5)
        XCTAssertEqual(fired, 1)
    }

    func testReleaseAfterMinimumIsImmediate() {
        let clock = ManualModalClock()
        let gate = RCMinimumDisplayGate(minimum: 0.45, clock: clock)
        var fired = false
        gate.markShown()
        clock.advance(by: 2)
        gate.requestRelease { fired = true }
        clock.advance(by: 0)
        XCTAssertTrue(fired)
    }

    func testReleaseBeforeShownWaitsForFullMinimumAfterShowing() {
        let clock = ManualModalClock()
        let gate = RCMinimumDisplayGate(minimum: 0.45, clock: clock)
        var fired = false
        gate.requestRelease { fired = true }
        clock.advance(by: 3)
        XCTAssertFalse(fired, "Nothing is scheduled until the card is visible")
        gate.markShown()
        clock.advance(by: 0.44)
        XCTAssertFalse(fired)
        clock.advance(by: 0.01)
        XCTAssertTrue(fired)
    }
}
