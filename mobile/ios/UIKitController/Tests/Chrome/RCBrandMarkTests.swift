import XCTest
@testable import RctlUIKit

@MainActor
final class RCBrandMarkTests: XCTestCase {
    private var host: PrimitiveTestHost!

    override func setUp() async throws {
        host = PrimitiveTestHost()
    }

    override func tearDown() async throws {
        host.tearDown()
        host = nil
    }

    /// The artwork as live layers (how the mark used to be drawn).
    private final class LiveArtworkView: UIView {
        let parts = RCBrandMarkLayers(includesBase: true, includesMarks: true)

        init(side: CGFloat, isDark: Bool) {
            super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
            overrideUserInterfaceStyle = isDark ? .dark : .light
            withoutImplicitAnimations {
                parts.applyColors(isDark: isDark)
                parts.layout(in: bounds)
                parts.all.forEach(layer.addSublayer)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }
    }

    func testStaticMarkIsASingleCachedBitmap() {
        let mark = RCBrandMark(side: 32)
        let twin = RCBrandMark(side: 32)
        host.add(mark, frame: CGRect(x: 20, y: 100, width: 32, height: 32))
        host.add(twin, frame: CGRect(x: 80, y: 100, width: 32, height: 32))
        XCTAssertTrue(mark.isShowingStaticArtwork)
        XCTAssertEqual(mark.layer.sublayers?.count ?? 0, 0, "no gradient, mask or shadow layers at rest")
        XCTAssertNotNil(mark.layer.contents)
        XCTAssertTrue((mark.layer.contents as AnyObject?) === (twin.layer.contents as AnyObject?), "one bitmap per size, scale and appearance")

        let lightContents = mark.layer.contents as AnyObject?
        mark.overrideUserInterfaceStyle = .dark
        mark.layoutIfNeeded()
        XCTAssertFalse((mark.layer.contents as AnyObject?) === lightContents, "the console edge is part of the dark artwork")
    }

    func testBitmapMatchesTheLiveLayerArtworkOnScreen() throws {
        for (side, isDark) in [(CGFloat(64), false), (28, true), (36, false)] {
            let mark = RCBrandMark(side: side)
            mark.overrideUserInterfaceStyle = isDark ? .dark : .light
            let live = LiveArtworkView(side: side, isDark: isDark)
            host.add(mark, frame: CGRect(x: 20, y: 100, width: side, height: side))
            host.add(live, frame: CGRect(x: 120, y: 100, width: side, height: side))
            let bitmap = try XCTUnwrap(TestPixels.snapshot(mark))
            let reference = try XCTUnwrap(TestPixels.snapshot(live))
            let difference = try XCTUnwrap(bitmap.difference(from: reference))
            let context = "\(side) pt \(isDark ? "dark" : "light"): \(difference)"
            let scale = host.window.screen.scale
            XCTAssertGreaterThan(difference.coverage.1, Double(side * side * scale * scale) * 0.8, context)
            // Only edge anti-aliasing (continuous plate corners, ring edges) may
            // differ; a shift, blur or color change is several times larger.
            XCTAssertLessThanOrEqual(difference.mean, 2.0, context)
            XCTAssertLessThanOrEqual(difference.strongShare, 0.03, context)
            mark.removeFromSuperview()
            live.removeFromSuperview()
        }
    }

    func testPulseUsesLiveMarksOnlyWhileItRuns() async throws {
        let mark = RCBrandMark(side: 44)
        host.add(mark, frame: CGRect(x: 20, y: 100, width: 44, height: 44))
        let restingContents = mark.layer.contents as AnyObject?
        mark.pulse()
        XCTAssertFalse(mark.isShowingStaticArtwork)
        XCTAssertEqual(mark.layer.sublayers?.count, 5, "rings, ripple, dot and core")
        XCTAssertFalse((mark.layer.contents as AnyObject?) === restingContents, "the ground under the pulse has no marks")
        mark.pulse() // A second pulse restarts instead of stacking layers.
        XCTAssertEqual(mark.layer.sublayers?.count, 5)

        let merged = await pollUntil(timeout: RCBrandMark.pulseDuration + 2) { mark.isShowingStaticArtwork }
        XCTAssertTrue(merged)
        XCTAssertEqual(mark.layer.sublayers?.count ?? 0, 0)
        XCTAssertTrue((mark.layer.contents as AnyObject?) === restingContents)
    }
}
