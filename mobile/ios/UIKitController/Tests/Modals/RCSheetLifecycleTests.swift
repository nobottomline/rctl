import UIKit
import XCTest
@testable import RctlUIKit

@MainActor
final class RCSheetLifecycleTests: XCTestCase {
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

    private func presentSheet(
        detents: [RCSheetDetent] = [.fitting],
        isDismissible: Bool = true,
        dismissals: @escaping @MainActor () -> Void
    ) async throws -> (FixedHeightContent, RCSheetPresentationController) {
        let content = FixedHeightContent(height: 300)
        RCSheet.present(content, from: host.root, detents: detents, isDismissible: isDismissible, onDismiss: dismissals)
        let presented = await waitUntil { content.presentingViewController != nil && RCSheetSession.session(for: content)?.state == .presented }
        XCTAssertTrue(presented)
        let controller = try XCTUnwrap(RCSheetSession.session(for: content)?.presentationController)
        host.window.layoutIfNeeded()
        return (content, controller)
    }

    func testProgrammaticDismissFiresOnceBeforeCompletion() async throws {
        var events: [String] = []
        let (content, _) = try await presentSheet { events.append("dismiss") }
        RCSheet.dismiss(content) { events.append("completion") }
        RCSheet.dismiss(content) { events.append("completion2") }
        let done = await waitUntil { events.count == 3 }
        XCTAssertTrue(done)
        XCTAssertEqual(events, ["dismiss", "completion", "completion2"])
        XCTAssertNil(content.presentingViewController)
        XCTAssertNil(RCSheetSession.session(for: content), "Session is released after dismissal")
        XCTAssertNotEqual(content.modalPresentationStyle, .custom, "Original presentation style is restored")
    }

