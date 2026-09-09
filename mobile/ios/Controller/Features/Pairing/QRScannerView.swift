import SwiftUI
import UIKit

/// Full-screen pairing-code scanner. The reticle rests in the center, springs
/// onto a detected code, confirms the lock, then hands the payload to the app
/// model. Pairing runs in place; the Devices screen pops on success.
struct PairingScannerView: View {
    private enum Phase: Equatable {
        case scanning
        case locked(String)
        case pairing
    }

    @ObservedObject var model: ControllerAppModel
    @StateObject private var scanner = QRScannerController()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Phase = .scanning
    @State private var lockTask: Task<Void, Never>?
    @State private var rejected: (payload: String, until: Date)?
    @State private var foreignCode = false
    @State private var breathe = false
    @State private var clipboardEmpty = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                switch scanner.availability {
                case .initializing, .running:
                    CameraPreview(controller: scanner)
                        .ignoresSafeArea()
                    ScannerReticle(
                        target: reticle(in: proxy),
                        tone: reticleTone,
                        breathing: breathe && scanner.detection == nil && phase == .scanning && !reduceMotion
                    )
                    .ignoresSafeArea()
                    instruction
                    controls
                    if phase == .pairing {
                        pairingCard
                    }
                case .denied:
                    CameraUnavailable(
                        symbol: "camera.slash.fill",
                        title: "Camera access needed",
                        text: "Allow camera access in Settings to scan pairing codes, or paste the code instead.",
                        primary: ("Open Settings", openSettings),
                        paste: paste,
                        back: { dismiss() }
                    )
                case let .unavailable(reason):
                    CameraUnavailable(
                        symbol: "camera.fill.badge.ellipsis",
                        title: "Camera unavailable",
                        text: reason + " You can still paste the pairing code.",
                        primary: nil,
                        paste: paste,
                        back: { dismiss() }
                    )
                }
            }
        }
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .task { await scanner.start() }
        .onAppear { breathe = true }
        .onDisappear {
            lockTask?.cancel()
            scanner.stop()
        }
        .onChange(of: scanner.detection) { detection in
            handle(detection)
        }
        .onChange(of: scenePhase) { scene in
            switch scene {
            case .active: Task { await scanner.start() }
            case .inactive, .background: scanner.stop()
            @unknown default: break
            }
        }
        .onChange(of: model.isBusy) { busy in
            // A paste from the intro screen or a finished claim both end here.
            if !busy, phase == .pairing, model.profile == nil {
                phase = .scanning
            }
        }
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if value.startLocation.x < 44, value.translation.width > 90, phase != .pairing {
                        dismiss()
                    }
                }
        )
        .alert("Nothing to paste", isPresented: $clipboardEmpty) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Copy the pairing code from relay admin first, then paste it here.")
        }
    }

    // MARK: - Overlay pieces

    private var instruction: some View {
        VStack(spacing: 6) {
            Text(instructionTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .contentTransition(.opacity)
            Text(instructionText)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 32)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 180)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .animation(ControllerMotion.standard, value: instructionTitle)
        .accessibilityElement(children: .combine)
    }

    private var instructionTitle: String {
        switch phase {
        case .scanning: foreignCode ? "That is not a pairing code" : "Scan the pairing code"
        case .locked: "Code found"
        case .pairing: "Pairing with relay"
        }
    }

    private var instructionText: String {
        switch phase {
        case .scanning:
            foreignCode
                ? "Open relay admin and show the controller pairing QR code."
                : "Point the camera at the QR code shown in relay admin."
        case .locked: "Hold still for a moment."
        case .pairing: "Creating your controller key and claiming the code."
        }
    }

    private var controls: some View {
        HStack(alignment: .center) {
            Button {
                ControllerHaptics.tap()
                dismiss()
            } label: {
                Image(systemName: "arrow.left")
            }
            .buttonStyle(ScannerCircleButtonStyle(prominent: true))
            .disabled(phase == .pairing)
            .accessibilityLabel("Back")

            Spacer()

            Button(action: paste) {
                Text("Paste code")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
            }
            .disabled(phase == .pairing)
            .accessibilityIdentifier("paste-pairing-code")

            Spacer()

            Button {
                ControllerHaptics.tap()
                scanner.toggleTorch()
            } label: {
                Image(systemName: scanner.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
            }
            .buttonStyle(ScannerCircleButtonStyle(prominent: scanner.torchOn))
            .disabled(!scanner.torchAvailable || phase == .pairing)
            .opacity(scanner.torchAvailable ? 1 : 0.35)
            .accessibilityLabel(scanner.torchOn ? "Turn flashlight off" : "Turn flashlight on")
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .frame(height: 200)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    private var pairingCard: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("Pairing with relay")
                .font(.headline)
                .foregroundStyle(.white)
        }
        .padding(28)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Reticle geometry

    private func reticle(in proxy: GeometryProxy) -> CGRect {
        let size = proxy.size
        let side = min(max(min(size.width, size.height) * 0.62, 220), 300)
        let resting = CGRect(
            x: (size.width - side) / 2,
            y: size.height * 0.44 - side / 2,
            width: side,
            height: side
        )
        guard phase != .pairing, let detection = scanner.detection, !detection.bounds.isNull,
              detection.bounds.width > 24, detection.bounds.height > 24 else {
            return resting
        }
        // The preview ignores the safe area; the overlay is measured in the same space.
        let bounds = detection.bounds.insetBy(dx: -16, dy: -16)
        let clampedSide = max(bounds.width, bounds.height, 120)
        return CGRect(
            x: bounds.midX - clampedSide / 2,
            y: bounds.midY - clampedSide / 2,
            width: clampedSide,
            height: clampedSide
        )
    }

    private var reticleTone: ScannerReticle.Tone {
        switch phase {
        case .scanning: foreignCode ? .rejected : .searching
        case .locked, .pairing: .locked
        }
    }

    // MARK: - Detection flow

    private func handle(_ detection: QRScannerController.Detection?) {
        guard phase != .pairing else { return }
        guard let detection else {
            lockTask?.cancel()
            lockTask = nil
            foreignCode = false
            if case .locked = phase { phase = .scanning }
            return
        }
        if let rejected, rejected.payload == detection.payload, Date() < rejected.until {
            return
        }
        guard Self.looksLikePairingPayload(detection.payload) else {
            foreignCode = true
            return
        }
        foreignCode = false
        if case let .locked(payload) = phase, payload == detection.payload { return }
        lockTask?.cancel()
        phase = .locked(detection.payload)
        ControllerHaptics.tap()
        let payload = detection.payload
        lockTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 120 : 420))
            guard !Task.isCancelled, phase == .locked(payload) else { return }
            deliver(payload)
        }
    }

    private func deliver(_ payload: String) {
        phase = .pairing
        ControllerHaptics.success()
        Task { @MainActor in
            await model.pair(using: payload)
            guard model.profile == nil else { return }
            // Failure is explained by the root alert; keep scanning but skip
            // this payload for a while so the same expired code does not loop.
            rejected = (payload, Date().addingTimeInterval(6))
            phase = .scanning
        }
    }

    /// Cheap shape check so arbitrary QR codes do not trigger a relay round trip.
    static func looksLikePairingPayload(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.utf8.count <= 4096 && trimmed.hasPrefix("{") && trimmed.hasSuffix("}")
            && trimmed.contains("pairing_id") && trimmed.contains("relay_id")
    }

    private func paste() {
        guard phase != .pairing else { return }
        guard UIPasteboard.general.hasStrings,
              let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            clipboardEmpty = true
            return
        }
        lockTask?.cancel()
        deliver(value)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

