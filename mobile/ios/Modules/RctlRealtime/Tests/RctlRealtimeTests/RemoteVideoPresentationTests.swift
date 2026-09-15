#if canImport(UIKit)
import CoreImage
import CoreVideo
import Foundation
@preconcurrency import LiveKitWebRTC
import Metal
import QuartzCore
import Testing
import UIKit
@testable import RctlRealtime

@Suite("Remote video presentation", .serialized)
@MainActor
struct RemoteVideoPresentationTests {
    @Test("Frames render on the private render queue, never on the main thread")
    func presentsOffMain() async throws {
        let view = makeView(width: 120, height: 80)
        let recorder = RenderRecorder()
        view.presenter.setRenderObserver { recorder.observe($0) }
        let renderer = RctlMetalVideoRenderer(view: view)
        let buffer = Unchecked(TestPattern.bgra(width: 64, height: 36))

        await deliverInBackground(count: 30, interval: 1.0 / 60) { index in
            renderer.renderFrame(makeFrame(buffer.value, timestamp: index))
        }
        try await waitUntil { recorder.snapshot.presented.count > 0 }
        await idle(view.presenter.renderQueue)

        let snapshot = recorder.snapshot
        #expect(!snapshot.renderedOnMainThread)
        #expect(snapshot.queueLabels == ["com.greatlove.rctl.controller.video-render"])
    }

    @Test("A burst keeps one pending frame and bounded buffers")
    func coalescesBursts() async throws {
        let view = makeView(width: 120, height: 80)
        let recorder = RenderRecorder()
        view.presenter.setRenderObserver { recorder.observe($0) }
        let renderer = RctlMetalVideoRenderer(view: view)
        let liveness = FrameLiveness()
        let gate = RenderGate(view.presenter.renderQueue)

        // While the render queue is busy, 200 decoded frames replace one another.
        let buffer = Unchecked(TestPattern.bgra(width: 64, height: 36))
        gate.close()
        await deliverInBackground(count: 200) { index in
            let frame = makeFrame(buffer.value, timestamp: index)
            liveness.track(frame)
            renderer.renderFrame(frame)
        }
        #expect(liveness.aliveCount == 1)
        gate.open()
        await idle(view.presenter.renderQueue)
        #expect(recorder.snapshot.presented == [199])
        try await waitUntil { liveness.aliveCount == 0 }

        // Unthrottled delivery from a decoder-like bounded pool never runs the
        // pool dry and never keeps more than the pending and rendering frames.
        let pool = try BoundedPixelBufferPool(width: 1280, height: 720, limit: 6)
        let maxAlive = Locked(0)
        await deliverInBackground(count: 200) { index in
            guard let pixelBuffer = pool.make() else { return }
            let frame = makeFrame(pixelBuffer, timestamp: 1_000 + index)
            liveness.track(frame)
            renderer.renderFrame(frame)
            let alive = liveness.aliveCount
            maxAlive.update { $0 = max($0, alive) }
        }
        await idle(view.presenter.renderQueue)
        #expect(pool.exhaustedCount == 0)
        #expect(maxAlive.value <= 3)
        #expect(recorder.snapshot.presented.last == 1_199)
        try await waitUntil { liveness.aliveCount == 0 }
    }