    func testContentCallingDismissFiresOnce() async throws {
        var count = 0
        let (content, _) = try await presentSheet { count += 1 }
        content.dismiss(animated: false)
        _ = await waitUntil { count > 0 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(count, 1)
    }

    func testInteractiveDismissFinishFiresOnce() async throws {
        var count = 0
        let (content, controller) = try await presentSheet { count += 1 }
        controller.beginDrag()
        controller.updateDrag(fingerY: 250)
        controller.updateDrag(fingerY: 500)
        controller.endDrag(velocity: 1800)
        let dismissed = await waitUntil { content.presentingViewController == nil }
        XCTAssertTrue(dismissed)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(count, 1)
    }

    func testInteractiveDismissCancelRestoresRestState() async throws {
        var count = 0
        let (content, controller) = try await presentSheet { count += 1 }
        let restFrame = controller.chromeView.frame
        controller.beginDrag()
        controller.updateDrag(fingerY: 80)
        XCTAssertNotEqual(controller.chromeView.transform, .identity, "Dragging below the detent translates the sheet")
        controller.endDrag(velocity: 0)
        XCTAssertEqual(controller.chromeView.transform, .identity)
        XCTAssertEqual(controller.chromeView.frame, restFrame)
        XCTAssertNotNil(content.presentingViewController)
        XCTAssertEqual(count, 0)
        RCSheet.dismiss(content)
        _ = await waitUntil { count == 1 }
        XCTAssertEqual(count, 1)
    }

    func testAnimatedCancelSettlesWithoutStuckTransform() async throws {
        RCModalSupport.animationsEnabled = true
        var count = 0
        let (content, controller) = try await presentSheet { count += 1 }
        _ = await waitUntil(timeout: 2) { controller.chromeView.layer.animationKeys()?.isEmpty ?? true }
        controller.beginDrag()
        controller.updateDrag(fingerY: 60)
        controller.endDrag(velocity: -300)
        let settled = await waitUntil(timeout: 3) { controller.chromeView.layer.animationKeys()?.isEmpty ?? true }
        XCTAssertTrue(settled)
        XCTAssertEqual(controller.chromeView.transform, .identity)
        XCTAssertEqual(count, 0)
        XCTAssertNotNil(content.presentingViewController)
    }

    func testEscapeDismissesOnlyWhenDismissible() async throws {
        var count = 0
        let (content, controller) = try await presentSheet { count += 1 }
        XCTAssertTrue(controller.chromeView.accessibilityPerformEscape())
        _ = await waitUntil { content.presentingViewController == nil && count == 1 }
        XCTAssertEqual(count, 1)
    }

    func testNonDismissibleSheetResistsEveryUserPath() async throws {
        var count = 0
        let (content, controller) = try await presentSheet(isDismissible: false) { count += 1 }
        XCTAssertFalse(controller.chromeView.accessibilityPerformEscape())
        controller.beginDrag()
        controller.updateDrag(fingerY: 900)
        XCTAssertLessThan(controller.chromeView.transform.ty, 80, "Drag rubber-bands")
        controller.endDrag(velocity: 3000)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNotNil(content.presentingViewController)
        XCTAssertEqual(controller.chromeView.transform, .identity)
        XCTAssertEqual(count, 0)
        RCSheet.dismiss(content)
        _ = await waitUntil { count == 1 }
        XCTAssertEqual(count, 1, "Programmatic dismissal still works")
    }

    func testDragBetweenDetentsSelectsLarge() async throws {
        let (content, controller) = try await presentSheet(detents: [.medium, .large]) {}
        XCTAssertEqual(controller.selectedIndex, 0, "Starts at the smallest detent")
        controller.beginDrag()
        controller.updateDrag(fingerY: -300)
        controller.endDrag(velocity: -600)
        XCTAssertEqual(controller.selectedIndex, 1)
        XCTAssertEqual(controller.chromeView.bounds.height, controller.detentHeights[1])
        RCSheet.dismiss(content)
        _ = await waitUntil { content.presentingViewController == nil }
    }

    func testScrollHandoffBetweenSheetAndScrollView() async throws {
        let content = ScrollableContent()
        RCSheet.present(content, from: host.root, detents: [.medium, .large])
        let installed = await waitUntil { !(RCSheetSession.session(for: content)?.presentationController?.detentHeights.isEmpty ?? true) }
        XCTAssertTrue(installed)
        let controller = try XCTUnwrap(RCSheetSession.session(for: content)?.presentationController)
        host.window.layoutIfNeeded()
        let scrollView = content.scrollView
        let medium = try XCTUnwrap(controller.detentHeights.first)
        let large = try XCTUnwrap(controller.detentHeights.last)

        controller.beginDrag(scrollView: scrollView)
        controller.updateDrag(fingerY: -50)
        XCTAssertEqual(controller.chromeView.bounds.height, medium + 50, accuracy: 0.5, "Dragging up below large expands the sheet")
        XCTAssertEqual(scrollView.contentOffset.y, 0, "The scroll view is held while the sheet moves")

        controller.updateDrag(fingerY: -2000)
        XCTAssertEqual(controller.chromeView.bounds.height, large, accuracy: 0.5, "Expansion stops at the largest detent")

        controller.updateDrag(fingerY: -2100)
        XCTAssertEqual(controller.chromeView.bounds.height, large, accuracy: 0.5, "At large, dragging up scrolls instead")

        scrollView.contentOffset.y = 300
        controller.updateDrag(fingerY: -2000)
        XCTAssertEqual(controller.chromeView.bounds.height, large, accuracy: 0.5, "Dragging down a scrolled list scrolls")
        XCTAssertEqual(controller.chromeView.transform, .identity)

        scrollView.contentOffset.y = 0
        controller.updateDrag(fingerY: -1900)
        XCTAssertEqual(controller.chromeView.bounds.height, large - 100, accuracy: 0.5, "At the top, dragging down moves the sheet")
        XCTAssertEqual(scrollView.contentOffset.y, 0)

        controller.endDrag(velocity: 0)
        XCTAssertEqual(controller.selectedIndex, 1)
        XCTAssertEqual(controller.chromeView.bounds.height, large, accuracy: 0.5)
    }

    func testDismissBeforePresentationCompletesStillFiresOnce() async throws {
        var count = 0
        // Occupy the presenter so the sheet has to wait.
        let blocker = UIViewController()
        host.root.present(blocker, animated: false)
        _ = await waitUntil { self.host.root.presentedViewController === blocker }
        let content = FixedHeightContent(height: 200)
        RCSheet.present(content, from: host.root, onDismiss: { count += 1 })
        XCTAssertEqual(RCSheetSession.session(for: content)?.state, .waiting)
        RCSheet.dismiss(content)
        XCTAssertEqual(count, 1)
        blocker.dismiss(animated: false)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(content.presentingViewController, "A cancelled request never presents")
        XCTAssertEqual(count, 1)
    }

    func testSheetAdoptsPresenterOverrideAndRestoresIt() async throws {
        let dark = UIViewController()
        dark.overrideUserInterfaceStyle = .dark
        host.root.addChild(dark)
        host.root.view.addSubview(dark.view)
        dark.didMove(toParent: host.root)
        let content = FixedHeightContent(height: 200)
        var dismissed = false
        RCSheet.present(content, from: dark, onDismiss: { dismissed = true })
        _ = await waitUntil { content.presentingViewController != nil }
        XCTAssertEqual(content.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(content.traitCollection.userInterfaceStyle, .dark)
        RCSheet.dismiss(content)
        _ = await waitUntil { dismissed }
        XCTAssertEqual(content.overrideUserInterfaceStyle, .unspecified)
    }

    func testInheritedInterfaceStyleSources() {
        let plain = UIViewController()
        XCTAssertEqual(RCModalSupport.inheritedInterfaceStyle(from: plain), .unspecified)

        let stage = UIViewController()
        stage.overrideUserInterfaceStyle = .dark
        let navigation = UINavigationController(rootViewController: stage)
        XCTAssertEqual(RCModalSupport.inheritedInterfaceStyle(from: navigation), .dark, "Navigation controller's visible child")

        let parent = UIViewController()
        parent.overrideUserInterfaceStyle = .light
        let child = UIViewController()
        parent.addChild(child)
        XCTAssertEqual(RCModalSupport.inheritedInterfaceStyle(from: child), .light, "Ancestor override")
    }
}

@MainActor
private final class ScrollableContent: UIViewController, RCSheetScrollable {
    let scrollView = UIScrollView()
    var sheetScrollView: UIScrollView? { scrollView }

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        scrollView.contentSize = CGSize(width: view.bounds.width, height: 3000)
    }
}
