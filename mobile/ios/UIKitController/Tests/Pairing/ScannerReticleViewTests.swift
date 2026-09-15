import UIKit
import XCTest
@testable import RctlUIKit

/// The idle pulse is bounded (area, duration, caching) and never interferes
/// with window target changes.
@MainActor
final class ScannerReticleViewTests: XCTestCase {
    private let stage = CGRect(x: 0, y: 0, width: 402, height: 874)
    private let resting = CGRect(x: 51, y: 250, width: 300, height: 300)
    private let detected = CGRect(x: 120, y: 480, width: 182, height: 182)

    private func makeReticle() -> ScannerReticleView {
        let reticle = ScannerReticleView(frame: stage)
        reticle.restingRect = resting
        reticle.layoutIfNeeded()
        return reticle
    }

    private func apply(_ reticle: ScannerReticleView, target: CGRect, breathing: Bool, dims: Bool = false, animated: Bool) {
        reticle.apply(
            target: target,
            tone: breathing ? .searching : .locked,
            showsBadge: !breathing,
            showsCaption: false,
            dimsWindow: dims,
            breathing: breathing,
            animated: animated
        )
    }

    private var breatheKey: String { ScannerReticleView.breatheKeyForTesting }

    func testBreathingIsConfinedToTheRestingWindowAndStopsAfterAFewBreaths() throws {
        let reticle = makeReticle()
        apply(reticle, target: resting, breathing: true, animated: false)
        let group = reticle.breathingLayerForTesting
        XCTAssertLessThan(group.bounds.width, stage.width * 0.9, "The pulse must not scale a stage-sized layer")
        XCTAssertEqual(group.position.x, resting.midX, accuracy: 0.5)
        XCTAssertEqual(group.position.y, resting.midY, accuracy: 0.5)
        XCTAssertTrue(group.bounds.contains(resting))
        let pulse = try XCTUnwrap(group.animation(forKey: breatheKey))
        XCTAssertEqual(pulse.repeatCount, ScannerReticleView.breathCycles)
        XCTAssertTrue(pulse.repeatCount.isFinite)
        XCTAssertTrue(pulse.isRemovedOnCompletion)
        XCTAssertTrue(group.shouldRasterize, "A still window pulses from a cached bitmap")
    }

    func testTargetChangeStopsBreathingAndRasterizationBeforeTheSpring() throws {
        let reticle = makeReticle()
        apply(reticle, target: resting, breathing: true, animated: false)
        apply(reticle, target: detected, breathing: false, animated: true)
        let group = reticle.breathingLayerForTesting
        XCTAssertNil(group.animation(forKey: breatheKey))
        XCTAssertFalse(group.shouldRasterize, "Springing paths must not re-rasterize every frame")
        XCTAssertEqual(reticle.target, detected)
        let brackets = reticle.bracketsLayerForTesting
        let expected = ScannerReticlePaths.brackets(in: detected, cornerRadius: ScannerGeometry.windowCornerRadius,
                                                    length: ScannerGeometry.bracketLength(forWindowWidth: detected.width))
        XCTAssertEqual(brackets.path, expected, "The model path is the new target immediately")
        XCTAssertNotNil(brackets.animation(forKey: "rc.reticle.path"))
    }

    func testBreathingResumesOnlyAfterTheReturnSpringSettles() throws {
        let reticle = makeReticle()
        apply(reticle, target: resting, breathing: true, animated: false)
        apply(reticle, target: detected, breathing: false, animated: true)
        apply(reticle, target: resting, breathing: true, animated: true)
        let group = reticle.breathingLayerForTesting
        let pulse = try XCTUnwrap(group.animation(forKey: breatheKey))
        let now = group.convertTime(CACurrentMediaTime(), from: nil)
        XCTAssertGreaterThan(pulse.beginTime, now + 0.2, "The pulse waits for the window spring")
        XCTAssertFalse(group.shouldRasterize, "No cached bitmap while the paths still spring")
    }

    func testRepeatedBreathingStateDoesNotRestartThePulse() throws {
        let reticle = makeReticle()
        apply(reticle, target: resting, breathing: true, animated: false)
        let first = try XCTUnwrap(reticle.breathingLayerForTesting.animation(forKey: breatheKey))
        apply(reticle, target: resting, breathing: true, animated: true)
        let second = try XCTUnwrap(reticle.breathingLayerForTesting.animation(forKey: breatheKey))
        XCTAssertEqual(first.beginTime, second.beginTime)
    }

    func testPairingDimsTheWindowAndFollowsTheTarget() {
        let reticle = makeReticle()
        apply(reticle, target: detected, breathing: false, dims: false, animated: false)
        XCTAssertEqual(reticle.windowDimLayerForTesting.opacity, 0)
        apply(reticle, target: detected, breathing: false, dims: true, animated: true)
        XCTAssertEqual(reticle.windowDimLayerForTesting.opacity, 1)
        XCTAssertEqual(reticle.windowDimLayerForTesting.path,
                       ScannerReticlePaths.roundedRect(detected, cornerRadius: ScannerGeometry.windowCornerRadius))
        apply(reticle, target: resting, breathing: true, dims: false, animated: true)
        XCTAssertEqual(reticle.windowDimLayerForTesting.opacity, 0)
    }
}