    @Test("A starved drawable pool drops frames without blocking the main thread")
    func starvedDrawablesNeverBlockMain() async throws {
        let view = makeView(width: 120, height: 80)
        let layer = try #require(view.layer as? CAMetalLayer)
        #expect(layer.maximumDrawableCount == 2)
        #expect(layer.allowsNextDrawableTimeout)

        let recorder = RenderRecorder()
        view.presenter.setRenderObserver { recorder.observe($0) }
        // A layer outside a display never runs out of drawables, so stand in
        // for a starved pool: each acquisition waits out the timeout and fails.
        let starved = Locked(true)
        view.presenter.setDrawableProvider { layer in
            guard starved.value else { return layer.nextDrawable() }
            Thread.sleep(forTimeInterval: 1)
            return nil
        }
        let renderer = RctlMetalVideoRenderer(view: view)
        let liveness = FrameLiveness()
        let maxAlive = Locked(0)
        let buffer = Unchecked(TestPattern.bgra(width: 64, height: 36))

        let feeding = Task.detached {
            await deliverInBackground(count: 150, interval: 1.0 / 60) { index in
                let frame = makeFrame(buffer.value, timestamp: index)
                liveness.track(frame)
                renderer.renderFrame(frame)
                let alive = liveness.aliveCount
                maxAlive.update { $0 = max($0, alive) }
            }
        }
        var longestStall: TimeInterval = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 2.5
        while ProcessInfo.processInfo.systemUptime < deadline {
            let started = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(nanoseconds: 4_000_000)
            longestStall = max(longestStall, ProcessInfo.processInfo.systemUptime - started)
            _ = view.normalizedRemotePoint(for: CGPoint(x: 60, y: 40), clamped: true)
            view.setDeviceOrientation(1)
            view.setNeedsLayout()
            view.layoutIfNeeded()
        }
        await feeding.value

        #expect(longestStall < 0.25, "Main thread stalled for \(longestStall) s")
        #expect(maxAlive.value <= 3)
        try await waitUntil(timeout: 5) { recorder.snapshot.dropped >= 2 }
        #expect(recorder.snapshot.presented.isEmpty)

        // Once drawables return, the next frames reach the screen. The wait
        // that was in progress still fails and drops its frame.
        starved.update { $0 = false }
        await idle(view.presenter.renderQueue)
        await deliverInBackground(count: 5, interval: 1.0 / 60) { index in
            renderer.renderFrame(makeFrame(buffer.value, timestamp: 10_000 + index))
        }
        try await waitUntil(timeout: 5) { recorder.snapshot.presented.last == 10_004 }
        try await waitUntil { liveness.aliveCount == 0 }
    }

    @Test("Touch geometry follows the frame on screen through orientation changes")
    func touchGeometryFollowsPresentedFrame() async throws {
        let view = makeView(width: 200, height: 100)
        let recorder = RenderRecorder()
        view.presenter.setRenderObserver { recorder.observe($0) }
        let renderer = RctlMetalVideoRenderer(view: view)
        let gate = RenderGate(view.presenter.renderQueue)
        let portrait = Unchecked(TestPattern.bgra(width: 90, height: 160))
        let sourceSize = CGSize(width: 90, height: 160)

        #expect(view.normalizedRemotePoint(for: CGPoint(x: 100, y: 50), clamped: false) == nil)

        await deliverInBackground(count: 1) { _ in
            renderer.renderFrame(makeFrame(portrait.value, timestamp: 1))
        }
        try await waitUntil { recorder.snapshot.presented == [1] }
        await idle(view.presenter.renderQueue)
        let upright = RctlRemoteVideoGeometry(sourceSize: sourceSize, rotation: 0, viewportSize: view.bounds.size)
        let probe = CGPoint(x: upright.contentRect.minX + 4, y: 20)
        #expect(view.presenter.presentedSource == .init(size: sourceSize, rotation: 0))
        #expect(view.normalizedRemotePoint(for: probe, clamped: false) == upright.normalizedRemotePoint(for: probe, clamped: false))

        // The remote reports landscape; a pending frame does not remap touches
        // until it is actually presented.
        view.setDeviceOrientation(3)
        gate.close()
        await deliverInBackground(count: 1) { _ in
            renderer.renderFrame(makeFrame(portrait.value, timestamp: 2))
        }
        #expect(view.presenter.presentedSource == .init(size: sourceSize, rotation: 0))
        #expect(view.normalizedRemotePoint(for: probe, clamped: false) == upright.normalizedRemotePoint(for: probe, clamped: false))
        gate.open()
        try await waitUntil { recorder.snapshot.presented == [1, 2] }
        await idle(view.presenter.renderQueue)

        let rotated = RctlRemoteVideoGeometry(sourceSize: sourceSize, rotation: 270, viewportSize: view.bounds.size)
        #expect(view.presenter.presentedSource == .init(size: sourceSize, rotation: 270))
        let rotatedProbe = CGPoint(x: rotated.contentRect.minX + 30, y: 25)
        #expect(view.normalizedRemotePoint(for: rotatedProbe, clamped: false) == rotated.normalizedRemotePoint(for: rotatedProbe, clamped: false))
        #expect(view.normalizedRemotePoint(for: CGPoint(x: rotated.contentRect.minX, y: rotated.contentRect.minY), clamped: false) == CGPoint(x: 1, y: 0))
        #expect(view.normalizedRemotePoint(for: CGPoint(x: 1, y: 50), clamped: false) == nil)

        // Without an override the frame's own rotation applies again.
        view.setDeviceOrientation(nil)
        await deliverInBackground(count: 1) { _ in
            renderer.renderFrame(makeFrame(portrait.value, rotation: 90, timestamp: 3))
        }
        try await waitUntil { recorder.snapshot.presented == [1, 2, 3] }
        await idle(view.presenter.renderQueue)
        #expect(view.presenter.presentedSource == .init(size: sourceSize, rotation: 90))
    }

