import RctlClient
import RctlRealtime
import SwiftUI

struct RemoteControlView: View {
    private enum SheetDestination: String, Identifiable {
        case tools

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let deviceName: String
    private let isLocal: Bool
    @StateObject private var model: RemoteSessionModel
    @State private var presentedSheet: SheetDestination?
    @State private var keyboardPresented = false

    init(appModel: ControllerAppModel, device: ControllerDevice) {
        deviceName = device.name
        isLocal = false
        _model = StateObject(wrappedValue: RemoteSessionModel(appModel: appModel, deviceID: device.id))
    }

    init(appModel: ControllerAppModel, localDevice: LocalDeviceProfile, localClient: LocalDeviceClient) {
        deviceName = localDevice.name
        isLocal = true
        _model = StateObject(wrappedValue: RemoteSessionModel(appModel: appModel,
            target: .local(localDevice.address), localClient: localClient))
    }

    var body: some View {
        ZStack {
            RemotePalette.canvas.ignoresSafeArea()

            RemoteVideoRepresentable(
                session: model.session,
                inputEnabled: controlsEnabled,
                onTouch: model.sendTouch
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            sessionOverlay
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            RemoteSessionHeader(
                deviceName: deviceName,
                accessPath: model.accessPath,
                connectionLabel: connectionLabel,
                connectionColor: connectionColor,
                modeLabel: modeLabel,
                modeColor: modeColor,
                dismiss: { dismiss() }
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if keyboardPresented {
                RemoteKeyboardPanel(
                    sendText: model.sendText,
                    sendKey: model.sendKeyboard,
                    dismiss: { keyboardPresented = false }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                RemoteControlDock(
                    media: model.media,
                    interactionMode: model.interactionMode,
                    canControl: model.canControl,
                    selectMedia: { value in
                        keyboardPresented = false
                        Task { await model.selectMedia(value) }
                    },
                    selectMode: { value in
                        if value != .control { keyboardPresented = false }
                        model.setInteractionMode(value)
                    },
                    home: { model.sendHardware(.home) },
                    showKeyboard: { keyboardPresented = controlsEnabled },
                    showTools: {
                        keyboardPresented = false
                        presentedSheet = .tools
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .sheet(item: $presentedSheet) { destination in
            switch destination {
            case .tools:
                RemoteToolsSheet(
                    deviceName: deviceName,
                    accessPath: model.accessPath,
                    diagnostics: model.diagnostics,
                    controlsEnabled: controlsEnabled,
                    send: model.sendHardware,
                    reconnect: { Task { await model.connect() } }
                )
                .presentationDetents([.height(390), .medium])
                .presentationDragIndicator(.visible)
            }
        }
        .task { await model.connect() }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                Task { await model.resume() }
            case .inactive, .background:
                model.suspend()
            @unknown default:
                model.suspend()
            }
        }
        .onDisappear { model.disconnect() }
        .onChange(of: controlsEnabled) { enabled in
            if !enabled { keyboardPresented = false }
        }
        .animation(.easeOut(duration: 0.18), value: keyboardPresented)
    }

    @ViewBuilder
    private var sessionOverlay: some View {
        if model.state == .closed || model.state == .failed || model.state == .disconnected || model.videoHealth == .stalled {
            VStack(spacing: 14) {
                Image(systemName: model.state == .closed ? "stop.circle" : "wifi.exclamationmark")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(RemotePalette.danger)
                Text(model.state == .closed ? "Session ended" : model.videoHealth == .stalled ? "Video paused" : "Connection interrupted")
                    .font(.headline)
                    .foregroundStyle(RemotePalette.primaryText)
                Text(model.videoHealth == .stalled ? "No fresh frames. Control is disabled." :
                    model.state == .closed ? "Reconnect to start a new session." :
                    model.errorMessage ?? "The device connection was interrupted.")
                    .font(.subheadline)
                    .foregroundStyle(RemotePalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                if model.reconnecting {
                    ProgressView("Reconnecting \(model.reconnectAttempt)/3")
                        .tint(RemotePalette.signal)
                } else {
                    Button {
                        Task { await model.connect() }
                    } label: {
                        Text("Reconnect")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(RemotePalette.signalText)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(RemotePalette.signal, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(RemotePalette.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(RemotePalette.line, lineWidth: 1)
            }
            .padding(24)
        } else if !model.videoAvailable {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(RemotePalette.signal)
                Text(connectionLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(RemotePalette.secondaryText)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(RemotePalette.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(RemotePalette.line, lineWidth: 1)
            }
        }
    }

    private var controlsEnabled: Bool {
        model.media == .screen && model.canControl && model.interactionMode == .control
    }

    private var modeLabel: String {
        if model.media == .camera { return "CAMERA" }
        return model.interactionMode == .control ? "CONTROL" : "VIEW ONLY"
    }

    private var modeColor: Color {
        if model.media == .camera { return RemotePalette.primaryText }
        return model.interactionMode == .control ? RemotePalette.signal : RemotePalette.secondaryText
    }

    private var connectionLabel: String {
        switch model.state {
        case .idle: "Ready"
        case .signaling: isLocal ? "Connecting locally" : "Authorizing"
        case .connecting: "Connecting"
        case .connected: model.videoHealth == .stalled ? "Video paused" :
            !model.videoAvailable ? "Waiting for video" : model.media == .camera ? "Live camera" : "Live screen"
        case .disconnected: "Disconnected"
        case .failed: "Connection failed"
        case .closed: "Closed"
        }
    }

    private var connectionColor: Color {
        switch model.state {
        case .connected: model.videoHealth == .flowing ? RemotePalette.online : RemotePalette.signal
        case .failed, .disconnected: RemotePalette.danger
        case .signaling, .connecting: RemotePalette.signal
        default: RemotePalette.mutedText
        }
    }
}
