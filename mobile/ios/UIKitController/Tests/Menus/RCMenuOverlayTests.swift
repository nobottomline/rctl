import UIKit
import XCTest
@testable import RctlUIKit

/// Overlay activity for dropdown and context menus, the context-menu header
/// rule, and masks/rasterization only where motion needs them.
@MainActor
final class RCMenuOverlayTests: XCTestCase {
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
        let idle = await waitUntil { !RCOverlayActivity.isActive }
        XCTAssertTrue(idle, "precondition: no overlay left over from another test")
    }

    override func tearDown() async throws {
        RCMenu.dismissAll(animated: false)
        window.isHidden = true
        window = nil
        anchor = nil
        XCTAssertFalse(RCOverlayActivity.isActive, "overlay activity must return to zero")
    }

    private func spin(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func sections(_ onSelect: @escaping @MainActor (String) -> Void = { _ in }) -> [RCMenuSection] {
        [
            RCMenuSection(title: "Kitchen iPad", items: [
                RCMenuItem("Open") { onSelect("Open") },
                RCMenuItem("More", children: [RCMenuSection(title: "Saved devices", items: [RCMenuItem("Studio") { onSelect("Studio") }])]),
            ]),
            RCMenuSection(title: "Danger zone", items: [
                RCMenuItem("Remove", role: .destructive) { onSelect("Remove") },
            ]),
        ]
    }

    private func row(_ title: String, in presentation: RCMenuPresentation) throws -> RCMenuRowView {
        try XCTUnwrap(presentation.panel.currentPage?.rows.first { $0.item?.title == title })
    }

    // MARK: Overlay activity

    func testDropdownSelectionReleasesActivityWhenTheMenuIsGone() async throws {
        var selected: String?
        RCMenu.present(sections { selected = $0 }, from: anchor)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        XCTAssertTrue(RCOverlayActivity.isActive)
        XCTAssertTrue(presentation.overlay.isOverlayActiveForTesting)
        presentation.activate(try row("Open", in: presentation))
        XCTAssertTrue(RCOverlayActivity.isActive, "still visible while it dismisses")
        let done = await waitUntil { selected != nil }
        XCTAssertTrue(done)
        XCTAssertFalse(RCOverlayActivity.isActive)
    }

    func testOutsideTapAnimatedDismissal() async throws {
        RCMenu.present(sections(), from: anchor)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        presentation.overlayTouch(.began, at: CGPoint(x: 380, y: 800))
        let released = await waitUntil { !RCOverlayActivity.isActive }
        XCTAssertTrue(released)
        XCTAssertEqual(presentation.phase, .finished)
    }

    func testReplacingAMenuKeepsOneActivity() throws {
        RCMenu.present(sections(), from: anchor)
        RCMenu.present(sections(), from: anchor, direction: .up)
        XCTAssertTrue(RCOverlayActivity.isActive)
        RCMenu.dismissAll(animated: false)
        XCTAssertFalse(RCOverlayActivity.isActive, "the replaced menu released its token")
    }

    func testAnchorLeavingTheWindowReleasesActivity() async throws {
        RCMenu.present(sections(), from: anchor)
        XCTAssertTrue(RCOverlayActivity.isActive)
        anchor.removeFromSuperview()
        let released = await waitUntil { !RCOverlayActivity.isActive }
        XCTAssertTrue(released)
    }

    func testBackgroundingReleasesActivity() {
        RCMenu.present(sections(), from: anchor)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertFalse(RCOverlayActivity.isActive)
    }

    func testContextMenuHoldsActivityUntilTheLiftReturns() async throws {
        let card = UIView(frame: CGRect(x: 20, y: 500, width: 362, height: 90))
        card.backgroundColor = .red
        window.rootViewController?.view.addSubview(card)
        window.layoutIfNeeded()
        let interaction = RCContextMenuInteraction { self.sections() }
        interaction.attach(to: card)
        interaction.present()
        XCTAssertTrue(RCOverlayActivity.isActive)
        RCMenu.dismissAll(animated: true)
        XCTAssertTrue(RCOverlayActivity.isActive, "the preview is still returning")
        let released = await waitUntil { !RCOverlayActivity.isActive }
        XCTAssertTrue(released)
        XCTAssertEqual(card.alpha, 1)
    }

    // MARK: Header rule

    func testContextMenuHidesOnlyTheFirstSectionTitle() throws {
        let card = UIView(frame: CGRect(x: 20, y: 500, width: 362, height: 90))
        window.rootViewController?.view.addSubview(card)
        let interaction = RCContextMenuInteraction { self.sections() }
        interaction.attach(to: card)
        interaction.present()
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        let root = presentation.panel.rootSections
        XCTAssertNil(root.first?.title, "the lifted preview already names the target")
        XCTAssertEqual(root.last?.title, "Danger zone", "later section titles stay")
        XCTAssertEqual(root.first?.items.first { !$0.children.isEmpty }?.children.first?.title, "Saved devices", "submenu titles stay")
        let headers = presentation.panel.currentPage?.subviews.compactMap { ($0 as? RCLabel)?.text } ?? []
        XCTAssertFalse(headers.contains("Kitchen iPad"))
        XCTAssertTrue(headers.contains("Danger zone"))
    }

    func testDropdownKeepsTheFirstSectionTitle() throws {
        RCMenu.present(sections(), from: anchor)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        XCTAssertEqual(presentation.panel.rootSections.first?.title, "Kitchen iPad")
    }

    // MARK: Offscreen work

    func testPanelHasNoMaskOrRasterizationAtRest() async throws {
        RCMenu.present(sections(), from: anchor)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        let panel = presentation.panel
        if !RCMotion.reduceMotion {
            XCTAssertTrue(panel.layer.shouldRasterize, "the opening fade runs on a flattened panel")
        }
        let open = await waitUntil(timeout: 2) { presentation.phase == .open && !panel.layer.shouldRasterize }
        XCTAssertTrue(open)
        XCTAssertFalse(panel.clipsPages, "no rounded mask at rest")
        XCTAssertNil(panel.clipView.layer.mask)

        presentation.activate(try row("More", in: presentation))
        XCTAssertTrue(panel.clipsPages, "pages slide under a rounded clip")
        let settled = await waitUntil(timeout: 2) { !panel.isTransitioning }
        XCTAssertTrue(settled)
        XCTAssertFalse(panel.clipsPages, "the clip goes away with the transition")

        presentation.dismiss(animated: true)
        XCTAssertTrue(panel.layer.shouldRasterize, "the exit fades a flattened panel")
        let released = await waitUntil { !RCOverlayActivity.isActive }
        XCTAssertTrue(released)
    }

    func testScrollingPanelKeepsItsRoundedClip() async throws {
        let many = (0..<60).map { RCMenuItem("Device \($0)") }
        RCMenu.present([RCMenuSection(items: many)], from: anchor)
        let presentation = try XCTUnwrap(RCMenuPresentation.current)
        XCTAssertTrue(presentation.placement?.scrolls ?? false)
        XCTAssertTrue(presentation.panel.clipsPages, "rows scroll past the rounded corners")
    }
}