    @Test("Clear drops pending frames and the newest work wins")
    func clearDropsPendingFrames() async throws {
        let view = makeView(width: 120, height: 80)
        let recorder = RenderRecorder()
        view.presenter.setRenderObserver { recorder.observe($0) }
        let renderer = RctlMetalVideoRenderer(view: view)
        let gate = RenderGate(view.presenter.renderQueue)
        let liveness = FrameLiveness()
        let buffer = Unchecked(TestPattern.bgra(width: 64, height: 36))

        gate.close()
        await deliverInBackground(count: 5) { index in
            let frame = makeFrame(buffer.value, timestamp: index)
            liveness.track(frame)
            renderer.renderFrame(frame)
        }
        renderer.clear()
        #expect(liveness.aliveCount == 0)
        gate.open()
        await idle(view.presenter.renderQueue)
        #expect(recorder.snapshot.presented.isEmpty)
        #expect(recorder.snapshot.cleared == 1)
        try await waitUntil { recorder.snapshot.lastClearPixels != nil }
        #expect(recorder.snapshot.lastClearPixels?.allSatisfy(\.isOpaqueBlack) == true)

        gate.close()
        renderer.clear()
        await deliverInBackground(count: 1) { _ in
            renderer.renderFrame(makeFrame(buffer.value, timestamp: 9))
        }
        gate.open()
        await idle(view.presenter.renderQueue)
        #expect(recorder.snapshot.presented == [9])
        #expect(recorder.snapshot.cleared == 1)
    }

