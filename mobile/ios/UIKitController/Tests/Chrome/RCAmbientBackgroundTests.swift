import XCTest
@testable import RctlUIKit

final class RCAmbientCompositionTests: XCTestCase {
    private let phone = CGSize(width: 402, height: 874)
    private let smallPhone = CGSize(width: 375, height: 667)
    private let iPad = CGSize(width: 1032, height: 1376)

    func testSameSizeAndSeedIsDeterministic() {
        XCTAssertEqual(RCAmbientComposition(size: phone), RCAmbientComposition(size: phone))
        XCTAssertNotEqual(RCAmbientComposition(size: phone, seed: 1), RCAmbientComposition(size: phone, seed: 2))
    }

    func testMoteCountIsSparseOnEveryScreen() {
        for size in [smallPhone, phone, CGSize(width: 440, height: 956), iPad, CGSize(width: 1376, height: 1032)] {
            let count = RCAmbientComposition.moteCount(for: size)
            XCTAssertTrue((18...28).contains(count), "\(size) → \(count)")
        }
        XCTAssertEqual(RCAmbientComposition.moteCount(for: CGSize(width: 300, height: 200)), RCAmbientComposition.minimumMotes)
    }

    func testRotationKeepsBloomSizes() {
        let portrait = RCAmbientComposition(size: phone)
        let landscape = RCAmbientComposition(size: CGSize(width: phone.height, height: phone.width))
        XCTAssertEqual(portrait.blooms.map(\.radius), landscape.blooms.map(\.radius))
        XCTAssertEqual(portrait.motes.count, landscape.motes.count)
    }

    func testMotesEnterAndLeaveOutsideTheCanvas() {
        for size in [smallPhone, phone, iPad] {
            let composition = RCAmbientComposition(size: size)
            let visible = CGRect(origin: .zero, size: size)
            for mote in composition.motes {
                let halfSide = mote.frameSide / 2
                XCTAssertFalse(visible.insetBy(dx: -halfSide, dy: -halfSide).contains(mote.start), "start \(mote.start) visible in \(size)")
                XCTAssertFalse(visible.insetBy(dx: -halfSide, dy: -halfSide).contains(mote.end), "end \(mote.end) visible in \(size)")
                XCTAssertGreaterThanOrEqual(mote.duration, 24, "Motes drift slowly")
                XCTAssertTrue((1.5...4).contains(mote.diameter))
                XCTAssertTrue((0..<1).contains(mote.phase))
            }
        }
    }

    func testFieldMixesDotsHalosAndRings() {
        let kinds = RCAmbientComposition(size: phone).motes.map(\.kind)
        XCTAssertTrue(kinds.contains(.halo))
        XCTAssertTrue(kinds.contains(.ring))
        XCTAssertGreaterThan(kinds.filter { $0 == .dot }.count, kinds.count / 2)
    }

    func testFadeEnvelopeIsInvisibleAtPathEnds() {
        XCTAssertEqual(RCAmbientComposition.fadeEnvelope(at: 0), 0)
        XCTAssertEqual(RCAmbientComposition.fadeEnvelope(at: 1), 0)
        XCTAssertEqual(RCAmbientComposition.fadeEnvelope(at: 0.5), 1)
        XCTAssertEqual(RCAmbientComposition.fadeEnvelope(at: 0.05), 0.5, accuracy: 0.001)
    }

    func testCrossingFindsBothEdges() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 200)
        let (entry, exit) = RCAmbientComposition.crossing(of: rect, through: CGPoint(x: 50, y: 100), direction: CGVector(dx: 0, dy: -1))
        XCTAssertEqual(entry, CGPoint(x: 50, y: 200))
        XCTAssertEqual(exit, CGPoint(x: 50, y: 0))
    }
}

@MainActor
final class RCAmbientBackgroundViewTests: XCTestCase {
    func testLayerBudgetOnLargestCanvas() {
        let view = RCAmbientBackgroundView(frame: CGRect(x: 0, y: 0, width: 1376, height: 1032))
        view.layoutIfNeeded()
        XCTAssertNotNil(view.composition)
        XCTAssertLessThanOrEqual(view.layerCount, 40)
    }

    func testNoMotionOutsideAWindow() {
        let view = RCAmbientBackgroundView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.layoutIfNeeded()
        XCTAssertFalse(view.isMotionRunning)
        view.isPaused = false
        XCTAssertFalse(view.isMotionRunning)
    }

    func testAnimationsExistUnlessReduceMotion() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled)
        let view = RCAmbientBackgroundView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.layoutIfNeeded()
        let animated = view.layer.sublayers?.flatMap { $0.sublayers ?? [] }.filter { !($0.animationKeys() ?? []).isEmpty } ?? []
        XCTAssertGreaterThanOrEqual(animated.count, RCAmbientComposition.moteCount(for: CGSize(width: 402, height: 874)))
    }

    func testAppearanceChangeKeepsComposition() {
        let view = RCAmbientBackgroundView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.layoutIfNeeded()
        let before = view.composition
        let layers = view.layerCount
        view.overrideUserInterfaceStyle = .dark
        view.traitCollectionDidChange(UITraitCollection(userInterfaceStyle: .light))
        view.layoutIfNeeded()
        XCTAssertEqual(view.composition, before)
        XCTAssertEqual(view.layerCount, layers)
    }

    func testResizeRegeneratesComposition() {
        let view = RCAmbientBackgroundView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        view.layoutIfNeeded()
        view.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        view.layoutIfNeeded()
        XCTAssertEqual(view.composition?.size, CGSize(width: 874, height: 402))
    }
}

@MainActor
final class RCLayerClockTests: XCTestCase {
    func testFreezeStopsTimeAndResumeContinuesWithoutJump() async throws {
        let layer = CALayer()
        RCLayerClock.freeze(layer)
        let frozen = RCLayerClock.localTime(of: layer)
        try await Task.sleep(seconds: 0.08)
        XCTAssertEqual(RCLayerClock.localTime(of: layer), frozen, accuracy: 0.0001, "Frozen time must not advance")
        RCLayerClock.resume(layer)
        XCTAssertEqual(RCLayerClock.localTime(of: layer), frozen, accuracy: 0.01, "Resuming must not jump")
        try await Task.sleep(seconds: 0.05)
        XCTAssertGreaterThan(RCLayerClock.localTime(of: layer), frozen + 0.03)
        RCLayerClock.resume(layer)
        XCTAssertEqual(layer.speed, 1, "Resuming a running layer is a no-op")
    }
}
