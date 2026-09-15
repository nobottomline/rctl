#if canImport(UIKit)
import CoreImage
import Metal
import QuartzCore
import UIKit
@preconcurrency import LiveKitWebRTC

/// UIKit host for the Metal video surface.
///
/// The view lays out the layer and answers touch geometry on the main thread.
/// Drawable acquisition, Core Image rendering and presentation run on
/// `RctlVideoPresenter`'s render queue, so a late GPU never delays touches.
@MainActor
final class RctlMetalVideoView: UIView {
    nonisolated let presenter: RctlVideoPresenter

    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    private var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    override init(frame: CGRect) {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue()
        else {
            preconditionFailure("Metal is required by the iOS controller video renderer")
        }

        presenter = RctlVideoPresenter(device: device, commandQueue: commandQueue)
        super.init(frame: frame)

        backgroundColor = .black
        clipsToBounds = true
        isOpaque = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.backgroundColor = UIColor.black.cgColor
        metalLayer.contentsScale = UIScreen.main.scale
        // One drawable being encoded plus one awaiting display. When the GPU
        // or display runs late the render queue waits for a drawable and then
        // draws the newest frame rather than queueing stale ones; a wait past
        // the layer's timeout drops the frame.
        metalLayer.maximumDrawableCount = 2
        metalLayer.allowsNextDrawableTimeout = true
        presenter.attach(metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    deinit {
        presenter.invalidate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = drawableSize
        presenter.setDrawableSize(drawableSize)
    }

    func setDeviceOrientation(_ orientation: Int?) {
        let rotation: Int? = switch orientation {
        case 1: 0
        case 2: 180
        case 3: 270
        case 4: 90
        default: nil
        }
        presenter.setDeviceRotation(rotation)
    }

    /// Maps through the geometry of the frame on screen, not a pending one.
    func normalizedRemotePoint(for point: CGPoint, clamped: Bool) -> CGPoint? {
        let source = presenter.presentedSource
        return RctlRemoteVideoGeometry(
            sourceSize: source.size,
            rotation: source.rotation,
            viewportSize: bounds.size
        ).normalizedRemotePoint(for: point, clamped: clamped)
    }
}

/// Presents decoded frames into a `CAMetalLayer` from a private serial queue.
///
/// Frames arrive on WebRTC's decode thread and geometry changes on the main
/// thread; neither waits for rendering. Pending work is a single slot in which
/// the newest frame or clear replaces older work, and the render queue retains
/// the presenter only while it drains that slot. The layer is held weakly and
/// the owning view invalidates the presenter as it deallocates, so queued work
/// never renders for a view that is gone.
final class RctlVideoPresenter: @unchecked Sendable {
    struct PresentedSource: Equatable {
        var size: CGSize
        var rotation: Int
    }

    private enum Work {
        case frame(LKRTCVideoFrame)
        case clear
    }

    /// Core Image resamples slightly past a scaled image's reported extent.
    /// Compositing over black within this margin keeps edge pixels identical
    /// to compositing over a full-frame black image.
    static let resamplingMargin: CGFloat = 4

    let renderQueue = DispatchQueue(label: "com.greatlove.rctl.controller.video-render", qos: .userInteractive)
    private let commandQueue: MTLCommandQueue
    private let imageContext: CIContext
    private let outputColorSpace = CGColorSpaceCreateDeviceRGB()

    private let lock = NSLock()
    // Guarded by `lock`.
    private weak var layer: CAMetalLayer?
    private var pending: Work?
    private var drainScheduled = false
    private var invalidated = false
    private var drawableSize = CGSize.zero
    private var deviceRotation: Int?
    private var presented = PresentedSource(size: .zero, rotation: 0)
#if DEBUG
    private var observer: (@Sendable (RenderEvent) -> Void)?
    private var drawableProvider: (@Sendable (CAMetalLayer) -> CAMetalDrawable?)?
#endif

    // Confined to `renderQueue`.
    private var loggedFirstFrame = false
    private var loggedMissingDrawable = false

    init(device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.commandQueue = commandQueue
        imageContext = CIContext(
            mtlDevice: device,
            options: [
                .cacheIntermediates: false,
                .name: "rctl video renderer",
            ]
        )
    }

    func attach(_ layer: CAMetalLayer) {
        withLock { self.layer = layer }
    }

    /// Discards pending work and refuses new work. A render that has already
    /// committed its command buffer still reaches the screen.
    func invalidate() {
        // The discarded work is released after the lock is dropped.
        _ = withLock {
            invalidated = true
            return takePending()
        }
    }

    func setDrawableSize(_ size: CGSize) {
        withLock { drawableSize = size }
    }

    func setDeviceRotation(_ rotation: Int?) {
        withLock { deviceRotation = rotation }
    }

    var presentedSource: PresentedSource {
        withLock { presented }
    }

    func enqueue(_ frame: LKRTCVideoFrame) {
        schedule(.frame(frame))
    }

    /// Replaces any pending frame with a black clear.
    func clear() {
        schedule(.clear)
    }

    private func schedule(_ work: Work) {
        // A superseded frame is released after the lock is dropped.
        let (shouldSchedule, _) = withLock { () -> (Bool, Work?) in
            guard !invalidated else { return (false, nil) }
            let superseded = takePending()
            pending = work
            defer { drainScheduled = true }
            return (!drainScheduled, superseded)
        }
        if shouldSchedule {
            renderQueue.async { self.drain() }
        }
    }

    private func drain() {
        while autoreleasepool(invoking: { renderPendingWork() }) {}
    }

    /// Renders the newest pending work. Returns `false` once nothing is
    /// pending and the drain is no longer scheduled.
    private func renderPendingWork() -> Bool {
        let surface: (layer: CAMetalLayer, drawableSize: CGSize)? = withLock {
            guard !invalidated, pending != nil, let layer else {
                pending = nil
                drainScheduled = false
                return nil
            }
            return (layer, drawableSize)
        }
        guard let surface else { return false }

        // Waits at most the layer's drawable timeout. Frames that arrive
        // meanwhile replace the pending one, so work is taken only once a
        // drawable is in hand.
        let drawable = surface.drawableSize.width > 0 && surface.drawableSize.height > 0
            ? nextDrawable(from: surface.layer)
            : nil
        let (work, rotationOverride) = withLock {
            (invalidated ? nil : takePending(), deviceRotation)
        }

        guard let work else { return true }

        switch work {
        case let .frame(frame):
            guard let buffer = frame.buffer as? LKRTCCVPixelBuffer else {
                RctlMetalVideoRenderer.logger.error(
                    "Unsupported decoded frame buffer: \(String(describing: type(of: frame.buffer)), privacy: .public)"
                )
                return true
            }
            guard let drawable, let commandBuffer = makeClearedCommandBuffer(for: drawable) else {
                if !loggedMissingDrawable {
                    loggedMissingDrawable = true
                    RctlMetalVideoRenderer.logger.error("Metal drawable is unavailable")
                }
#if DEBUG
                notify(.dropped)
#endif
                return true
            }
            present(
                frame,
                pixelBuffer: buffer.pixelBuffer,
                rotation: rotationOverride ?? frame.rotation.rawValue,
                drawable: drawable,
                commandBuffer: commandBuffer
            )
        case .clear:
            guard let drawable, let commandBuffer = makeClearedCommandBuffer(for: drawable) else {
#if DEBUG
                notify(.dropped)
#endif
                return true
            }
#if DEBUG
            notify(.clear(drawable.texture, commandBuffer))
#endif
            guard !withLock({ invalidated }) else { return true }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
        return true
    }

    private func present(
        _ frame: LKRTCVideoFrame,
        pixelBuffer: CVPixelBuffer,
        rotation: Int,
        drawable: CAMetalDrawable,
        commandBuffer: MTLCommandBuffer
    ) {
        let texture = drawable.texture
        Self.encodeFrame(
            pixelBuffer,
            rotation: rotation,
            into: texture,
            commandBuffer: commandBuffer,
            context: imageContext,
            colorSpace: outputColorSpace
        )
#if DEBUG
        notify(.frame(frame, texture, commandBuffer))
#endif
        let isCurrent = withLock {
            guard !invalidated else { return false }
            presented = PresentedSource(
                size: CGSize(width: CGFloat(frame.width), height: CGFloat(frame.height)),
                rotation: rotation
            )
            return true
        }
        guard isCurrent else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if !loggedFirstFrame {
            loggedFirstFrame = true
            RctlMetalVideoRenderer.logger.info(
                "Presented first Metal frame: \(frame.width)x\(frame.height) frameRotation=\(frame.rotation.rawValue) displayRotation=\(rotation) drawable=\(texture.width)x\(texture.height)"
            )
        }
    }

    private func nextDrawable(from layer: CAMetalLayer) -> CAMetalDrawable? {
#if DEBUG
        if let provider = withLock({ drawableProvider }) {
            return provider(layer)
        }
#endif
        return layer.nextDrawable()
    }

    private func makeClearedCommandBuffer(for drawable: CAMetalDrawable) -> MTLCommandBuffer? {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              Self.encodeBlackClear(drawable.texture, commandBuffer: commandBuffer) else {
            return nil
        }
        return commandBuffer
    }

    /// Must be called with `lock` held.
    private func takePending() -> Work? {
        defer { pending = nil }
        return pending
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Paints the whole texture opaque black with a load-action clear.
    static func encodeBlackClear(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.endEncoding()
        return true
    }

    /// Aspect-fits `pixelBuffer` into a texture already cleared to black.
    /// Core Image processes only the content rectangle and its resampling
    /// margin; the letterbox keeps the clear.
    static func encodeFrame(
        _ pixelBuffer: CVPixelBuffer,
        rotation: Int,
        into texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        context: CIContext,
        colorSpace: CGColorSpace
    ) {
        let target = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        var image = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(forExifOrientation: exifOrientation(for: rotation))
        image = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
        )

        let scale = min(target.width / image.extent.width, target.height / image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(
            by: CGAffineTransform(
                translationX: (target.width - image.extent.width) / 2 - image.extent.minX,
                y: (target.height - image.extent.height) / 2 - image.extent.minY
            )
        )
        let content = image.extent
            .insetBy(dx: -resamplingMargin, dy: -resamplingMargin)
            .intersection(target)
        guard !content.isEmpty else { return }

        context.render(
            image.composited(over: CIImage(color: .black).cropped(to: content)),
            to: texture,
            commandBuffer: commandBuffer,
            bounds: target,
            colorSpace: colorSpace
        )
    }

    private static func exifOrientation(for rotation: Int) -> Int32 {
        switch rotation {
        case 90: 6
        case 180: 3
        case 270: 8
        default: 1
        }
    }

#if DEBUG
    /// Render-queue work reported to tests before it is committed.
    enum RenderEvent {
        case frame(LKRTCVideoFrame, MTLTexture, MTLCommandBuffer)
        case clear(MTLTexture, MTLCommandBuffer)
        case dropped
    }

    func setRenderObserver(_ observer: (@Sendable (RenderEvent) -> Void)?) {
        withLock { self.observer = observer }
    }

    /// Test seam standing in for `CAMetalLayer.nextDrawable()`, which cannot
    /// starve for a layer that is not attached to a display.
    func setDrawableProvider(_ provider: (@Sendable (CAMetalLayer) -> CAMetalDrawable?)?) {
        withLock { drawableProvider = provider }
    }

    private func notify(_ event: RenderEvent) {
        withLock { observer }?(event)
    }
#endif
}

final class RctlMetalVideoRenderer: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    static let logger = RealtimeLog(category: "video-renderer")

    private let presenter: RctlVideoPresenter

    init(view: RctlMetalVideoView) {
        presenter = view.presenter
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        presenter.enqueue(frame)
    }

    func clear() {
        presenter.clear()
    }
}
#endif
