import CoreGraphics
import XCTest
@testable import RctlUIKit

/// Pure placement math: flip, clamp, widths, landscape, iPad, keyboard, RTL,
/// and context-menu preview shifting.
final class RCMenuLayoutTests: XCTestCase {
    // iPhone 16 Pro portrait: 402 × 874, safe area top 62 / bottom 34.
    private let phone = CGRect(x: 0, y: 0, width: 402, height: 874)
    private let phoneInsets = (top: CGFloat(62), left: CGFloat(0), bottom: CGFloat(34), right: CGFloat(0))

    private func environment(
        bounds: CGRect? = nil,
        insets: (top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat)? = nil,
        keyboard: CGRect? = nil,
        rtl: Bool = false
    ) -> RCMenuLayout.Environment {
        let bounds = bounds ?? phone
        let insets = insets ?? phoneInsets
        let safe = CGRect(
            x: bounds.minX + insets.left,
            y: bounds.minY + insets.top,
            width: bounds.width - insets.left - insets.right,
            height: bounds.height - insets.top - insets.bottom
        )
        return RCMenuLayout.Environment(bounds: bounds, safeArea: safe, keyboard: keyboard, isRightToLeft: rtl)
    }

    private func place(
        content: CGSize,
        anchor: CGRect,
        direction: RCMenu.Direction = .automatic,
        alignment: RCMenu.Alignment = .automatic,
        in environment: RCMenuLayout.Environment? = nil
    ) -> RCMenuPlacement {
        RCMenuLayout.place(contentSize: content, anchor: anchor, direction: direction, alignment: alignment, in: environment ?? self.environment())
    }

    // MARK: Vertical

    func testOpensBelowAnchorWithGapByDefault() {
        let anchor = CGRect(x: 20, y: 200, width: 100, height: 36)
        let placement = place(content: CGSize(width: 240, height: 200), anchor: anchor)
        XCTAssertEqual(placement.edge, .below)
        XCTAssertEqual(placement.frame.minY, anchor.maxY + 8)
        XCTAssertEqual(placement.frame.height, 200)
        XCTAssertFalse(placement.scrolls)
        XCTAssertEqual(placement.transformOrigin.y, 0)
    }

    func testFlipsAboveWhenThereIsNoRoomBelow() {
        let anchor = CGRect(x: 20, y: 760, width: 100, height: 36)
        let placement = place(content: CGSize(width: 240, height: 220), anchor: anchor)
        XCTAssertEqual(placement.edge, .above)
        XCTAssertEqual(placement.frame.maxY, anchor.minY - 8)
        XCTAssertFalse(placement.scrolls)
        XCTAssertEqual(placement.transformOrigin.y, 1)
    }

    func testUpPreferenceFlipsDownWhenThereIsNoRoomAbove() {
        let anchor = CGRect(x: 20, y: 80, width: 100, height: 36)
        let placement = place(content: CGSize(width: 240, height: 200), anchor: anchor, direction: .up)
        XCTAssertEqual(placement.edge, .below)
        XCTAssertEqual(placement.frame.minY, anchor.maxY + 8)
    }

    func testUpPreferenceStaysAboveWhenItFits() {
        let anchor = CGRect(x: 20, y: 500, width: 100, height: 36)
        let placement = place(content: CGSize(width: 240, height: 200), anchor: anchor, direction: .up)
        XCTAssertEqual(placement.edge, .above)
        XCTAssertEqual(placement.frame.maxY, anchor.minY - 8)
    }

