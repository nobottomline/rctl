import UIKit
import XCTest
@testable import RctlUIKit

final class RCSheetLayoutTests: XCTestCase {
    private let phone = RCSheetGeometry(
        style: .bottomSheet,
        containerSize: CGSize(width: 402, height: 874),
        safeAreaInsets: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
        preferredContentHeight: 300
    )

    private let pad = RCSheetGeometry(
        style: .card,
        containerSize: CGSize(width: 1032, height: 1376),
        safeAreaInsets: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0),
        preferredContentHeight: 300
    )

    func testPhoneDetentHeights() {
        XCTAssertEqual(RCSheetLayout.height(for: .large, in: phone), 874 - 62 - 10)
        XCTAssertEqual(RCSheetLayout.height(for: .medium, in: phone), 437)
        XCTAssertEqual(RCSheetLayout.height(for: .fitting, in: phone), 300 + 34, "Fitting adds the bottom safe area")
        XCTAssertEqual(RCSheetLayout.height(for: .height(390), in: phone), 390 + 34)
    }

    func testFittingIsCappedAtLarge() {
        var tall = phone
        tall.preferredContentHeight = 5000
        XCTAssertEqual(RCSheetLayout.height(for: .fitting, in: tall), RCSheetLayout.height(for: .large, in: tall))
        XCTAssertEqual(RCSheetLayout.height(for: .height(5000), in: tall), 802)
    }

    func testFittingWithoutPreferredSizeFallsBackToMedium() {
        var unsized = phone
        unsized.preferredContentHeight = nil
        XCTAssertEqual(RCSheetLayout.height(for: .fitting, in: unsized), RCSheetLayout.height(for: .medium, in: unsized))
    }

    func testKeyboardShrinksLargeAndDropsHomeIndicatorInset() {
        var typing = phone
        typing.keyboardHeight = 336
        XCTAssertEqual(RCSheetLayout.height(for: .large, in: typing), 874 - 336 - 62 - 10)
        XCTAssertEqual(RCSheetLayout.height(for: .fitting, in: typing), 300, "Above the keyboard there is no home indicator to pad")
        let frame = RCSheetLayout.frame(height: 300, in: typing)
        XCTAssertEqual(frame.maxY, 874 - 336, "The sheet sits on top of the keyboard")
    }

    func testResolvedHeightsAreSortedAndDeduplicated() {
        let heights = RCSheetLayout.resolvedHeights(for: [.large, .fitting, .medium, .height(403)], in: phone)
        XCTAssertEqual(heights, [334, 437, 802], "height(403)+34 == medium collapses into one stop")
        XCTAssertEqual(RCSheetLayout.resolvedHeights(for: [], in: phone), [334], "No detents means fitting")
        XCTAssertEqual(RCSheetLayout.index(of: .large, in: heights, geometry: phone), 2)
    }

    func testPhoneFrameIsBottomAttachedAndFullWidth() {
        let frame = RCSheetLayout.frame(height: 334, in: phone)
        XCTAssertEqual(frame, CGRect(x: 0, y: 874 - 334, width: 402, height: 334))
    }

    func testLandscapePhoneUsesReadableColumn() {
        let landscape = RCSheetGeometry(style: .bottomSheet, containerSize: CGSize(width: 874, height: 402), safeAreaInsets: UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62))
        let frame = RCSheetLayout.frame(height: 200, in: landscape)
        XCTAssertEqual(frame.width, 620)
        XCTAssertEqual(frame.midX, 437)
        XCTAssertEqual(frame.maxY, 402)
    }

    func testCardGeometry() {
        XCTAssertEqual(RCSheetLayout.height(for: .fitting, in: pad), 300, "Cards do not add the bottom safe area")
        XCTAssertEqual(RCSheetLayout.height(for: .large, in: pad), 1376 * 0.8, accuracy: 0.5)
        let frame = RCSheetLayout.frame(height: 300, in: pad)
        XCTAssertEqual(frame.width, 540)
        XCTAssertEqual(frame.midX, 516, accuracy: 0.5)
        XCTAssertGreaterThan(frame.minY, 24)
        XCTAssertLessThan(frame.maxY, 1376 - 20)
    }

    func testSnapPicksNearestProjectedDetent() {
        let heights: [CGFloat] = [437, 802]
        XCTAssertEqual(RCSheetLayout.snapTarget(visibleHeight: 600, velocity: 0, detentHeights: heights, isDismissible: true), .detent(0))
        XCTAssertEqual(RCSheetLayout.snapTarget(visibleHeight: 650, velocity: 0, detentHeights: heights, isDismissible: true), .detent(1))
        // An upward flick from medium reaches large.
        XCTAssertEqual(RCSheetLayout.snapTarget(visibleHeight: 480, velocity: -900, detentHeights: heights, isDismissible: true), .detent(1))
        // A downward flick from large lands on medium, not dismissal.
        XCTAssertEqual(RCSheetLayout.snapTarget(visibleHeight: 780, velocity: 900, detentHeights: heights, isDismissible: true), .detent(0))
    }

    func testSnapDismissal() {
        let heights: [CGFloat] = [334]
        XCTAssertEqual(RCSheetLayout.snapTarget(visibleHeight: 300, velocity: 0, detentHeights: heights, isDismissible: true), .detent(0), "Small slow drag springs back")
        XCTAssertEqual(RCSheetLayout.snapTarget(visibleHeight: 150, velocity: 0, detentHeights: heights, isDismissible: true), .dismiss, "Past halfway dismisses")
        XCTAssertEqual(RCSheetLayout.snapTarget(visibleHeight: 320, velocity: 1800, detentHeights: heights, isDismissible: true), .dismiss, "Fast flick dismisses")
        XCTAssertEqual(RCSheetLayout.snapTarget(visibleHeight: 20, velocity: 2000, detentHeights: heights, isDismissible: false), .detent(0), "Never dismisses when not dismissible")
    }

    func testDragStateRubberBandsAndOffsets() {
        let heights: [CGFloat] = [437, 802]
        let between = RCSheetLayout.dragState(visibleHeight: 600, detentHeights: heights, isDismissible: true, resizes: true, restHeight: 437)
        XCTAssertEqual(between, .init(height: 600, stretch: 0, offset: 0))

        let above = RCSheetLayout.dragState(visibleHeight: 1000, detentHeights: heights, isDismissible: true, resizes: true, restHeight: 802)
        XCTAssertEqual(above.height, 802)
        XCTAssertGreaterThan(above.stretch, 0)
        XCTAssertLessThan(above.stretch, 80, "Stretch above the largest detent is rubber-banded")

        let below = RCSheetLayout.dragState(visibleHeight: 300, detentHeights: heights, isDismissible: true, resizes: true, restHeight: 437)
        XCTAssertEqual(below, .init(height: 437, stretch: 0, offset: 137), "Dismissible sheets follow the finger")

        let locked = RCSheetLayout.dragState(visibleHeight: 0, detentHeights: heights, isDismissible: false, resizes: true, restHeight: 437)
        XCTAssertLessThan(locked.offset, 80, "Non-dismissible sheets resist")

        let card = RCSheetLayout.dragState(visibleHeight: 400, detentHeights: [300, 600], isDismissible: true, resizes: false, restHeight: 600)
        XCTAssertEqual(card, .init(height: 600, stretch: 0, offset: 200), "Cards translate instead of resizing")
    }

    func testRubberBandIsMonotonicAndBounded() {
        var previous: CGFloat = 0
        for offset in stride(from: CGFloat(0), through: 2000, by: 50) {
            let value = RCModalSupport.rubberBand(offset, dimension: 80)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThan(value, 80)
            previous = value
        }
    }
}
