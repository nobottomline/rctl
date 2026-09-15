import XCTest
@testable import RctlUIKit

/// Where the editor comes to rest when it scrolls to reveal a field: at the
/// top, or with a solid bar and a clear gap below it, never half revealed.
final class LocalDeviceEditorRestingOffsetTests: XCTestCase {
    /// iPhone SE-like editor: 64 pt bar, title, three-line intro, fields, trust callout, button.
    private let bar: CGFloat = 64
    private let title = CGRect(x: 20, y: 68, width: 335, height: 41)
    private let intro = CGRect(x: 20, y: 117, width: 335, height: 66)
    private let address = CGRect(x: 20, y: 207, width: 335, height: 74)
    private let nameField = CGRect(x: 20, y: 293, width: 335, height: 74)
    private let trust = CGRect(x: 20, y: 387, width: 335, height: 70)
    private let button = CGRect(x: 20, y: 481, width: 335, height: 52)
    private let clearance = LocalDeviceEditorViewController.restingClearance

    private var blocks: [CGRect] { [title, intro, address, nameField, trust, button] }

    func testStopsNeedASolidBarAndClearGapBelowIt() {
        let stops = LocalDeviceEditorViewController.restingStops(blocks: blocks.shuffled(), barHeight: bar, clearance: clearance)
        // title → intro is an 8 pt gap: too tight to rest in.
        XCTAssertEqual(stops.first, (intro.maxY - bar)...(address.minY - bar - clearance))
        for stop in stops {
            XCTAssertGreaterThanOrEqual(stop.lowerBound, title.maxY - bar, "The large title is fully under the bar, so the bar is solid")
            let barBottom = stop.lowerBound + bar
            let below = blocks.filter { $0.minY >= barBottom }.map(\.minY).min() ?? .greatestFiniteMagnitude
            XCTAssertGreaterThanOrEqual(below - barBottom, clearance, "The next block starts at least 12 pt below the bar")
            XCTAssertFalse(blocks.contains { $0.minY < barBottom && $0.maxY > barBottom }, "No block is cut by the bar edge")
        }
        XCTAssertTrue(LocalDeviceEditorViewController.restingStops(blocks: [], barHeight: bar, clearance: clearance).isEmpty)
    }

    func testFieldVisibleAtTheTopKeepsTheLargeTitle() {
        let stops = LocalDeviceEditorViewController.restingStops(blocks: blocks, barHeight: bar, clearance: clearance)
        // Showing the button too would need a scroll no resting offset allows (every gap past it hides
        // the focused field), but the field shows at the top: stay there.
        let offset = LocalDeviceEditorViewController.restingOffset(desired: 30, earliest: -40, latest: 100, stops: stops, maximum: 400)
        XCTAssertEqual(offset, 0)
        XCTAssertEqual(LocalDeviceEditorViewController.restingOffset(desired: 0, earliest: 20, latest: 100, stops: stops, maximum: 400), 0)
    }

    func testRevealSnapsForwardToAGapThatKeepsTheFieldBelowTheBar() {
        let stops = LocalDeviceEditorViewController.restingStops(blocks: blocks, barHeight: bar, clearance: clearance)
        // Name field focused with a short visible area: 30 pt of scroll would clip the intro under a half-solid bar.
        let offset = LocalDeviceEditorViewController.restingOffset(desired: 30, earliest: 20, latest: nameField.minY - bar - clearance, stops: stops, maximum: 400)
        XCTAssertEqual(offset, intro.maxY - bar)
    }

    func testRevealFallsBackToAnEarlierGapThatStillShowsTheField() {
        let stops = LocalDeviceEditorViewController.restingStops(blocks: blocks, barHeight: bar, clearance: clearance)
        let desired: CGFloat = 125
        let offset = LocalDeviceEditorViewController.restingOffset(desired: desired, earliest: 100, latest: address.minY - bar - clearance, stops: stops, maximum: 400)
        XCTAssertEqual(offset, desired, "Inside a gap the desired offset itself rests cleanly")
        // Past the last usable gap: back off to it while the field stays above the keyboard.
        let backed = LocalDeviceEditorViewController.restingOffset(desired: 200, earliest: 100, latest: 270, stops: [stops[0]], maximum: 400)
        XCTAssertEqual(backed, stops[0].upperBound)
    }

    func testUnreachableStopsAreIgnored() {
        let stops = LocalDeviceEditorViewController.restingStops(blocks: blocks, barHeight: bar, clearance: clearance)
        let offset = LocalDeviceEditorViewController.restingOffset(desired: 30, earliest: 20, latest: 500, stops: stops, maximum: 10)
        XCTAssertEqual(offset, 30, "Without a reachable stop the reveal scrolls exactly as far as needed")
    }
}