    @Test("Presented pixels match the full-frame composite at every rotation", arguments: [
        TestPattern.Format.bgra, .nv12,
    ])
    func pixelsMatchLegacyComposite(format: TestPattern.Format) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let reference = LegacyCompositeReference(device: device)
        let cases: [(view: CGSize, source: (width: Int, height: Int))] = [
            (CGSize(width: 120, height: 80), (90, 160)),
            (CGSize(width: 80, height: 120), (90, 160)),
            (CGSize(width: 101, height: 67), (1280, 720)),
            (CGSize(width: 67, height: 101), (1280, 720)),
        ]
        for (size, sourceSize) in cases {
            let view = makeView(width: size.width, height: size.height)
            let recorder = RenderRecorder(device: device)
            view.presenter.setRenderObserver { recorder.observe($0) }
            let renderer = RctlMetalVideoRenderer(view: view)
            let source = Unchecked(TestPattern.make(format, width: sourceSize.width, height: sourceSize.height))

            for (index, rotation) in [0, 90, 180, 270].enumerated() {
                await deliverInBackground(count: 1) { _ in
                    renderer.renderFrame(makeFrame(source.value, rotation: rotation, timestamp: index))
                }
                try await waitUntil { recorder.snapshot.framePixels.count == index + 1 }
                let presented = recorder.snapshot.framePixels[index]
                let expected = try reference.render(source.value, rotation: rotation, width: presented.width, height: presented.height)
                let mismatch = PixelMismatch(presented.bytes, expected, width: presented.width)
                #expect(mismatch == nil, "\(format) \(size) pt at \(rotation)°: \(mismatch?.description ?? "")")
                #expect(presented.pixel(x: 0, y: 0).isOpaqueBlack)
                #expect(presented.pixel(x: presented.width - 1, y: presented.height - 1).isOpaqueBlack)

                if format == .bgra {
                    expectOrientation(presented, view: view, sampleCount: 24)
                }
            }
        }
    }

    @Test("Releasing the view with pending and in-flight renders is safe")
    func releaseWithPendingRender() async throws {
        let factory = LKRTCPeerConnectionFactory()
        let source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: "presentation-test")
        let capturer = LKRTCVideoCapturer(delegate: source)
        let buffer = Unchecked(TestPattern.bgra(width: 64, height: 36))
        let deliver: @Sendable (Int) -> Void = { index in
            source.capturer(capturer, didCapture: makeFrame(buffer.value, timestamp: index))
        }

        let delivered = FrameCounter()
        track.add(delivered)
        defer { track.remove(delivered) }

        // Pending: frames queued behind a busy render queue when the view goes away.
        let recorder = RenderRecorder()
        let pending = try attachedView(track: track) { recorder.observe($0) }
        let gate = RenderGate(pending.queue)
        gate.close()
        await deliverInBackground(count: 20, deliver: deliver)
        #expect(delivered.count == 20)
        pending.release()
        try await waitUntil { pending.isReleased }
        gate.open()
        await idle(pending.queue)
        try await waitUntil { pending.presenterReleased }
        #expect(recorder.snapshot.presented.isEmpty)
        #expect(recorder.snapshot.cleared == 0)
        await deliverInBackground(count: 5, deliver: deliver)

        // In flight: the view goes away while its frame is being encoded.
        let inFlightRecorder = RenderRecorder()
        let encoding = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let inFlight = try attachedView(track: track) { event in
            inFlightRecorder.observe(event)
            guard case .frame = event else { return }
            encoding.signal()
            resume.wait()
        }
        await deliverInBackground(count: 1, deliver: deliver)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                encoding.wait()
                continuation.resume()
            }
        }
        inFlight.release()
        try await waitUntil { inFlight.isReleased }
        resume.signal()
        await idle(inFlight.queue)
        try await waitUntil { inFlight.presenterReleased }
        #expect(inFlightRecorder.snapshot.presented.count == 1)
        await deliverInBackground(count: 5, deliver: deliver)
    }

    private func attachedView(
        track: LKRTCVideoTrack,
        observer: @escaping @Sendable (RctlVideoPresenter.RenderEvent) -> Void
    ) throws -> ReleasableVideoView {
        var result: ReleasableVideoView?
        try autoreleasepool {
            let view = RctlRemoteVideoView(frame: CGRect(x: 0, y: 0, width: 120, height: 80))
            view.layoutIfNeeded()
            let presentation = try #require(view.subviews.first as? RctlMetalVideoView)
            #expect(presentation.bounds.size == view.bounds.size)
            presentation.presenter.setRenderObserver(observer)
            view.setTrack(track)
            result = ReleasableVideoView(view: view, presentation: presentation)
        }
        return try #require(result)
    }

    // MARK: Helpers

    private func makeView(width: CGFloat, height: CGFloat) -> RctlMetalVideoView {
        let view = RctlMetalVideoView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return view
    }

    /// Every sampled touch point must land on the source quadrant whose color
    /// is drawn under it, tying rendering to touch mapping.
    private func expectOrientation(_ pixels: CapturedPixels, view: RctlMetalVideoView, sampleCount: Int) {
        let source = view.presenter.presentedSource
        let content = RctlRemoteVideoGeometry(
            sourceSize: source.size,
            rotation: source.rotation,
            viewportSize: view.bounds.size
        ).contentRect
        let scaleX = CGFloat(pixels.width) / view.bounds.width
        let scaleY = CGFloat(pixels.height) / view.bounds.height
        var checked = 0
        for row in 0 ..< sampleCount {
            for column in 0 ..< sampleCount {
                let point = CGPoint(
                    x: (CGFloat(column) + 0.5) * view.bounds.width / CGFloat(sampleCount),
                    y: (CGFloat(row) + 0.5) * view.bounds.height / CGFloat(sampleCount)
                )
                let color = pixels.pixel(x: Int(point.x * scaleX), y: Int(point.y * scaleY))
                guard let remote = view.normalizedRemotePoint(for: point, clamped: false) else {
                    if !content.insetBy(dx: -1, dy: -1).contains(point) {
                        #expect(color.isOpaqueBlack, "Letterbox at \(point) shows \(color)")
                    }
                    continue
                }
                // Skip samples near seams and edges where filtering blends colors.
                guard abs(remote.x - 0.5) > 0.06, abs(remote.y - 0.5) > 0.06,
                      remote.x > 0.04, remote.x < 0.96, remote.y > 0.04, remote.y < 0.96 else { continue }
                let expected = TestPattern.quadrantColor(x: remote.x, y: remote.y)
                #expect(color == expected, "Touch \(point) maps to \(remote) but shows \(color)")
                checked += 1
            }
        }
        #expect(checked > 20)
    }
}