    func testAutomaticPicksLargerSideWhenNeitherFitsButExplicitDirectionHolds() {
        // Below: 832 − 544 = 288. Above: 492 − 70 = 422. Content 600 fits neither.
        let anchor = CGRect(x: 20, y: 500, width: 100, height: 36)
        let content = CGSize(width: 240, height: 600)

        let automatic = place(content: content, anchor: anchor)
        XCTAssertEqual(automatic.edge, .above)
        XCTAssertTrue(automatic.scrolls)
        XCTAssertEqual(automatic.frame.height, 422)
        XCTAssertEqual(automatic.frame.minY, 70, "Clamped to safe area top + margin")

        let down = place(content: content, anchor: anchor, direction: .down)
        XCTAssertEqual(down.edge, .below)
        XCTAssertTrue(down.scrolls)
        XCTAssertEqual(down.frame.height, 288)
        XCTAssertEqual(down.frame.maxY, 874 - 34 - 8)
    }

    func testExplicitDirectionGivesUpWhenPreferredSideIsTooSmall() {
        let anchor = CGRect(x: 20, y: 780, width: 100, height: 36)
        let placement = place(content: CGSize(width: 240, height: 900), anchor: anchor, direction: .down)
        XCTAssertEqual(placement.edge, .above)
        XCTAssertTrue(placement.scrolls)
    }

    func testTallContentIsClampedAndScrolls() {
        let anchor = CGRect(x: 20, y: 120, width: 100, height: 36)
        let placement = place(content: CGSize(width: 240, height: 2000), anchor: anchor)
        XCTAssertEqual(placement.edge, .below)
        XCTAssertTrue(placement.scrolls)
        XCTAssertEqual(placement.frame.maxY, 874 - 34 - 8)
        XCTAssertEqual(placement.maximumHeight, placement.frame.height)
    }

    func testAnchorCoveringTheScreenStillGetsAUsablePanelInsideLimits() {
        let placement = place(content: CGSize(width: 240, height: 300), anchor: phone)
        let limits = RCMenuLayout.limits(in: environment())
        XCTAssertGreaterThanOrEqual(placement.frame.height, 96)
        XCTAssertTrue(limits.contains(placement.frame), "\(placement.frame) outside \(limits)")
    }

    // MARK: Width

    func testWidthHonorsMinimumMaximumAndAnchorWidth() {
        let anchor = CGRect(x: 20, y: 200, width: 100, height: 36)
        XCTAssertEqual(place(content: CGSize(width: 90, height: 100), anchor: anchor).frame.width, 220)
        XCTAssertEqual(place(content: CGSize(width: 500, height: 100), anchor: anchor).frame.width, 320)
        let wideAnchor = CGRect(x: 20, y: 200, width: 280, height: 44)
        XCTAssertEqual(place(content: CGSize(width: 90, height: 100), anchor: wideAnchor).frame.width, 280)
        let fullWidthAnchor = CGRect(x: 20, y: 200, width: 362, height: 44)
        XCTAssertEqual(place(content: CGSize(width: 90, height: 100), anchor: fullWidthAnchor).frame.width, 320)
    }

    func testNarrowContainerShrinksBelowMinimumWidth() {
        let slideOver = CGRect(x: 0, y: 0, width: 200, height: 700)
        let env = environment(bounds: slideOver, insets: (20, 0, 20, 0))
        let placement = place(content: CGSize(width: 260, height: 100), anchor: CGRect(x: 10, y: 100, width: 40, height: 40), in: env)
        XCTAssertEqual(placement.frame.width, 184)
        XCTAssertEqual(placement.frame.minX, 8)
    }

    func testIPadKeepsMaximumWidthForWideAnchors() {
        let iPad = CGRect(x: 0, y: 0, width: 1032, height: 1376)
        let env = environment(bounds: iPad, insets: (24, 0, 20, 0))
        let anchor = CGRect(x: 206, y: 300, width: 620, height: 52)
        let placement = place(content: CGSize(width: 180, height: 200), anchor: anchor, in: env)
        XCTAssertEqual(placement.frame.width, 320)
        XCTAssertEqual(placement.frame.minX, 206, "Centered wide anchor: tie goes to the leading edge")
    }

    // MARK: Horizontal

