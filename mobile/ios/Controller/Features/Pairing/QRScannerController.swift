@preconcurrency import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Owns the capture session for pairing-code scanning and publishes the
/// current detection in preview-layer coordinates so the SwiftUI reticle can
/// follow the code. Metadata callbacks arrive on the main queue.
@MainActor
final class QRScannerController: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    enum Availability: Equatable {
        case initializing
        case running
        case denied
        case unavailable(String)
    }

    struct Detection: Equatable {
        let payload: String
        let bounds: CGRect
    }

    @Published private(set) var availability: Availability = .initializing
    @Published private(set) var detection: Detection?
    @Published private(set) var torchOn = false
    @Published private(set) var torchAvailable = false

    let session = AVCaptureSession()
    weak var previewLayer: AVCaptureVideoPreviewLayer?

    private let sessionQueue = DispatchQueue(label: "com.greatlove.rctl.controller.qr")
    private var camera: AVCaptureDevice?
    private var configured = false
    private var stopped = false
    private var authorizationTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?

    func start() async {
        stopped = false
        guard !configured else {
            resumeRunning()
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.requestAccessAndConfigure()
        }
        authorizationTask = task
        await task.value
    }

    func stop() {
        stopped = true
        authorizationTask?.cancel()
        authorizationTask = nil
        clearTask?.cancel()
        clearTask = nil
        detection = nil
        setTorch(false)
        let session = session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    func toggleTorch() {
        setTorch(!torchOn)
    }

    private func resumeRunning() {
        let session = session
        sessionQueue.async {
            if !session.isRunning { session.startRunning() }
        }
    }

    private func requestAccessAndConfigure() async {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            authorized = false
        }
        guard !Task.isCancelled, !stopped else { return }
        guard authorized else {
            availability = .denied
            return
        }
        configure()
    }

    private func configure() {
        let discovered = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        guard let camera = discovered,
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            availability = .unavailable("This device has no usable camera.")
            return
        }
        session.beginConfiguration()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            availability = .unavailable("QR scanning is not available on this device.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        self.camera = camera
        configured = true
        torchAvailable = camera.hasTorch
        availability = .running
        resumeRunning()
    }

    private func setTorch(_ on: Bool) {
        guard let camera, camera.hasTorch else { return }
        do {
            try camera.lockForConfiguration()
            camera.torchMode = on ? .on : .off
            camera.unlockForConfiguration()
            torchOn = on
        } catch {
            torchOn = false
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // The delegate queue is the main queue; hop into the actor without a
        // suspension so the non-Sendable metadata objects stay on this thread.
        let objects = MetadataBatch(objects: metadataObjects)
        MainActor.assumeIsolated {
            self.process(objects.objects)
        }
    }

    /// Metadata objects are only ever touched on the main queue that
    /// AVFoundation delivers them on; the wrapper documents that invariant.
    private struct MetadataBatch: @unchecked Sendable {
        let objects: [AVMetadataObject]
    }

    private func process(_ objects: [AVMetadataObject]) {
        guard !stopped else { return }
        clearTask?.cancel()
        clearTask = nil
        guard let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let value = code.stringValue, !value.isEmpty else {
            detection = nil
            return
        }
        let bounds: CGRect
        if let layer = previewLayer, let transformed = layer.transformedMetadataObject(for: code) {
            bounds = transformed.bounds
        } else {
            bounds = .null
        }
        let next = Detection(payload: value, bounds: bounds)
        if next != detection { detection = next }
        // Frames without a code are not always reported; expire stale hits.
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            self?.detection = nil
        }
    }
}

/// Full-bleed camera preview that keeps its orientation aligned with the
/// interface and hands the layer to the controller for coordinate mapping.
struct CameraPreview: UIViewRepresentable {
    let controller: QRScannerController

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = controller.session
        view.previewLayer.videoGravity = .resizeAspectFill
        controller.previewLayer = view.previewLayer
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            alignOrientation()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            alignOrientation()
        }

        private func alignOrientation() {
            guard let connection = previewLayer.connection,
                  let orientation = window?.windowScene?.interfaceOrientation else { return }
            if #available(iOS 17.0, *) {
                let angle: CGFloat = switch orientation {
                case .portrait: 90
                case .portraitUpsideDown: 270
                case .landscapeLeft: 180
                case .landscapeRight: 0
                default: 90
                }
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            } else {
                let video: AVCaptureVideoOrientation = switch orientation {
                case .portrait: .portrait
                case .portraitUpsideDown: .portraitUpsideDown
                case .landscapeLeft: .landscapeLeft
                case .landscapeRight: .landscapeRight
                default: .portrait
                }
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = video
                }
            }
        }
    }
}
