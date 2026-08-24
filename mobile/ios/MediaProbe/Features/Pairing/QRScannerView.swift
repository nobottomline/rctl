@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        QRScannerViewController(onCode: onCode)
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: QRScannerViewController, coordinator: ()) {
        uiViewController.stop()
    }
}

@MainActor
final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.nobottomline.rctl.mediaprobe.qr")
    private let onCode: @MainActor (String) -> Void
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var delivered = false
    private var stopped = false
    private var authorizationTask: Task<Void, Never>?
    private var unavailableView: UIStackView?

    init(onCode: @escaping @MainActor (String) -> Void) {
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        authorizationTask = Task { [weak self] in
            await self?.requestAccessAndStart()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    func stop() {
        stopped = true
        authorizationTask?.cancel()
        authorizationTask = nil
        let session = captureSession
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    private func requestAccessAndStart() async {
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
            showUnavailable(message: "Camera access is unavailable.")
            return
        }
        configureSession()
    }

    private func configureSession() {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              captureSession.canAddInput(input) else {
            showUnavailable(message: "This device has no available camera.")
            return
        }
        captureSession.beginConfiguration()
        captureSession.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else {
            captureSession.commitConfiguration()
            showUnavailable(message: "QR scanning is unavailable on this device.")
            return
        }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        captureSession.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview

        let session = captureSession
        sessionQueue.async {
            session.startRunning()
        }
    }

    private func showUnavailable(message: String) {
        guard unavailableView == nil else { return }
        let image = UIImageView(image: UIImage(systemName: "camera.slash"))
        image.tintColor = UIColor.white.withAlphaComponent(0.72)
        image.contentMode = .scaleAspectFit
        image.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let label = UILabel()
        label.text = message
        label.textColor = UIColor.white.withAlphaComponent(0.72)
        label.font = .preferredFont(forTextStyle: .body)
        label.textAlignment = .center
        label.numberOfLines = 0

        var configuration = UIButton.Configuration.borderedProminent()
        configuration.title = "Paste Pairing Code"
        configuration.image = UIImage(systemName: "doc.on.clipboard")
        configuration.imagePadding = 8
        let paste = UIButton(configuration: configuration)
        paste.addTarget(self, action: #selector(pastePairingCode), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [image, label, paste])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
        unavailableView = stack
    }

    @objc private func pastePairingCode() {
        guard let value = UIPasteboard.general.string, !delivered, !stopped else { return }
        delivered = true
        onCode(value)
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        Task { @MainActor [weak self] in
            guard let self, !delivered, !stopped else { return }
            delivered = true
            stop()
            onCode(value)
        }
    }
}
