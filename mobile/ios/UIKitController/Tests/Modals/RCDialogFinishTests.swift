import UIKit
import XCTest
@testable import RctlUIKit

/// `onFinish` must run exactly once for every way a dialog leaves the screen,
/// so callers that gate on "a dialog is showing" can never stay blocked.
@MainActor
final class RCDialogFinishTests: XCTestCase {
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

    func testOnFinishRunsOnceAfterTheChosenHandler() async throws {
        var log: [String] = []
        RCDialog.present(title: "A", actions: [RCDialogAction("OK") { log.append("handler") }], from: host.root, onFinish: { log.append("finish") })
        _ = await waitUntil { RCModalQueue.shared.active?.state == .visible }
        try XCTUnwrap(RCModalQueue.shared.active as? RCDialogRequest).choose(0)
        _ = await waitUntil { RCModalQueue.shared.isIdle }
        XCTAssertEqual(log, ["handler", "finish"])
    }

    func testOnFinishRunsWhenTheDialogIsTornDownWithItsPresenter() async throws {
        let middle = UIViewController()
        host.root.present(middle, animated: false)
        let middleShown = await waitUntil { middle.presentingViewController != nil && middle.viewIfLoaded?.window != nil }
        XCTAssertTrue(middleShown)
        var finished = 0
        RCDialog.present(title: "Error", actions: [RCDialogAction("OK")], from: middle, onFinish: { finished += 1 })
        _ = await waitUntil { RCModalQueue.shared.active?.state == .visible }
        XCTAssertTrue(RCModalQueue.shared.active?.controller?.presentingViewController === middle)
        // The screen that owned the dialog goes away (e.g. a tap already in flight) while it is up.
        host.root.dismiss(animated: false)
        let idle = await waitUntil { RCModalQueue.shared.isIdle }
        XCTAssertTrue(idle, "A torn-down dialog must release the queue")
        XCTAssertEqual(finished, 1)
    }

    func testChoosingAnActionClosesTheDialogNotAModalAboveIt() async throws {
        var chosen = false
        RCDialog.present(title: "Info", actions: [RCDialogAction("OK") { chosen = true }], from: host.root)
        _ = await waitUntil { RCModalQueue.shared.active?.state == .visible }
        let dialogController = try XCTUnwrap(host.root.presentedViewController)
        // Force a controller above the dialog (sheets normally wait for the queue).
        let above = UIViewController()
        dialogController.present(above, animated: false)
        _ = await waitUntil { above.presentingViewController != nil }
        try XCTUnwrap(RCModalQueue.shared.active as? RCDialogRequest).choose(0)
        let idle = await waitUntil { RCModalQueue.shared.isIdle }
        XCTAssertTrue(idle)
        XCTAssertTrue(chosen)
        XCTAssertNil(host.root.presentedViewController, "The dialog itself (and what it presented) must be gone")
    }

    func testSheetWaitsForAVisibleDialog() async throws {
        RCDialog.present(title: "Wait", actions: [RCDialogAction("OK")], from: host.root)
        _ = await waitUntil { RCModalQueue.shared.active?.state == .visible }
        let sheetContent = FixedHeightContent(height: 200)
        RCSheet.present(sheetContent, from: host.root)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(sheetContent.presentingViewController, "A sheet must not cover a dialog")
        try XCTUnwrap(RCModalQueue.shared.active as? RCDialogRequest).choose(0)
        let presented = await waitUntil { sheetContent.presentingViewController != nil }
        XCTAssertTrue(presented, "The sheet appears once the dialog is gone")
    }
}
