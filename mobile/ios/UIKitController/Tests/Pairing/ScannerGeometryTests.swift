import CoreGraphics
import XCTest
@testable import RctlUIKit

final class ScannerGeometryTests: XCTestCase {
    func testRestingRectOnSmallPhone() {
        // iPhone SE portrait: 375 × 667 with a 20 pt status bar.
        let safe = CGRect(x: 0, y: 20, width: 375, height: 647)
        let rect = ScannerGeometry.restingRect(safeFrame: safe)
        XCTAssertEqual(rect.width, 375 * 0.62, accuracy: 0.001)
        XCTAssertEqual(rect.height, rect.width)
        XCTAssertEqual(rect.midX, safe.midX, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 20 + 647 * 0.44, accuracy: 0.001)
    }

    func testRestingSideIsClamped() {
        let tiny = ScannerGeometry.restingRect(safeFrame: CGRect(x: 0, y: 0, width: 300, height: 300))
        XCTAssertEqual(tiny.width, 220)
        let tablet = ScannerGeometry.restingRect(safeFrame: CGRect(x: 0, y: 24, width: 1032, height: 1332))
        XCTAssertEqual(tablet.width, 300)
    }

    func testRestingRectRespectsHorizontalInsets() {
        // Landscape phone with notch insets: centered in the safe area, not the screen.
        let safe = CGRect(x: 59, y: 0, width: 734, height: 372)
        let rect = ScannerGeometry.restingRect(safeFrame: safe)
        XCTAssertEqual(rect.midX, safe.midX, accuracy: 0.001)
        XCTAssertEqual(rect.width, 372 * 0.62, accuracy: 0.001)
    }

    func testRestingRectStaysBelowTallCopyButAboveControls() {
        let safe = CGRect(x: 0, y: 20, width: 375, height: 647)
        let lowered = ScannerGeometry.restingRect(safeFrame: safe, minimumTop: 240, maximumBottom: 600)
        XCTAssertEqual(lowered.minY, 240)
        let capped = ScannerGeometry.restingRect(safeFrame: safe, minimumTop: 500, maximumBottom: 600)
        XCTAssertEqual(capped.maxY, 600, accuracy: 0.001, "The controls win over the copy")
        let untouched = ScannerGeometry.restingRect(safeFrame: safe, minimumTop: 100, maximumBottom: 640)
        XCTAssertEqual(untouched, ScannerGeometry.restingRect(safeFrame: safe))
    }

    func testTargetFallsBackToRestingWithoutUsableBounds() {
        let resting = CGRect(x: 10, y: 20, width: 240, height: 240)
        XCTAssertEqual(ScannerGeometry.targetRect(detectionBounds: nil, resting: resting), resting)
        XCTAssertEqual(ScannerGeometry.targetRect(detectionBounds: .null, resting: resting), resting)
        XCTAssertEqual(ScannerGeometry.targetRect(detectionBounds: CGRect(x: 0, y: 0, width: 24, height: 80), resting: resting), resting)
    }

    func testTargetIsPaddedSquareAroundCode() {
        let resting = CGRect(x: 0, y: 0, width: 240, height: 240)
        let target = ScannerGeometry.targetRect(detectionBounds: CGRect(x: 100, y: 200, width: 150, height: 150), resting: resting)
        XCTAssertEqual(target, CGRect(x: 84, y: 184, width: 182, height: 182))

        let wide = ScannerGeometry.targetRect(detectionBounds: CGRect(x: 0, y: 0, width: 200, height: 100), resting: resting)
        XCTAssertEqual(wide.width, 232)
        XCTAssertEqual(wide.height, 232)
        XCTAssertEqual(wide.midX, 100)
        XCTAssertEqual(wide.midY, 50)
    }

    func testTargetHasMinimumSide() {
        let target = ScannerGeometry.targetRect(detectionBounds: CGRect(x: 50, y: 50, width: 40, height: 40), resting: .zero)
        XCTAssertEqual(target.width, 120)
        XCTAssertEqual(target.midX, 70)
        XCTAssertEqual(target.midY, 70)
    }

