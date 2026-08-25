import RctlClient
import RctlRealtime
import SwiftUI

struct RemoteControlView: View {
    @Environment(\.scenePhase) private var scenePhase
    let device: ControllerDevice
    @StateObject private var model: RemoteSessionModel

    init(appModel: ControllerAppModel, device: ControllerDevice) {
        self.device = device
        _model = StateObject(wrappedValue: RemoteSessionModel(appModel: appModel, deviceID: device.id))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            RemoteVideoRepresentable(
                session: model.session,
                inputEnabled: model.interactionMode == .control && model.canControl,
                onTouch: model.sendTouch
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            sessionOverlay
        }
        .overlay(alignment: .topTrailing) {
            if model.videoAvailable {
                modeBadge
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RemoteControlDock(model: model, deviceName: device.name)
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(device.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Image(systemName: connectionSymbol)
                    .foregroundStyle(connectionColor)
                    .accessibilityLabel(connectionLabel)
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
    }

    @ViewBuilder
    private var sessionOverlay: some View {
        if model.state == .failed || model.state == .disconnected {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title2)
                Text(model.errorMessage ?? "The device connection was interrupted.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                Button("Reconnect") {
                    Task { await model.connect() }
                }
                .buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(24)
        } else if !model.videoAvailable {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                Text(connectionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var modeBadge: some View {
        Label(
            model.media == .camera ? "Camera" : model.interactionMode == .control ? "Control" : "View only",
            systemImage: model.media == .camera ? "camera.fill" : model.interactionMode == .control ? "hand.tap.fill" : "eye.fill"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var connectionLabel: String {
        switch model.state {
        case .idle: "Ready"
        case .signaling: "Authorizing"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .failed: "Connection failed"
        case .closed: "Closed"
        }
    }

    private var connectionSymbol: String {
        model.state == .connected ? "checkmark.circle.fill" : "circle.fill"
    }

    private var connectionColor: Color {
        switch model.state {
        case .connected: .green
        case .failed, .disconnected: .red
        default: .secondary
        }
    }
}

private struct RemoteControlDock: View {
    @ObservedObject var model: RemoteSessionModel
    let deviceName: String
    @State private var confirmsLock = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                mediaMenu
                if model.media == .screen {
                    interactionPicker
                    homeButton
                } else {
                    cameraLabel
                }
                moreMenu
            }

            VStack(spacing: 8) {
                if model.media == .screen {
                    interactionPicker
                }
                HStack(spacing: 12) {
                    mediaMenu
                    if model.media == .screen {
                        homeButton
                    } else {
                        cameraLabel
                    }
                    Spacer(minLength: 0)
                    moreMenu
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .confirmationDialog(
            "Lock \(deviceName)?",
            isPresented: $confirmsLock,
            titleVisibility: .visible
        ) {
            Button("Lock Device") {
                model.sendHardware(.lock)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The remote session stays connected after the screen locks.")
        }
    }

    private var interactionPicker: some View {
        Picker(
            "Interaction",
            selection: Binding(
                get: { model.interactionMode },
                set: { value in model.setInteractionMode(value) }
            )
        ) {
            Label("View", systemImage: "eye").tag(RemoteInteractionMode.view)
            Label("Control", systemImage: "hand.tap").tag(RemoteInteractionMode.control)
        }
        .pickerStyle(.segmented)
        .frame(minWidth: 150, maxWidth: 190)
        .disabled(!model.canControl)
        .accessibilityHint("View mode blocks all remote input")
    }

    private var mediaMenu: some View {
        Menu {
            Button {
                Task { await model.selectMedia(.screen) }
            } label: {
                Label("Screen", systemImage: "display")
            }
            Button {
                Task { await model.selectMedia(.camera) }
            } label: {
                Label("Camera", systemImage: "camera")
            }
        } label: {
            Image(systemName: model.media == .screen ? "display" : "camera.fill")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Source")
        .accessibilityValue(model.media == .screen ? "Screen" : "Camera")
    }

    private var homeButton: some View {
        Button {
            model.sendHardware(.home)
        } label: {
            Image(systemName: "circle")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(!controlsEnabled)
        .accessibilityLabel("Home")
    }

    private var cameraLabel: some View {
        Label("Live Camera", systemImage: "record.circle")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
    }

    private var moreMenu: some View {
        Menu {
            if model.media == .screen {
                Section("System") {
                    Button {
                        model.sendHardware(.controlCenter)
                    } label: {
                        Label("Control Center", systemImage: "switch.2")
                    }
                    Button {
                        model.sendHardware(.notificationCenter)
                    } label: {
                        Label("Notification Center", systemImage: "bell")
                    }
                    Button {
                        model.sendHardware(.volumeUp)
                    } label: {
                        Label("Volume Up", systemImage: "speaker.plus")
                    }
                    Button {
                        model.sendHardware(.volumeDown)
                    } label: {
                        Label("Volume Down", systemImage: "speaker.minus")
                    }
                    Button {
                        confirmsLock = true
                    } label: {
                        Label("Lock Device", systemImage: "lock")
                    }
                }
                .disabled(!controlsEnabled)
            }

            Button {
                Task { await model.connect() }
            } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More controls")
    }

    private var controlsEnabled: Bool {
        model.canControl && model.interactionMode == .control
    }
}