    func testAutomaticAlignmentGrowsAwayFromTheNearerEdge() {
        let left = CGRect(x: 20, y: 200, width: 40, height: 40)
        XCTAssertEqual(place(content: CGSize(width: 240, height: 100), anchor: left).frame.minX, left.minX)
        let right = CGRect(x: 342, y: 200, width: 40, height: 40)
        XCTAssertEqual(place(content: CGSize(width: 240, height: 100), anchor: right).frame.maxX, right.maxX)
    }

    func testCenteredNarrowAnchorGetsACenteredPanel() {
        let anchor = CGRect(x: 181, y: 700, width: 40, height: 40)
        let placement = place(content: CGSize(width: 240, height: 200), anchor: anchor)
        XCTAssertEqual(placement.frame.midX, anchor.midX, accuracy: 0.001)
        XCTAssertEqual(placement.transformOrigin.x, 0.5, accuracy: 0.001)
    }

    func testLeadingAndTrailingFollowLayoutDirection() {
        let anchor = CGRect(x: 130, y: 200, width: 140, height: 40)
        let content = CGSize(width: 240, height: 100)
        XCTAssertEqual(place(content: content, anchor: anchor, alignment: .leading).frame.minX, 130)
        XCTAssertEqual(place(content: content, anchor: anchor, alignment: .trailing).frame.maxX, 270)
        let rtl = environment(rtl: true)
        XCTAssertEqual(place(content: content, anchor: anchor, alignment: .leading, in: rtl).frame.maxX, 270)
        XCTAssertEqual(place(content: content, anchor: anchor, alignment: .trailing, in: rtl).frame.minX, 130)
    }

    func testCenterAlignmentIsClampedToMargins() {
        let anchor = CGRect(x: 354, y: 200, width: 40, height: 40)
        let placement = place(content: CGSize(width: 240, height: 100), anchor: anchor, alignment: .center)
        XCTAssertEqual(placement.frame.maxX, 402 - 8)
        // The motion origin still points at the anchor, inside the panel.
        let originX = placement.frame.minX + placement.transformOrigin.x * placement.frame.width
        XCTAssertEqual(originX, anchor.midX, accuracy: 0.001)
    }

    func testTransformOriginIsClampedInsidePanel() {
        let anchor = CGRect(x: -60, y: 200, width: 40, height: 40)
        let placement = place(content: CGSize(width: 240, height: 100), anchor: anchor)
        XCTAssertEqual(placement.frame.minX, 8)
        XCTAssertEqual(placement.transformOrigin.x, 0)
    }

    func testLandscapeRespectsHorizontalSafeAreaAndScrolls() {
        let landscape = CGRect(x: 0, y: 0, width: 874, height: 402)
        let env = environment(bounds: landscape, insets: (0, 62, 21, 62))
        let anchor = CGRect(x: 40, y: 40, width: 44, height: 44)
        let placement = place(content: CGSize(width: 240, height: 400), anchor: anchor, in: env)
        XCTAssertEqual(placement.edge, .below)
        XCTAssertTrue(placement.scrolls)
        XCTAssertEqual(placement.frame.minX, 62 + 8, "Clamped out of the sensor housing inset")
        XCTAssertEqual(placement.frame.maxY, 402 - 21 - 8)
    }

    // MARK: Keyboard

    func testDockedKeyboardLimitsTheBottomAndFlipsTheMenu() {
        let keyboard = CGRect(x: 0, y: 874 - 336, width: 402, height: 336)
        let env = environment(keyboard: keyboard)
        XCTAssertEqual(RCMenuLayout.limits(in: env).maxY, keyboard.minY - 8)
        let anchor = CGRect(x: 20, y: 400, width: 100, height: 36)
        let placement = place(content: CGSize(width: 240, height: 200), anchor: anchor, in: env)
        XCTAssertEqual(placement.edge, .above)
        XCTAssertLessThanOrEqual(placement.frame.maxY, keyboard.minY)
    }

