@preconcurrency import AVFoundation
import UIKit

/// Camera capture for pairing-code scanning.
///
/// - Session configuration, `startRunning` and `stopRunning` run on a private
///   serial queue, never on the main thread (they block for hundreds of ms).
/// - Metadata arrives on the main queue (`.qr` only, full-frame rect of
///   interest) and is mapped into the preview layer's coordinates.
/// - Frames without a code are not always reported, so a detection expires
///   260 ms after the last callback.
/// - The owner decides when the camera runs (`start()` / `stop()`); the
///   service releases the session when it is deallocated.
@MainActor
final class QRScannerService {
    enum Availability: Equatable, Sendable {
        case initializing
        case running
        case denied
        case unavailable(String)
    }

    private(set) var availability: Availability = .initializing
    private(set) var detection: ScannerDetection?
    private(set) var isTorchOn = false
    private(set) var isTorchAvailable = false

    /// Availability or torch changed.
    var onStateChange: (@MainActor () -> Void)?
    /// A code appeared, moved, changed or expired.
    var onDetection: (@MainActor (ScannerDetection?) -> Void)?

    let previewView = ScannerCameraPreviewView()

    private let capture = CaptureSessionBox()
    private let metadataProxy = MetadataDelegateProxy()
    private var wantsRunning = false
    private var isConfigured = false
    private var isConfiguring = false
    private var expiry: DispatchWorkItem?
    private var torchRequest = 0
    private static let detectionLifetime: TimeInterval = 0.26

    init() {
        previewView.previewLayer.session = capture.session
        previewView.previewLayer.videoGravity = .resizeAspectFill
        metadataProxy.service = self
        capture.observeSession(
            interrupted: { [weak self] reason in self?.sessionWasInterrupted(reason: reason) },
            interruptionEnded: { [weak self] in self?.sessionInterruptionEnded() },
            runtimeError: { [weak self] in self?.sessionRuntimeError() }
        )
    }

    deinit {
        let capture = capture
        capture.queue.async { capture.tearDown() }
    }

    /// Starts (or resumes) the camera, asking for access the first time.
    func start() {
        wantsRunning = true
        if isConfigured {
            capture.setRunning(true)
            return
        }
        guard !isConfiguring else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            isConfiguring = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.isConfiguring = false
                        if granted {
                            if self.wantsRunning { self.configure() }
                        } else {
                            self.setAvailability(.denied)
                        }
                    }
                }
            }
        default:
            setAvailability(.denied)
        }
    }

    /// Stops the camera and forgets the current detection. The session stays
    /// configured so a later `start()` resumes quickly.
    func stop() {
        wantsRunning = false
        expiry?.cancel()
        expiry = nil
        publish(nil)
        // Invalidate any torch change still pending on the capture queue so its
        // completion cannot turn the button back on after the camera stopped.
        torchRequest += 1
        if isTorchOn {
            isTorchOn = false
            onStateChange?()
        }
        guard isConfigured else { return }
        capture.setRunning(false)
    }

    func setTorch(_ on: Bool) {
        guard isTorchAvailable, isConfigured, on != isTorchOn else { return }
        isTorchOn = on
        torchRequest += 1
        let request = torchRequest
        onStateChange?()
        capture.setTorch(on) { [weak self] applied in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, request == self.torchRequest, applied != self.isTorchOn else { return }
                    self.isTorchOn = applied
                    self.onStateChange?()
                }
            }
        }
    }

    // MARK: - Configuration

    private func configure() {
        isConfiguring = true
        let output = AVCaptureMetadataOutput()
        output.setMetadataObjectsDelegate(metadataProxy, queue: .main)
        capture.configure(output: output) { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isConfiguring = false
                    switch result {
                    case let .configured(torch):
                        self.isConfigured = true
                        self.isTorchAvailable = torch
                        self.setAvailability(.running, force: true)
                        self.previewView.alignOrientation()
                        if self.wantsRunning { self.capture.setRunning(true) }
                    case let .unavailable(reason):
                        self.setAvailability(.unavailable(reason))
                    }
                }
            }
        }
    }

    private func setAvailability(_ value: Availability, force: Bool = false) {
        guard force || value != availability else { return }
        availability = value
        onStateChange?()
    }

    // MARK: - Session events

    private func sessionWasInterrupted(reason: Int?) {
        expiry?.cancel()
        expiry = nil
        publish(nil)
        torchRequest += 1
        if isTorchOn {
            isTorchOn = false
        }
        if reason == AVCaptureSession.InterruptionReason.videoDeviceNotAvailableWithMultipleForegroundApps.rawValue {
            setAvailability(.unavailable("The camera is not available while other apps share the screen."), force: true)
        } else {
            onStateChange?()
        }
    }

    private func sessionInterruptionEnded() {
        guard isConfigured else { return }
        setAvailability(.running)
        if wantsRunning { capture.setRunning(true) }
    }

    private func sessionRuntimeError() {
        guard isConfigured, wantsRunning else { return }
        // Media services can reset underneath the session; one restart recovers it.
        capture.setRunning(true)
    }

    // MARK: - Metadata

    fileprivate func process(_ objects: [AVMetadataObject]) {
        guard wantsRunning else { return }
        expiry?.cancel()
        expiry = nil
        guard let code = objects.lazy.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              let value = code.stringValue, !value.isEmpty else {
            publish(nil)
            return
        }
        let bounds = previewView.previewLayer.transformedMetadataObject(for: code)?.bounds ?? .null
        publish(ScannerDetection(payload: value, bounds: bounds))
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.expiry = nil
                self?.publish(nil)
            }
        }
        expiry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.detectionLifetime, execute: item)
    }

    private func publish(_ next: ScannerDetection?) {
        guard next != detection else { return }
        detection = next
        onDetection?(next)
    }
}

