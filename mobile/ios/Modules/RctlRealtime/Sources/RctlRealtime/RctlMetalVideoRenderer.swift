#if canImport(UIKit)
import CoreImage
import Metal
import OSLog
import QuartzCore
import UIKit
@preconcurrency import LiveKitWebRTC

@MainActor
final class RctlMetalVideoView: UIView {
    private let commandQueue: MTLCommandQueue
    private let imageContext: CIContext
    private let outputColorSpace = CGColorSpaceCreateDeviceRGB()
    private var loggedFirstFrame = false
    private var loggedMissingDrawable = false

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

        self.commandQueue = commandQueue
        imageContext = CIContext(
            mtlDevice: device,
            options: [
                .cacheIntermediates: false,
                .name: "rctl video renderer",
            ]
        )
        super.init(frame: frame)

        backgroundColor = .black
        clipsToBounds = true
        isOpaque = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.backgroundColor = UIColor.black.cgColor
        metalLayer.contentsScale = UIScreen.main.scale
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    func present(_ frame: LKRTCVideoFrame) {
        guard let rtcBuffer = frame.buffer as? LKRTCCVPixelBuffer else {
            RctlMetalVideoRenderer.logger.error(
                "Unsupported decoded frame buffer: \(String(describing: type(of: frame.buffer)), privacy: .public)"
            )
            return
        }
        guard
            metalLayer.drawableSize.width > 0,
            metalLayer.drawableSize.height > 0,
            let drawable = metalLayer.nextDrawable(),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            if !loggedMissingDrawable {
                loggedMissingDrawable = true
                RctlMetalVideoRenderer.logger.error("Metal drawable is unavailable")
            }
            return
        }

        let target = CGRect(origin: .zero, size: metalLayer.drawableSize)
        var image = CIImage(cvPixelBuffer: rtcBuffer.pixelBuffer)
            .oriented(forExifOrientation: exifOrientation(for: frame.rotation.rawValue))
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
        let output = image.composited(over: CIImage(color: .black).cropped(to: target))

        imageContext.render(
            output,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: target,
            colorSpace: outputColorSpace
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if !loggedFirstFrame {
            loggedFirstFrame = true
            RctlMetalVideoRenderer.logger.info(
                "Presented first Metal frame: \(frame.width)x\(frame.height) rotation=\(frame.rotation.rawValue) drawable=\(Int(target.width))x\(Int(target.height))"
            )
        }
    }

    func clear() {
        guard let commandBuffer = commandQueue.makeCommandBuffer(), let drawable = metalLayer.nextDrawable() else {
            return
        }
        let target = CGRect(origin: .zero, size: metalLayer.drawableSize)
        imageContext.render(
            CIImage(color: .black).cropped(to: target),
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: target,
            colorSpace: outputColorSpace
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func exifOrientation(for rotation: Int) -> Int32 {
        switch rotation {
        case 90: 6
        case 180: 3
        case 270: 8
        default: 1
        }
    }

}

final class RctlMetalVideoRenderer: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    static let logger = Logger(subsystem: "com.greatlove.rctl.controller", category: "video-renderer")

    private let lock = NSLock()
    private weak var view: RctlMetalVideoView?
    private var pendingFrame: LKRTCVideoFrame?
    private var drainScheduled = false

    init(view: RctlMetalVideoView) {
        self.view = view
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }

        lock.lock()
        pendingFrame = frame
        let shouldSchedule = !drainScheduled
        drainScheduled = true
        lock.unlock()

        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in
                self?.drainLatestFrame()
            }
        }
    }

    func clear() {
        lock.lock()
        pendingFrame = nil
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.view?.clear()
        }
    }

    @MainActor
    private func drainLatestFrame() {
        lock.lock()
        let frame = pendingFrame
        pendingFrame = nil
        lock.unlock()

        if let frame {
            view?.present(frame)
        }

        lock.lock()
        let hasPendingFrame = pendingFrame != nil
        if !hasPendingFrame {
            drainScheduled = false
        }
        lock.unlock()

        if hasPendingFrame {
            DispatchQueue.main.async { [weak self] in
                self?.drainLatestFrame()
            }
        }
    }
}
#endif
