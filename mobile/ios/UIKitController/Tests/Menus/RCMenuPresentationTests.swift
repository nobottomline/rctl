import UIKit
import XCTest
@testable import RctlUIKit

/// Presentation behavior in a real window: overlay hosting, "action runs
/// after dismissal", one menu at a time, disabled items, submenus,
/// press-and-drag routing, automatic dismissal and the context-menu source.
@MainActor
final class RCMenuPresentationTests: XCTestCase {
    private var window: UIWindow!
    private var anchor: UIButton!

    override func setUp() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let root = UIViewController()
        root.view.backgroundColor = .white
        window.rootViewController = root
        window.isHidden = false
        let anchor = UIButton(frame: CGRect(x: 20, y: 200, width: 100, height: 36))
        root.view.addSubview(anchor)
        window.layoutIfNeeded()
        self.window = window
        self.anchor = anchor
    }

    override func tearDown() async throws {
        RCMenu.dismissAll(animated: false)
        window.isHidden = true
        window = nil
        anchor = nil
    }

    // MARK: Helpers

    private func spin(_ seconds: TimeInterval) {
        let done = expectation(description: "spin")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2)
    }

    private func row(_ title: String, in presentation: RCMenuPresentation) throws -> RCMenuRowView {
        try XCTUnwrap(presentation.panel.currentPage?.rows.first { $0.item?.title == title || ($0.isBack && title == "Back") })
    }

    private func windowCenter(of view: UIView) -> CGPoint {
        view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    private func sections(onSelect: @escaping @MainActor (String) -> Void = { _ in }) -> [RCMenuSection] {
        [
            RCMenuSection(title: "Relays", items: [
                RCMenuItem("One", isChecked: true) { onSelect("One") },
                RCMenuItem("Two") { onSelect("Two") },
            ]),
            RCMenuSection(items: [
                RCMenuItem("Disabled", isEnabled: false) { onSelect("Disabled") },
                RCMenuItem("More", children: [RCMenuSection(items: [RCMenuItem("Child") { onSelect("Child") }])]),
                RCMenuItem("Delete", role: .destructive) { onSelect("Delete") },
            ]),
        ]
    }

    // MARK: Hosting

    func testPresentsAsTopmostOverlayInTheAnchorsWindow() throws {
        RCMenu.present(sections(), from: anchor)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        XCTAssertTrue(RCMenu.isPresented)
        XCTAssertTrue(presentation.overlay.superview === window)
        XCTAssertTrue(window.subviews.last === presentation.overlay)
        XCTAssertNil(window.rootViewController?.presentedViewController, "No view-controller presentation")
        let frame = presentation.panel.convert(presentation.panel.bounds, to: window)
        XCTAssertEqual(frame.minY, anchor.frame.maxY + 8, accuracy: 0.5)
        XCTAssertEqual(frame.minX, anchor.frame.minX, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(frame.width, 220)
        XCTAssertTrue(presentation.overlay.accessibilityViewIsModal)
    }

    func testRowsExposeAccessibilityState() throws {
        RCMenu.present(sections(), from: anchor)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        XCTAssertTrue(try row("One", in: presentation).accessibilityTraits.contains(.selected))
        XCTAssertTrue(try row("Disabled", in: presentation).accessibilityTraits.contains(.notEnabled))
        XCTAssertTrue(try row("Two", in: presentation).accessibilityTraits.contains(.button))
        XCTAssertNotNil(try row("More", in: presentation).accessibilityHint)
    }

    // MARK: Selection

    func testActionRunsOnlyAfterTheMenuHasFinishedDismissing() throws {
        var ranWhileOverlayInWindow: Bool?
        var ranWhilePresented: Bool?
        let ran = expectation(description: "action")
        RCMenu.present(sections { _ in
            ranWhileOverlayInWindow = RCMenuPresentation.current?.overlay.window != nil
            ranWhilePresented = RCMenu.isPresented
            ran.fulfill()
        }, from: anchor)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        let overlay = presentation.overlay

        presentation.activate(try row("Two", in: presentation))
        XCTAssertNil(ranWhilePresented, "The action must not run synchronously on selection")
        XCTAssertTrue(RCMenu.isPresented)
        XCTAssertTrue(presentation.hasCommitted)

        wait(for: [ran], timeout: 2)
        XCTAssertEqual(ranWhilePresented, false)
        XCTAssertEqual(ranWhileOverlayInWindow, false)
        XCTAssertNil(overlay.superview)
        XCTAssertEqual(presentation.phase, .finished)
    }

    func testImmediateDismissalStillRunsACommittedActionAfterRemovingTheOverlay() throws {
        var order: [String] = []
        RCMenu.present(sections { _ in
            order.append(RCMenu.isPresented ? "action-while-presented" : "action")
        }, from: anchor)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        presentation.activate(try row("One", in: presentation))
        RCMenu.dismissAll(animated: false)
        XCTAssertEqual(order, ["action"])
        XCTAssertNil(presentation.overlay.superview)
    }

    func testDisabledItemIsNotSelectable() throws {
        var selected: [String] = []
        RCMenu.present(sections { selected.append($0) }, from: anchor)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        presentation.activate(try row("Disabled", in: presentation))
        XCTAssertFalse(presentation.hasCommitted)
        XCTAssertTrue(presentation.isOpen)
        spin(0.3)
        XCTAssertEqual(selected, [])
        XCTAssertTrue(RCMenu.isPresented)
    }

    func testSubmenuNavigatesWithoutRunningAnActionAndCanGoBack() throws {
        var selected: [String] = []
        RCMenu.present(sections { selected.append($0) }, from: anchor)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        presentation.activate(try row("More", in: presentation))
        XCTAssertEqual(presentation.panel.pages.count, 2)
        XCTAssertFalse(presentation.hasCommitted)
        spin(0.6)
        let page = try XCTUnwrap(presentation.panel.currentPage)
        XCTAssertTrue(page.rows.first?.isBack == true)
        XCTAssertNotNil(page.rows.first { $0.item?.title == "Child" })
        XCTAssertEqual(selected, [])

        presentation.activate(try row("Back", in: presentation))
        spin(0.6)
        XCTAssertEqual(presentation.panel.pages.count, 1)
        XCTAssertNotNil(try? row("Two", in: presentation))

        presentation.activate(try row("More", in: presentation))
        spin(0.6)
        presentation.activate(try row("Child", in: presentation))
        RCMenu.dismissAll(animated: false)
        XCTAssertEqual(selected, ["Child"])
    }

    // MARK: Dismissal

    func testOutsideTouchDismissesWithoutRunningAnAction() throws {
        var selected: [String] = []
        RCMenu.present(sections { selected.append($0) }, from: anchor)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        presentation.overlayTouch(.began, at: CGPoint(x: 380, y: 800))
        XCTAssertEqual(presentation.phase, .dismissing)
        XCTAssertFalse(presentation.overlay.isUserInteractionEnabled, "Taps during the exit reach the content")
        spin(0.4)
        XCTAssertFalse(RCMenu.isPresented)
        XCTAssertEqual(selected, [])
    }

    func testPresentingAnotherMenuReplacesTheFirst() throws {
        RCMenu.present(sections(), from: anchor)
        let first = try XCTUnwrap(RCMenuPresentation.current)
        RCMenu.present(sections(), from: anchor, direction: .up)
        let second = try XCTUnwrap(RCMenuPresentation.current)
        XCTAssertFalse(first === second)
        XCTAssertEqual(first.phase, .finished)
        XCTAssertNil(first.overlay.superview)
        XCTAssertEqual(window.subviews.filter { $0 is RCMenuOverlayView }.count, 1)
    }

    func testAnchorLeavingTheWindowDismisses() throws {
        RCMenu.present(sections(), from: anchor)
        XCTAssertTrue(RCMenu.isPresented)
        anchor.removeFromSuperview()
        spin(0.1)
        XCTAssertFalse(RCMenu.isPresented)
        XCTAssertFalse(anchor.subviews.contains { $0 is RCMenuWindowSentinel }, "Sentinel is removed with the menu")
    }

    func testContainerSizeChangeDismisses() throws {
        RCMenu.present(sections(), from: anchor)
        window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        window.layoutIfNeeded()
        spin(0.1)
        XCTAssertFalse(RCMenu.isPresented)
    }

    func testAppBackgroundingDismisses() throws {
        RCMenu.present(sections(), from: anchor)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertFalse(RCMenu.isPresented)
    }

    func testEscapeGestureDismisses() throws {
        RCMenu.present(sections(), from: anchor)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        XCTAssertTrue(presentation.overlay.accessibilityPerformEscape())
        XCTAssertEqual(presentation.phase, .dismissing)
    }

    // MARK: Press and drag

    func testDragFromTheControlHighlightsAndReleaseSelects() throws {
        var selected: [String] = []
        RCMenu.present(sections { selected.append($0) }, from: anchor)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        let one = try row("One", in: presentation)
        let two = try row("Two", in: presentation)
        let disabled = try row("Disabled", in: presentation)

        presentation.externalTouch(.moved, atWindowPoint: windowCenter(of: one))
        XCTAssertTrue(presentation.panel.highlightedRow === one)
        presentation.externalTouch(.moved, atWindowPoint: windowCenter(of: disabled))
        XCTAssertNil(presentation.panel.highlightedRow, "Disabled rows never highlight")
        presentation.externalTouch(.moved, atWindowPoint: windowCenter(of: two))
        XCTAssertTrue(presentation.panel.highlightedRow === two)
        presentation.externalTouch(.ended, atWindowPoint: windowCenter(of: two), travelled: true)
        XCTAssertTrue(presentation.hasCommitted)
        RCMenu.dismissAll(animated: false)
        XCTAssertEqual(selected, ["Two"])
    }

    func testReleaseAwayFromItemsKeepsATappedMenuButClosesADraggedOne() throws {
        RCMenu.present(sections(), from: anchor)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        presentation.externalTouch(.ended, atWindowPoint: CGPoint(x: 380, y: 800), travelled: false)
        XCTAssertTrue(presentation.isOpen)
        presentation.externalTouch(.ended, atWindowPoint: CGPoint(x: 380, y: 800), travelled: true)
        XCTAssertEqual(presentation.phase, .dismissing)
    }

    func testTouchInsideThePanelTracksRowsAndSelectsOnRelease() throws {
        var selected: [String] = []
        RCMenu.present(sections { selected.append($0) }, from: anchor)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        let overlay = presentation.overlay
        let one = try row("One", in: presentation)
        let delete = try row("Delete", in: presentation)
        presentation.overlayTouch(.began, at: overlay.convert(windowCenter(of: one), from: nil))
        XCTAssertTrue(presentation.panel.highlightedRow === one)
        presentation.overlayTouch(.moved, at: overlay.convert(windowCenter(of: delete), from: nil))
        XCTAssertTrue(presentation.panel.highlightedRow === delete)
        presentation.overlayTouch(.ended, at: overlay.convert(windowCenter(of: delete), from: nil))
        RCMenu.dismissAll(animated: false)
        XCTAssertEqual(selected, ["Delete"])
    }

    // MARK: Attach

    func testAttachedControlOpensOnTapWithFreshItems() throws {
        let control = RCButton(title: "Menu")
        control.frame = CGRect(x: 200, y: 400, width: 120, height: 44)
        window.rootViewController?.view.addSubview(control)
        var generation = 0
        RCMenu.attach(to: control) {
            generation += 1
            return [RCMenuSection(items: [RCMenuItem("Item \(generation)")])]
        }
        control.sendActions(for: .touchUpInside)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        XCTAssertTrue(presentation.anchor === control)
        XCTAssertNotNil(try? row("Item 1", in: presentation))
        control.sendActions(for: .primaryActionTriggered)
        XCTAssertTrue(RCMenuPresentation.current === presentation, "A second activation does not reopen")
        RCMenu.dismissAll(animated: false)
        control.sendActions(for: .touchUpInside)
        XCTAssertNotNil(try? row("Item 2", in: XCTUnwrap(RCMenuPresentation.current)))
    }

    // MARK: Context menu

    func testContextMenuHidesTheSourceWhileLiftedAndRestoresIt() throws {
        let card = UIView(frame: CGRect(x: 20, y: 500, width: 362, height: 90))
        card.backgroundColor = .red
        window.rootViewController?.view.addSubview(card)
        window.layoutIfNeeded()
        var selected: [String] = []
        var alphaWhenActionRan: CGFloat?
        let ran = expectation(description: "action")
        let interaction = RCContextMenuInteraction {
            self.sections {
                selected.append($0)
                alphaWhenActionRan = card.alpha
                ran.fulfill()
            }
        }
        interaction.attach(to: card)
        XCTAssertTrue(card.accessibilityCustomActions?.isEmpty == false, "Menu reachable without a long press")

        interaction.present()
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        XCTAssertEqual(card.alpha, 0)
        guard case .context = presentation.style else { return XCTFail("Expected a context presentation") }

        presentation.activate(try row("Two", in: presentation))
        XCTAssertEqual(card.alpha, 0, "Still lifted while the menu dismisses")
        wait(for: [ran], timeout: 2)
        XCTAssertEqual(selected, ["Two"])
        XCTAssertEqual(alphaWhenActionRan, 1, "Source is restored before the action runs")
        XCTAssertFalse(RCMenu.isPresented)
    }

    func testContextMenuWithNilProviderPresentsNothing() {
        let card = UIView(frame: CGRect(x: 20, y: 500, width: 362, height: 90))
        window.rootViewController?.view.addSubview(card)
        let interaction = RCContextMenuInteraction { nil }
        interaction.attach(to: card)
        interaction.present()
        XCTAssertFalse(RCMenu.isPresented)
        XCTAssertEqual(card.alpha, 1)
    }
}