// MARK: - Test support

/// Owns a video view so a test can drop the only strong reference and then
/// observe teardown through weak references.
@MainActor
private final class ReleasableVideoView {
    private var view: RctlRemoteVideoView?
    private weak var weakView: RctlRemoteVideoView?
    private weak var weakPresentation: RctlMetalVideoView?
    private weak var weakPresenter: RctlVideoPresenter?
    let queue: DispatchQueue

    init(view: RctlRemoteVideoView, presentation: RctlMetalVideoView) {
        self.view = view
        weakView = view
        weakPresentation = presentation
        weakPresenter = presentation.presenter
        queue = presentation.presenter.renderQueue
    }

    func release() {
        view = nil
    }

    var isReleased: Bool { weakView == nil && weakPresentation == nil }
    var presenterReleased: Bool { weakPresenter == nil }
}

/// Counts frames a track hands to its sinks.
private final class FrameCounter: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private let frames = Locked(0)

    var count: Int { frames.value }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        if frame != nil { frames.update { $0 += 1 } }
    }
}

private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func update(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}

/// Holds a serial queue busy until opened, so work submitted meanwhile queues
/// behind it.
private final class RenderGate: @unchecked Sendable {
    private let queue: DispatchQueue
    private let semaphore = DispatchSemaphore(value: 0)

    init(_ queue: DispatchQueue) { self.queue = queue }

    func close() {
        queue.async { self.semaphore.wait() }
    }

    func open() {
        semaphore.signal()
    }
}

/// Summarizes byte differences without handing large arrays to `#expect`.
private struct PixelMismatch: CustomStringConvertible {
    let count: Int
    let maxDelta: Int
    let first: (x: Int, y: Int)

    init?(_ actual: [UInt8], _ expected: [UInt8], width: Int) {
        guard actual.count == expected.count else {
            count = -1
            maxDelta = 0
            first = (0, 0)
            return
        }
        var count = 0, maxDelta = 0, firstIndex = -1
        for index in stride(from: 0, to: actual.count, by: 4) {
            var differs = false
            for channel in 0 ..< 4 {
                let delta = abs(Int(actual[index + channel]) - Int(expected[index + channel]))
                if delta > 0 {
                    differs = true
                    maxDelta = max(maxDelta, delta)
                }
            }
            if differs {
                count += 1
                if firstIndex < 0 { firstIndex = index / 4 }
            }
        }
        guard count > 0 else { return nil }
        self.count = count
        self.maxDelta = maxDelta
        first = (firstIndex % width, firstIndex / width)
    }

    var description: String {
        count < 0 ? "size mismatch" : "\(count) pixels differ, max channel delta \(maxDelta), first at \(first)"
    }
}

private struct RGBA: Equatable, CustomStringConvertible {
    let red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8

    static let black = RGBA(red: 0, green: 0, blue: 0, alpha: 255)

    var isOpaqueBlack: Bool { self == .black }
    var description: String { "rgba(\(red), \(green), \(blue), \(alpha))" }
}

private struct CapturedPixels {
    let width: Int
    let height: Int
    /// BGRA rows, top row first.
    let bytes: [UInt8]

    func pixel(x: Int, y: Int) -> RGBA {
        let index = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return RGBA(red: bytes[index + 2], green: bytes[index + 1], blue: bytes[index], alpha: bytes[index + 3])
    }

    var allPixels: [RGBA] {
        stride(from: 0, to: bytes.count, by: 4).map {
            RGBA(red: bytes[$0 + 2], green: bytes[$0 + 1], blue: bytes[$0], alpha: bytes[$0 + 3])
        }
    }
}