    func testRetargetIgnoresJitterOnly() {
        let current = CGRect(x: 100, y: 100, width: 200, height: 200)
        XCTAssertTrue(ScannerGeometry.shouldRetarget(from: nil, to: current))
        XCTAssertFalse(ScannerGeometry.shouldRetarget(from: current, to: current.offsetBy(dx: 3, dy: -4)))
        XCTAssertTrue(ScannerGeometry.shouldRetarget(from: current, to: current.offsetBy(dx: 5, dy: 0)))
        XCTAssertTrue(ScannerGeometry.shouldRetarget(from: current, to: current.insetBy(dx: -5, dy: -5)))
    }

    func testBracketLengthScalesWithSmallWindows() {
        XCTAssertEqual(ScannerGeometry.bracketLength(forWindowWidth: 300), 34)
        XCTAssertEqual(ScannerGeometry.bracketLength(forWindowWidth: 120), 24)
    }

    func testCaptionPrefersBelowWindow() {
        let window = CGRect(x: 0, y: 200, width: 200, height: 200)
        let y = ScannerGeometry.captionCenterY(window: window, captionHeight: 34, topLimit: 100, bottomLimit: 700)
        XCTAssertEqual(y, 400 + 18 + 17)
    }

    func testCaptionMovesAboveWhenItWouldReachControls() {
        let window = CGRect(x: 0, y: 400, width: 200, height: 200)
        let y = ScannerGeometry.captionCenterY(window: window, captionHeight: 34, topLimit: 100, bottomLimit: 640)
        XCTAssertEqual(y, 400 - 18 - 17)
    }

    func testCaptionAboveNeverCrossesTopLimit() {
        let window = CGRect(x: 0, y: 120, width: 500, height: 500)
        let y = ScannerGeometry.captionCenterY(window: window, captionHeight: 34, topLimit: 110, bottomLimit: 640)
        XCTAssertEqual(y, 110 + 17)
    }

    func testPathsKeepElementStructureForAnyRect() {
        // Core Animation interpolates paths element by element; a different
        // structure would make the reticle jump instead of spring.
        let rects = [
            CGRect(x: 0, y: 0, width: 300, height: 300),
            CGRect(x: 40, y: 90, width: 120, height: 120),
            CGRect(x: 10, y: 10, width: 20, height: 20),
            CGRect(x: 5, y: 5, width: 0, height: 0),
        ]
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let bracketSignatures = Set(rects.map { signature(ScannerReticlePaths.brackets(in: $0, cornerRadius: 24, length: ScannerGeometry.bracketLength(forWindowWidth: $0.width))) })
        let scrimSignatures = Set(rects.map { signature(ScannerReticlePaths.scrim(bounds: bounds, window: $0, cornerRadius: 24)) })
        let outlineSignatures = Set(rects.map { signature(ScannerReticlePaths.roundedRect($0, cornerRadius: 24)) })
        XCTAssertEqual(bracketSignatures.count, 1)
        XCTAssertEqual(scrimSignatures.count, 1)
        XCTAssertEqual(outlineSignatures.count, 1)
    }

    func testBracketStrokeMidpointIsCornerApex() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let path = ScannerReticlePaths.bracket(.topLeft, in: rect, cornerRadius: 20, length: 18)
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let count: Int
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: count = 0
            }
            if count > 0 { points.append(element.pointee.points[count - 1]) }
        }
        XCTAssertEqual(points.first, CGPoint(x: 0, y: 38))
        XCTAssertEqual(points.last, CGPoint(x: 38, y: 0))
    }

    private func signature(_ path: CGPath) -> [Int32] {
        var types: [Int32] = []
        path.applyWithBlock { element in
            types.append(element.pointee.type.rawValue)
        }
        return types
    }
}
