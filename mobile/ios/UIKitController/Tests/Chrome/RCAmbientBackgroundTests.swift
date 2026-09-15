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
        let view = RCAmbientBackgroundView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        try XCTSkipIf(view.motionState == .still, "Reduce Motion, Low Power Mode or thermal pressure")
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

/// Motion lifecycle in a real window: idle freeze, overlay freeze, live resize.
@MainActor
final class RCAmbientBackgroundMotionTests: XCTestCase {
    private var host: PrimitiveTestHost!

    override func setUp() async throws {
        host = PrimitiveTestHost()
    }

    override func tearDown() async throws {
        host.tearDown()
        host = nil
    }

    private func makeRunningBackground(idleTimeout: TimeInterval) async throws -> RCAmbientBackgroundView {
        let view = RCAmbientBackgroundView()
        view.idleTimeout = idleTimeout
        host.add(view, frame: host.container.bounds)
        try XCTSkipIf(view.motionState == .still, "Reduce Motion, Low Power Mode or thermal pressure")
        try XCTSkipIf(RCOverlayActivity.isActive, "an overlay from another test is still up")
        XCTAssertFalse(view.isMotionRunning, "motion waits for the warm-up delay")
        let running = await pollUntil(timeout: RCAmbientBackgroundView.motionStartDelay + 2) { view.isMotionRunning }
        try XCTSkipUnless(running || view.motionState != .frozen, "host scene is not active")
        XCTAssertTrue(running)
        return view
    }

    private func assertClockFrozen(_ view: RCAmbientBackgroundView, file: StaticString = #filePath, line: UInt = #line) async -> CFTimeInterval {
        let frozen = view.motionClockTime
        try? await Task.sleep(seconds: 0.12)
        XCTAssertEqual(view.motionClockTime, frozen, accuracy: 0.0001, "layer time must not advance while frozen", file: file, line: line)
        return frozen
    }

    func testIdleTimeoutFreezesAndATouchResumesWithoutAJump() async throws {
        let view = try await makeRunningBackground(idleTimeout: 1.5)
        let idle = await pollUntil(timeout: 4) { view.isIdle }
        XCTAssertTrue(idle)
        XCTAssertFalse(view.isMotionRunning)
        XCTAssertEqual(view.motionState, .frozen)
        let frozen = await assertClockFrozen(view)

        let monitor = try XCTUnwrap(RCAmbientInteractionMonitor.installed(on: host.window))
        monitor.recordInteraction()
        XCTAssertFalse(view.isIdle)
        XCTAssertEqual(view.motionState, .running)
        XCTAssertFalse(view.isMotionRunning, "resumes after the warm-up delay, not instantly")
        let resumed = await pollUntil(timeout: 3) { view.isMotionRunning }
        XCTAssertTrue(resumed)
        XCTAssertEqual(view.motionClockTime, frozen, accuracy: 0.1, "continues where it stopped")
        try? await Task.sleep(seconds: 0.1)
        XCTAssertGreaterThan(view.motionClockTime, frozen + 0.05, "time runs again")
    }

    func testOverlayActivityFreezesImmediatelyAndResumesAfterIt() async throws {
        let view = try await makeRunningBackground(idleTimeout: 600)
        let token = RCOverlayActivity.begin()
        XCTAssertFalse(view.isMotionRunning, "a dialog or menu freezes the backdrop at once")
        XCTAssertEqual(view.motionState, .frozen)
        let frozen = await assertClockFrozen(view)

        token.end()
        XCTAssertEqual(view.motionState, .running)
        let resumed = await pollUntil(timeout: 3) { view.isMotionRunning }
        XCTAssertTrue(resumed)
        XCTAssertEqual(view.motionClockTime, frozen, accuracy: 0.1)
    }

    func testOneSharedPassiveMonitorPerWindow() throws {
        let first = RCAmbientBackgroundView()
        let second = RCAmbientBackgroundView()
        host.add(first, frame: host.container.bounds)
        host.add(second, frame: host.container.bounds)
        let monitors = host.window.gestureRecognizers?.compactMap { $0 as? RCAmbientInteractionMonitor } ?? []
        XCTAssertEqual(monitors.count, 1)
        let monitor = try XCTUnwrap(monitors.first)
        XCTAssertFalse(monitor.cancelsTouchesInView)
        XCTAssertFalse(monitor.delaysTouchesBegan)
        XCTAssertFalse(monitor.delaysTouchesEnded)
        let other = UIPanGestureRecognizer()
        XCTAssertFalse(monitor.canPrevent(other))
        XCTAssertFalse(monitor.canBePrevented(by: other))
        XCTAssertEqual(monitor.delegate?.gestureRecognizer?(monitor, shouldRecognizeSimultaneouslyWith: other), true)

        first.removeFromSuperview()
        XCTAssertNotNil(RCAmbientInteractionMonitor.installed(on: host.window), "still used by the second backdrop")
        second.removeFromSuperview()
        XCTAssertNil(RCAmbientInteractionMonitor.installed(on: host.window), "removed with the last backdrop")
    }