private final class RenderRecorder: @unchecked Sendable {
    struct Snapshot {
        var presented: [Int64] = []
        var cleared = 0
        var dropped = 0
        var renderedOnMainThread = false
        var queueLabels: Set<String> = []
        var framePixels: [CapturedPixels] = []
        var lastClearPixels: [RGBA]?
    }

    private let device: MTLDevice?
    private let state = Locked(Snapshot())

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.device = device
    }

    var snapshot: Snapshot { state.value }

    func observe(_ event: RctlVideoPresenter.RenderEvent) {
        let onMain = Thread.isMainThread
        let label = String(cString: __dispatch_queue_get_label(nil))
        state.update {
            $0.renderedOnMainThread = $0.renderedOnMainThread || onMain
            $0.queueLabels.insert(label)
        }
        switch event {
        case let .frame(frame, texture, commandBuffer):
            capture(texture, commandBuffer: commandBuffer) { pixels in
                self.state.update { $0.framePixels.append(pixels) }
            }
            state.update { $0.presented.append(frame.timeStampNs) }
        case let .clear(texture, commandBuffer):
            capture(texture, commandBuffer: commandBuffer) { pixels in
                self.state.update { $0.lastClearPixels = pixels.allPixels }
            }
            state.update { $0.cleared += 1 }
        case .dropped:
            state.update { $0.dropped += 1 }
        }
    }

    private func capture(
        _ texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        completion: @escaping @Sendable (CapturedPixels) -> Void
    ) {
        guard let device else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        guard let copy = device.makeTexture(descriptor: descriptor),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: copy,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        let target = Unchecked(copy)
        commandBuffer.addCompletedHandler { _ in
            completion(readPixels(target.value))
        }
    }
}

private func readPixels(_ texture: MTLTexture) -> CapturedPixels {
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(
        &bytes,
        bytesPerRow: texture.width * 4,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
    return CapturedPixels(width: texture.width, height: texture.height, bytes: bytes)
}

private final class FrameLiveness: @unchecked Sendable {
    private struct WeakFrame {
        weak var frame: LKRTCVideoFrame?
    }

    private let frames = Locked<[WeakFrame]>([])

    func track(_ frame: LKRTCVideoFrame) {
        frames.update { $0.append(WeakFrame(frame: frame)) }
    }

    var aliveCount: Int {
        frames.value.reduce(0) { $0 + ($1.frame == nil ? 0 : 1) }
    }
}

/// Mirrors a decoder pool: allocation fails once `limit` buffers are in use.
private final class BoundedPixelBufferPool: @unchecked Sendable {
    private let pool: CVPixelBufferPool
    private let auxiliary: CFDictionary
    private let exhausted = Locked(0)

    struct CreationFailed: Error {}

    init(width: Int, height: Int, limit: Int) throws {
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw CreationFailed()
        }
        self.pool = pool
        auxiliary = [kCVPixelBufferPoolAllocationThresholdKey as String: limit] as CFDictionary
    }

    var exhaustedCount: Int { exhausted.value }

    func make() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, auxiliary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            exhausted.update { $0 += 1 }
            return nil
        }
        return buffer
    }
}

enum TestPattern {
    enum Format: String, CustomTestStringConvertible, Sendable {
        case bgra, nv12
        var testDescription: String { rawValue }
    }

    /// Top-left red, top-right green, bottom-left blue, bottom-right white.
    fileprivate static func quadrantColor(x: CGFloat, y: CGFloat) -> RGBA {
        switch (x < 0.5, y < 0.5) {
        case (true, true): RGBA(red: 255, green: 0, blue: 0, alpha: 255)
        case (false, true): RGBA(red: 0, green: 255, blue: 0, alpha: 255)
        case (true, false): RGBA(red: 0, green: 0, blue: 255, alpha: 255)
        case (false, false): RGBA(red: 255, green: 255, blue: 255, alpha: 255)
        }
    }

    static func make(_ format: Format, width: Int, height: Int) -> CVPixelBuffer {
        switch format {
        case .bgra: bgra(width: width, height: height)
        case .nv12: nv12(width: width, height: height)
        }
    }