/// Forwards main-queue metadata callbacks without the output retaining the service.
private final class MetadataDelegateProxy: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    /// Read and written on the main queue only.
    nonisolated(unsafe) weak var service: QRScannerService?

    /// Metadata objects are only touched on the main queue AVFoundation delivers them on.
    private struct Batch: @unchecked Sendable {
        let objects: [AVMetadataObject]
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let batch = Batch(objects: metadataObjects)
        MainActor.assumeIsolated {
            service?.process(batch.objects)
        }
    }
}

/// Owns the capture session. Everything except `session` (read by the preview
/// layer) is confined to `queue`.
private final class CaptureSessionBox: @unchecked Sendable {
    enum ConfigurationResult: Sendable {
        case configured(torch: Bool)
        case unavailable(String)
    }

    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "com.greatlove.rctl.uikit.qr-session", qos: .userInitiated)
    private var camera: AVCaptureDevice?
    private var output: AVCaptureMetadataOutput?
    private var observers: [NSObjectProtocol] = []

    private struct OutputBox: @unchecked Sendable {
        let output: AVCaptureMetadataOutput
    }

    func observeSession(
        interrupted: @escaping @MainActor (Int?) -> Void,
        interruptionEnded: @escaping @MainActor () -> Void,
        runtimeError: @escaping @MainActor () -> Void
    ) {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { note in
                let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
                MainActor.assumeIsolated { interrupted(reason) }
            },
            center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { _ in
                MainActor.assumeIsolated { interruptionEnded() }
            },
            center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { _ in
                MainActor.assumeIsolated { runtimeError() }
            },
        ]
    }

    func configure(output: AVCaptureMetadataOutput, completion: @escaping @Sendable (ConfigurationResult) -> Void) {
        let box = OutputBox(output: output)
        queue.async { [self] in
            completion(configureOnQueue(output: box.output))
        }
    }

    private func configureOnQueue(output: AVCaptureMetadataOutput) -> ConfigurationResult {
        let discovered = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        guard let camera = discovered,
              let input = try? AVCaptureDeviceInput(device: camera) else {
            return .unavailable("This device has no usable camera.")
        }
        session.beginConfiguration()
        // Pairing codes fill much of the frame; 720p detects them reliably at a
        // fraction of the default 1080p capture and metadata cost.
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return .unavailable("This device has no usable camera.")
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            session.commitConfiguration()
            return .unavailable("QR scanning is not available on this device.")
        }
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            session.removeOutput(output)
            session.removeInput(input)
            session.commitConfiguration()
            return .unavailable("QR scanning is not available on this device.")
        }
        output.metadataObjectTypes = [.qr]
        // Codes anywhere in the frame count; the reticle follows them.
        output.rectOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
        session.commitConfiguration()
        self.camera = camera
        self.output = output
        return .configured(torch: camera.hasTorch && camera.isTorchModeSupported(.on))
    }

    func setRunning(_ running: Bool) {
        queue.async { [self] in
            guard camera != nil else { return }
            if running, !session.isRunning {
                session.startRunning()
            } else if !running, session.isRunning {
                session.stopRunning()
            }
        }
    }

    func setTorch(_ on: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard let camera, camera.hasTorch else { completion(false); return }
            do {
                try camera.lockForConfiguration()
                camera.torchMode = on ? .on : .off
                camera.unlockForConfiguration()
                completion(on)
            } catch {
                completion(camera.torchMode == .on)
            }
        }
    }

    /// Called on `queue` when the owning service goes away.
    func tearDown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        output?.setMetadataObjectsDelegate(nil, queue: nil)
        if session.isRunning { session.stopRunning() }
        camera = nil
        output = nil
    }
}

/// Full-bleed camera preview whose connection orientation follows the interface.
@MainActor
final class ScannerCameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        unsafeDowncast(layer, to: AVCaptureVideoPreviewLayer.self)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = RCColor.stage
        isUserInteractionEnabled = false
        isAccessibilityElement = false
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

    func alignOrientation() {
        guard let connection = previewLayer.connection,
              let orientation = window?.windowScene?.interfaceOrientation else { return }
        if #available(iOS 17.0, *) {
            let angle: CGFloat = switch orientation {
            case .portraitUpsideDown: 270
            case .landscapeLeft: 180
            case .landscapeRight: 0
            default: 90
            }
            if connection.videoRotationAngle != angle, connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else {
            let video: AVCaptureVideoOrientation = switch orientation {
            case .portraitUpsideDown: .portraitUpsideDown
            case .landscapeLeft: .landscapeLeft
            case .landscapeRight: .landscapeRight
            default: .portrait
            }
            if connection.isVideoOrientationSupported, connection.videoOrientation != video {
                connection.videoOrientation = video
            }
        }
    }
}
