import UIKit
import XCTest
@testable import RctlUIKit

/// Dialogs, progress cards and sheets hold `RCOverlayActivity` exactly while
/// they are on screen, and release it on every way they leave.
@MainActor
final class RCModalOverlayActivityTests: XCTestCase {
    private var host: ModalTestHost!

    override func setUp() async throws {
        RCModalSupport.animationsEnabled = false
        host = try ModalTestHost()
        let idle = await waitUntil { !RCOverlayActivity.isActive }
        XCTAssertTrue(idle, "precondition: no overlay left over from another test")
    }

    override func tearDown() async throws {
        await host.tearDown()
        host = nil
        RCModalSupport.animationsEnabled = true
        let idle = await waitUntil { !RCOverlayActivity.isActive }
        XCTAssertTrue(idle, "overlay activity must return to zero")
    }

    private func assertReleased(_ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        let released = await waitUntil { !RCOverlayActivity.isActive }
        XCTAssertTrue(released, message, file: file, line: line)
    }

    // MARK: Dialogs

    func testDialogChosenAction() async throws {
        RCDialog.present(title: "Device unavailable", actions: [RCDialogAction("OK")], from: host.root)
        _ = await waitUntil { RCModalQueue.shared.active?.state == .visible }
        XCTAssertTrue(RCOverlayActivity.isActive)
        try XCTUnwrap(RCModalQueue.shared.active as? RCDialogRequest).choose(0)
        _ = await waitUntil { RCModalQueue.shared.isIdle }
        await assertReleased("chosen action")
    }

    func testAnimatedDialogAndItsMotionRasterization() async throws {
        RCModalSupport.animationsEnabled = true
        RCDialog.present(title: "Switch to Control?", actions: [RCDialogAction("Stay", style: .cancel), RCDialogAction("Control")], from: host.root)
        _ = await waitUntil { RCModalQueue.shared.active?.state == .visible }
        let card = try XCTUnwrap(RCModalQueue.shared.active?.controller?.view as? RCCardView)
        XCTAssertTrue(RCOverlayActivity.isActive)
        let rested = await waitUntil(timeout: 2) { !card.layer.shouldRasterize }
        XCTAssertTrue(rested, "rasterization is only for the entrance")
        XCTAssertTrue(card.isOverlayActiveForTesting)
        try XCTUnwrap(RCModalQueue.shared.active as? RCDialogRequest).choose(0)
        let flattened = await waitUntil(timeout: 1) { card.layer.shouldRasterize || card.window == nil }
        XCTAssertTrue(flattened && card.layer.shouldRasterize, "the exit fades a flattened card")
        _ = await waitUntil { RCModalQueue.shared.isIdle }
        await assertReleased("animated dismissal")
    }

    func testDialogTornDownWithItsPresenter() async throws {
        let middle = UIViewController()
        host.root.present(middle, animated: false)
        _ = await waitUntil { middle.viewIfLoaded?.window != nil }
        RCDialog.present(title: "Error", actions: [RCDialogAction("OK")], from: middle)
        _ = await waitUntil { RCModalQueue.shared.active?.state == .visible }
        XCTAssertTrue(RCOverlayActivity.isActive)
        host.root.dismiss(animated: false)
        _ = await waitUntil { RCModalQueue.shared.isIdle }
        await assertReleased("teardown with presenter")
    }

    func testProgressCardDismissal() async throws {
        let handle = RCDialog.presentProgress(title: "Connecting", message: nil, from: host.root, clock: RCSystemModalClock.shared, minimumVisibleDuration: 0)
        _ = await waitUntil { RCModalQueue.shared.active?.state == .visible }
        XCTAssertTrue(RCOverlayActivity.isActive)
        var finished = false
        handle.dismiss { finished = true }
        _ = await waitUntil { finished }
        await assertReleased("progress dismissal")
    }

    func testQueuedProgressThatNeverShowsHoldsNothing() async throws {
        RCDialog.present(title: "First", actions: [RCDialogAction("OK")], from: host.root)
        _ = await waitUntil { RCModalQueue.shared.active?.state == .visible }
        let queued = RCDialog.presentProgress(title: "Saving", message: nil, from: host.root, clock: RCSystemModalClock.shared, minimumVisibleDuration: 0)
        queued.dismiss()
        try XCTUnwrap(RCModalQueue.shared.active as? RCDialogRequest).choose(0)
        _ = await waitUntil { RCModalQueue.shared.isIdle }
        await assertReleased("cancelled queued card")
    }

    // MARK: Sheets

    private func presentSheet(from presenter: UIViewController? = nil) async throws -> (FixedHeightContent, RCSheetPresentationController) {
        let content = FixedHeightContent(height: 280)
        RCSheet.present(content, from: presenter ?? host.root)
        _ = await waitUntil { RCSheetSession.session(for: content)?.state == .presented && content.viewIfLoaded?.window != nil }
        let controller = try XCTUnwrap(RCSheetSession.session(for: content)?.presentationController)
        XCTAssertTrue(RCOverlayActivity.isActive)
        XCTAssertTrue(controller.chromeView.isOverlayActiveForTesting)
        return (content, controller)
    }

    func testSheetProgrammaticDismissal() async throws {
        let (content, _) = try await presentSheet()
        var dismissed = false
        RCSheet.dismiss(content) { dismissed = true }
        _ = await waitUntil { dismissed }
        await assertReleased("programmatic dismissal")
    }

    func testSheetInteractiveDismissal() async throws {
        let (content, controller) = try await presentSheet()
        controller.beginDrag()
        controller.updateDrag(fingerY: 400)
        controller.endDrag(velocity: 2000)
        _ = await waitUntil { content.presentingViewController == nil }
        await assertReleased("drag to dismiss")
    }

    func testSheetContentCallingDismiss() async throws {
        let (content, _) = try await presentSheet()
        content.dismiss(animated: false)
        _ = await waitUntil { content.presentingViewController == nil }
        await assertReleased("content dismiss")
    }

    func testSheetTornDownWithItsPresenter() async throws {
        let middle = UIViewController()
        host.root.present(middle, animated: false)
        _ = await waitUntil { middle.viewIfLoaded?.window != nil }
        let (content, _) = try await presentSheet(from: middle)
        host.root.dismiss(animated: false)
        _ = await waitUntil { content.viewIfLoaded?.window == nil }
        await assertReleased("teardown with presenter")
    }

    func testSheetCancelledBeforePresentationHoldsNothing() async throws {
        let blocker = UIViewController()
        host.root.present(blocker, animated: false)
        _ = await waitUntil { self.host.root.presentedViewController === blocker }
        let content = FixedHeightContent(height: 200)
        RCSheet.present(content, from: host.root)
        RCSheet.dismiss(content)
        XCTAssertFalse(RCOverlayActivity.isActive)
        blocker.dismiss(animated: false)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(RCOverlayActivity.isActive)
    }

    func testSheetAndDialogTogetherReleaseBoth() async throws {
        let (content, _) = try await presentSheet()
        RCDialog.present(title: "On top", actions: [RCDialogAction("OK")], from: content)
        _ = await waitUntil { RCModalQueue.shared.active?.state == .visible }
        try XCTUnwrap(RCModalQueue.shared.active as? RCDialogRequest).choose(0)
        _ = await waitUntil { RCModalQueue.shared.isIdle }
        XCTAssertTrue(RCOverlayActivity.isActive, "the sheet is still up")
        RCSheet.dismiss(content)
        await assertReleased("both gone")
    }
}