    func testFloatingOrOffscreenKeyboardIsIgnored() {
        let floating = CGRect(x: 100, y: 300, width: 300, height: 200)
        XCTAssertEqual(RCMenuLayout.limits(in: environment(keyboard: floating)), RCMenuLayout.limits(in: environment()))
        let offscreen = CGRect(x: 0, y: 874, width: 402, height: 336)
        XCTAssertEqual(RCMenuLayout.limits(in: environment(keyboard: offscreen)), RCMenuLayout.limits(in: environment()))
    }

    // MARK: Context menu

    func testContextMenuSitsBelowLiftedPreviewWhenItFits() {
        let source = CGRect(x: 20, y: 200, width: 362, height: 80)
        let result = RCMenuLayout.placeContextMenu(contentSize: CGSize(width: 250, height: 200), source: source, in: environment())
        XCTAssertEqual(result.previewScale, 1.02)
        XCTAssertEqual(result.previewFrame.midY, source.midY, accuracy: 0.001)
        XCTAssertEqual(result.previewFrame.width, source.width * 1.02, accuracy: 0.001)
        XCTAssertEqual(result.menu.edge, .below)
        XCTAssertEqual(result.menu.frame.minY, result.previewFrame.maxY + 8, accuracy: 0.001)
        XCTAssertEqual(result.menu.frame.minX, result.previewFrame.minX, accuracy: 0.001, "Aligned to the preview's leading edge")
    }

    func testContextMenuGoesAboveNearTheBottom() {
        let source = CGRect(x: 20, y: 650, width: 362, height: 80)
        let result = RCMenuLayout.placeContextMenu(contentSize: CGSize(width: 250, height: 200), source: source, in: environment())
        XCTAssertEqual(result.menu.edge, .above)
        XCTAssertEqual(result.menu.frame.maxY, result.previewFrame.minY - 8, accuracy: 0.001)
        XCTAssertEqual(result.previewFrame.midY, source.midY, accuracy: 0.001)
    }

    func testContextPreviewShiftsUpWhenMenuFitsOnNeitherSide() {
        let source = CGRect(x: 20, y: 300, width: 362, height: 150)
        let content = CGSize(width: 250, height: 420)
        let result = RCMenuLayout.placeContextMenu(contentSize: content, source: source, in: environment())
        let limits = RCMenuLayout.limits(in: environment())
        XCTAssertEqual(result.menu.edge, .below)
        XCTAssertFalse(result.menu.scrolls)
        XCTAssertLessThan(result.previewFrame.midY, source.midY, "Preview moved up")
        XCTAssertEqual(result.menu.frame.maxY, limits.maxY, accuracy: 0.001)
        XCTAssertEqual(result.menu.frame.minY, result.previewFrame.maxY + 8, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(result.previewFrame.minY, limits.minY)
    }

    func testContextPreviewShrinksAndMenuScrollsWhenNothingElseFits() {
        let source = CGRect(x: 20, y: 70, width: 362, height: 700)
        let result = RCMenuLayout.placeContextMenu(contentSize: CGSize(width: 250, height: 400), source: source, in: environment())
        let limits = RCMenuLayout.limits(in: environment())
        XCTAssertLessThan(result.previewScale, 1)
        XCTAssertGreaterThanOrEqual(result.previewScale, 0.5)
        XCTAssertTrue(limits.contains(result.menu.frame.integral.insetBy(dx: 1, dy: 1)))
        XCTAssertGreaterThanOrEqual(result.menu.frame.height, 96)
        XCTAssertGreaterThanOrEqual(result.menu.frame.minY, result.previewFrame.maxY + 8 - 0.001)
    }

    func testFullBleedSourceScalesToFitTheWidth() {
        let source = CGRect(x: 0, y: 300, width: 402, height: 90)
        let result = RCMenuLayout.placeContextMenu(contentSize: CGSize(width: 250, height: 200), source: source, in: environment())
        XCTAssertEqual(result.previewFrame.width, 386, accuracy: 0.001)
        XCTAssertEqual(result.previewFrame.minX, 8, accuracy: 0.001)
    }
}