// MARK: - Reticle

/// Dimmed scrim with a clear window and four corner brackets that animate to
/// the target rectangle.
struct ScannerReticle: View {
    enum Tone { case searching, locked, rejected }

    let target: CGRect
    let tone: Tone
    let breathing: Bool

    var body: some View {
        ZStack {
            ScrimWithWindow(window: target, cornerRadius: 24)
                .fill(Color.black.opacity(0.48), style: FillStyle(eoFill: true))
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                .frame(width: target.width, height: target.height)
                .position(x: target.midX, y: target.midY)
            ReticleBrackets(cornerRadius: 24, length: min(34, target.width * 0.2))
                .stroke(color, style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                .frame(width: target.width, height: target.height)
                .position(x: target.midX, y: target.midY)
                .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 1)
                .scaleEffect(breathing ? 1.035 : 1)
                .animation(
                    breathing ? .easeInOut(duration: 1.7).repeatForever(autoreverses: true) : .default,
                    value: breathing
                )
            if tone == .locked {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white, color)
                    .position(x: target.midX, y: target.minY - 30)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: target)
        .animation(ControllerMotion.standard, value: tone)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch tone {
        case .searching: .white
        case .locked: Color(red: 0.42, green: 0.84, blue: 0.58)
        case .rejected: Color(red: 1.0, green: 0.74, blue: 0.38)
        }
    }
}

/// Everything except a rounded window, filled with the even-odd rule.
private struct ScrimWithWindow: Shape {
    var window: CGRect
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(window.minX, window.minY), AnimatablePair(window.width, window.height)) }
        set { window = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: window, cornerSize: CGSize(width: cornerRadius, height: cornerRadius), style: .continuous)
        return path
    }
}

/// Four rounded corner brackets inset in the shape's rect.
struct ReticleBrackets: Shape {
    var cornerRadius: CGFloat
    var length: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        let l = max(0, min(length, min(rect.width, rect.height) / 2 - r))

        // Top-left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + r + l))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r + l, y: rect.minY))

        // Top-right
        path.move(to: CGPoint(x: rect.maxX - r - l, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                    startAngle: .degrees(270), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r + l))

        // Bottom-right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - r - l))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - r - l, y: rect.maxY))

        // Bottom-left
        path.move(to: CGPoint(x: rect.minX + r + l, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r - l))
        return path
    }
}

// MARK: - Controls and fallbacks

private struct ScannerCircleButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .frame(width: 60, height: 60)
            .background(
                (prominent ? Color.white : Color.white.opacity(0.18))
                    .opacity(configuration.isPressed ? 0.7 : 1),
                in: Circle()
            )
            .overlay {
                Circle().strokeBorder(Color.white.opacity(prominent ? 0 : 0.28), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(ControllerMotion.immediate, value: configuration.isPressed)
            .contentShape(Circle())
    }
}

private struct CameraUnavailable: View {
    let symbol: String
    let title: String
    let text: String
    let primary: (String, () -> Void)?
    let paste: () -> Void
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) {
                    Image(systemName: "arrow.left")
                }
                .buttonStyle(ScannerCircleButtonStyle(prominent: false))
                .accessibilityLabel("Back")
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    if let primary {
                        Button(primary.0, action: primary.1)
                            .buttonStyle(ScannerWideButtonStyle(prominent: true))
                    }
                    Button("Paste pairing code", action: paste)
                        .buttonStyle(ScannerWideButtonStyle(prominent: false))
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: 340)
            .padding(.horizontal, 28)
            Spacer()
        }
    }
}

private struct ScannerWideButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                (prominent ? Color.white : Color.white.opacity(0.14)).opacity(configuration.isPressed ? 0.75 : 1),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(prominent ? 0 : 0.3), lineWidth: 1)
            }
            .animation(ControllerMotion.immediate, value: configuration.isPressed)
    }
}
