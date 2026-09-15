import UIKit
import XCTest
@testable import RctlUIKit

/// The scrim of both sheet styles ends visible even when the geometry changes
/// while the entrance is running (the iPad card re-measures within a frame),
/// and the sheet chrome draws its rounded shape without masks.
@MainActor
final class RCSheetScrimTests: XCTestCase {
    private var host: ModalTestHost!
    private var originalFrame: CGRect = .zero

    override func setUp() async throws {
        RCModalSupport.animationsEnabled = true
        host = try ModalTestHost()
        originalFrame = host.window.frame
    }

    override func tearDown() async throws {
        RCSheetPresentationController.styleOverrideForTesting = nil
        host.window.frame = originalFrame
        RCModalSupport.animationsEnabled = false
        await host.tearDown()
        host = nil
        RCModalSupport.animationsEnabled = true
    }

    private func present(style: RCSheetGeometry.Style) async throws -> (FixedHeightContent, RCSheetPresentationController) {
        RCSheetPresentationController.styleOverrideForTesting = style
        let content = FixedHeightContent(height: 320)
        RCSheet.present(content, from: host.root)
        let presented = await waitUntil { RCSheetSession.session(for: content)?.state == .presented && !(RCSheetSession.session(for: content)?.presentationController?.detentHeights.isEmpty ?? true) }
        XCTAssertTrue(presented)
        let controller = try XCTUnwrap(RCSheetSession.session(for: content)?.presentationController)
        XCTAssertEqual(controller.chromeView.style, style)
        return (content, controller)
    }

    private func assertScrimVisible(_ controller: RCSheetPresentationController, file: StaticString = #filePath, line: UInt = #line) throws {
        let container = try XCTUnwrap(controller.containerView, file: file, line: line)
        let dimming = controller.dimmingViewForTesting
        XCTAssertTrue(dimming.superview === container, file: file, line: line)
        XCTAssertGreaterThan(dimming.alpha, 0.99, "scrim alpha \(dimming.alpha)", file: file, line: line)
        XCTAssertFalse(dimming.isHidden, file: file, line: line)
        XCTAssertEqual(dimming.frame, container.bounds, "scrim covers the container", file: file, line: line)
        let dimmingIndex = try XCTUnwrap(container.subviews.firstIndex(of: dimming), file: file, line: line)
        let chromeIndex = try XCTUnwrap(container.subviews.firstIndex(of: controller.chromeView), file: file, line: line)
        XCTAssertLessThan(dimmingIndex, chromeIndex, "scrim sits under the sheet", file: file, line: line)
        var components: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        dimming.backgroundColor?.resolvedColor(with: dimming.traitCollection).getRed(&components.0, green: &components.1, blue: &components.2, alpha: &components.3)
        XCTAssertGreaterThan(components.3, 0.1, "scrim color is not transparent", file: file, line: line)
    }

    private func settle(_ controller: RCSheetPresentationController) async {
        _ = await waitUntil(timeout: 3) {
            controller.chromeView.layer.animationKeys()?.isEmpty ?? true
                && controller.dimmingViewForTesting.layer.animationKeys()?.isEmpty ?? true
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    func testScrimIsVisibleForBothStyles() async throws {
        for style in [RCSheetGeometry.Style.bottomSheet, .card] {
            let (content, controller) = try await present(style: style)
            await settle(controller)
            try assertScrimVisible(controller)
            RCSheet.dismiss(content)
            _ = await waitUntil { content.presentingViewController == nil && RCSheetSession.session(for: content) == nil }
        }
    }

    func testGeometryChangeDuringTheEntranceKeepsTheScrim() async throws {
        for style in [RCSheetGeometry.Style.card, .bottomSheet] {
            let (content, controller) = try await present(style: style)
            // Change the container while the entrance spring is still running.
            host.window.frame = originalFrame.insetBy(dx: 0, dy: 12).offsetBy(dx: 0, dy: -12)
            host.window.layoutIfNeeded()
            await settle(controller)
            try assertScrimVisible(controller)
            XCTAssertEqual(controller.chromeView.transform, .identity)
            host.window.frame = originalFrame
            host.window.layoutIfNeeded()
            RCSheet.dismiss(content)
            _ = await waitUntil { content.presentingViewController == nil && RCSheetSession.session(for: content) == nil }
        }
    }

    func testChromeRoundsWithoutMaskingContent() async throws {
        for style in [RCSheetGeometry.Style.bottomSheet, .card] {
            let (content, controller) = try await present(style: style)
            await settle(controller)
            let chrome = controller.chromeView
            for view in [chrome, chrome.surfaceView, chrome.contentClipView] {
                XCTAssertNil(view.layer.mask)
                XCTAssertFalse(view.layer.masksToBounds && view.layer.cornerRadius > 0, "\(type(of: view)) \(style): no rounded mask")
            }
            XCTAssertTrue(chrome.contentClipView.clipsToBounds, "rectangular content clip")
            XCTAssertEqual(chrome.contentClipView.layer.cornerRadius, 0)
            XCTAssertEqual(chrome.surfaceView.layer.cornerRadius, RCRadius.xxl)
            XCTAssertTrue(content.view.isDescendant(of: chrome.contentClipView))
            XCTAssertEqual(content.view.layer.cornerRadius, RCRadius.xxl, "an opaque content background gets the sheet's corners")
            XCTAssertFalse(content.view.layer.masksToBounds)
            let expectedCorners: CACornerMask = style == .bottomSheet
                ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            XCTAssertEqual(content.view.layer.maskedCorners, expectedCorners)
            RCSheet.dismiss(content)
            _ = await waitUntil { content.presentingViewController == nil && RCSheetSession.session(for: content) == nil }
            XCTAssertEqual(content.view.layer.cornerRadius, 0, "content corners are restored after dismissal")
        }
    }
}