    static func bgra(width: Int, height: Int) -> CVPixelBuffer {
        let buffer = allocate(kCVPixelFormatType_32BGRA, width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let color = quadrantColor(x: CGFloat(x) / CGFloat(width), y: CGFloat(y) / CGFloat(height))
                let pixel = base + y * rowBytes + x * 4
                pixel[0] = color.blue
                pixel[1] = color.green
                pixel[2] = color.red
                pixel[3] = 255
            }
        }
        return buffer
    }

    /// Full-range 4:2:0 like hardware decoder output.
    static func nv12(width: Int, height: Int) -> CVPixelBuffer {
        let buffer = allocate(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        func ycbcr(_ color: RGBA) -> (UInt8, UInt8, UInt8) {
            let r = Double(color.red), g = Double(color.green), b = Double(color.blue)
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            let cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b
            let cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b
            func byte(_ value: Double) -> UInt8 { UInt8(min(max(value.rounded(), 0), 255)) }
            return (byte(y), byte(cb), byte(cr))
        }
        let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0 ..< height {
            for x in 0 ..< width {
                luma[y * lumaRow + x] = ycbcr(quadrantColor(x: CGFloat(x) / CGFloat(width), y: CGFloat(y) / CGFloat(height))).0
            }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        for y in 0 ..< chromaHeight {
            for x in 0 ..< chromaWidth {
                let color = quadrantColor(x: CGFloat(x) / CGFloat(chromaWidth), y: CGFloat(y) / CGFloat(chromaHeight))
                let (_, cb, cr) = ycbcr(color)
                chroma[y * chromaRow + x * 2] = cb
                chroma[y * chromaRow + x * 2 + 1] = cr
            }
        }
        return buffer
    }

    private static func allocate(_ format: OSType, width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &buffer)
        return buffer!
    }
}

/// The pre-change renderer: aspect fit composited over a full-frame black
/// image, rendered into a drawable of a layer configured like the old view.
/// Kept verbatim as the pixel reference.
@MainActor
private struct LegacyCompositeReference {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    let layer = CAMetalLayer()
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    init(device: MTLDevice) {
        self.device = device
        queue = device.makeCommandQueue()!
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "legacy reference"])
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
    }

    func render(_ pixelBuffer: CVPixelBuffer, rotation: Int, width: Int, height: Int) throws -> [UInt8] {
        layer.drawableSize = CGSize(width: width, height: height)
        let drawable = try #require(layer.nextDrawable())
        let commandBuffer = try #require(queue.makeCommandBuffer())

        let target = CGRect(origin: .zero, size: layer.drawableSize)
        let exif: Int32 = switch rotation {
        case 90: 6
        case 180: 3
        case 270: 8
        default: 1
        }
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(forExifOrientation: exif)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = min(target.width / image.extent.width, target.height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(
            by: CGAffineTransform(
                translationX: (target.width - image.extent.width) / 2 - image.extent.minX,
                y: (target.height - image.extent.height) / 2 - image.extent.minY
            )
        )
        let output = image.composited(over: CIImage(color: .black).cropped(to: target))
        context.render(output, to: drawable.texture, commandBuffer: commandBuffer, bounds: target, colorSpace: colorSpace)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        let copy = try #require(device.makeTexture(descriptor: descriptor))
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: drawable.texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: copy,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return readPixels(copy).bytes
    }
}

private func makeFrame(_ buffer: CVPixelBuffer, rotation: Int = 0, timestamp: Int) -> LKRTCVideoFrame {
    LKRTCVideoFrame(
        buffer: LKRTCCVPixelBuffer(pixelBuffer: buffer),
        rotation: LKRTCVideoRotation(rawValue: rotation)!,
        timeStampNs: Int64(timestamp)
    )
}

/// Delivers frames from a background thread, like WebRTC's decoder.
private func deliverInBackground(
    count: Int,
    interval: TimeInterval = 0,
    deliver: @escaping @Sendable (Int) -> Void
) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            for index in 0 ..< count {
                autoreleasepool { deliver(index) }
                if interval > 0 { Thread.sleep(forTimeInterval: interval) }
            }
            continuation.resume()
        }
    }
}

/// Resumes after everything already submitted to `queue` has run.
private func idle(_ queue: DispatchQueue) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        queue.async { continuation.resume() }
    }
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 5,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            Issue.record("Timed out after \(timeout) s", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}
#endif