    func testLiveResizeRebuildsOnceTheSizeSettles() async throws {
        let view = RCAmbientBackgroundView()
        host.add(view, frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        XCTAssertEqual(view.composition?.size, CGSize(width: 390, height: 844))
        try? await Task.sleep(seconds: RCAmbientBackgroundView.resizeSettleDelay + 0.1)

        // A single change (rotation) rebuilds immediately.
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 844)
        view.layoutIfNeeded()
        XCTAssertEqual(view.composition?.size.width, 320)

        // Changes following it within the settle delay wait for the last one.
        for width: CGFloat in [300, 280, 260, 240] {
            view.frame = CGRect(x: 0, y: 0, width: width, height: 844)
            view.layoutIfNeeded()
            XCTAssertEqual(view.composition?.size.width, 320, "no rebuild per frame of a live resize")
        }
        let settled = await pollUntil(timeout: 2) { view.composition?.size.width == 240 }
        XCTAssertTrue(settled)
        XCTAssertEqual(view.composition?.motes.count, RCAmbientComposition.moteCount(for: CGSize(width: 240, height: 844)))
    }

    func testNoLayerWithSublayersUsesGroupOpacity() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let view = RCAmbientBackgroundView()
            view.overrideUserInterfaceStyle = style
            host.add(view, frame: host.container.bounds)
            view.intensity = 0.6
            func visit(_ layer: CALayer) {
                if !(layer.sublayers ?? []).isEmpty, !layer.isHidden {
                    XCTAssertTrue(layer.opacity == 1 || !layer.allowsGroupOpacity, "\(layer) would composite offscreen (\(style.rawValue))")
                }
                layer.sublayers?.forEach(visit)
            }
            visit(view.layer)
            view.removeFromSuperview()
        }
    }

    func testMotionAsksForALowFrameRate() throws {
        guard #available(iOS 15.0, *) else { throw XCTSkip("frame rate ranges need iOS 15") }
        let view = RCAmbientBackgroundView()
        host.add(view, frame: host.container.bounds)
        try XCTSkipIf(view.motionState == .still)
        let animations = (view.layer.sublayers ?? []).flatMap { $0.sublayers ?? [] }
            .flatMap { layer in (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) } }
        XCTAssertFalse(animations.isEmpty)
        for animation in animations {
            XCTAssertEqual(animation.preferredFrameRateRange, CAFrameRateRange(minimum: 8, maximum: 20, preferred: 15))
        }
    }
}

@MainActor
final class RCAmbientArtworkTests: XCTestCase {
    func testGrainTileCarriesTheFaintnessInItsAlpha() throws {
        RCAmbientArtwork.purgeCaches()
        let tile = TestPixels.of(try XCTUnwrap(RCAmbientArtwork.grainTile()))
        var alphaSum = 0
        var maxAlpha = 0
        for pixel in 0..<(tile.width * tile.height) {
            let alpha = Int(tile.bytes[pixel * 4 + 3])
            alphaSum += alpha
            maxAlpha = max(maxAlpha, alpha)
        }
        // A 5% layer over the original speck distribution (roll² / 256 for a uniform byte).
        let original = (0..<256).reduce(0.0) { $0 + Double(($1 * $1) >> 8) } / 256
        let mean = Double(alphaSum) / Double(tile.width * tile.height)
        XCTAssertEqual(mean, original * RCAmbientArtwork.grainOpacity, accuracy: original * RCAmbientArtwork.grainOpacity * 0.03)
        XCTAssertLessThanOrEqual(maxAlpha, Int((255 * RCAmbientArtwork.grainOpacity).rounded(.up)))
    }

    func testCachesAreBoundedAndPurgedOnMemoryWarning() async {
        RCAmbientArtwork.purgeCaches()
        for width in [320, 390, 744, 1024] {
            _ = RCAmbientArtwork.gridImage(size: CGSize(width: width, height: 800), tone: .console)
        }
        XCTAssertEqual(RCAmbientArtwork.cachedImageCount, RCAmbientArtwork.gridCacheLimit)
        _ = RCAmbientArtwork.bloomImage(.signal, tone: .warm)
        _ = RCAmbientArtwork.grainTile()
        XCTAssertGreaterThan(RCAmbientArtwork.cachedImageCount, RCAmbientArtwork.gridCacheLimit)

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
        let purged = await pollUntil(timeout: 1) { RCAmbientArtwork.cachedImageCount == 0 }
        XCTAssertTrue(purged)
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
