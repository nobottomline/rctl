import SwiftUI

struct RemoteToolsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let deviceName: String
    let accessPath: RemoteAccessPath
    let controlsEnabled: Bool
    let send: (RemoteHardwareAction) -> Void
    let reconnect: () -> Void

    @State private var confirmsLock = false

    var body: some View {
        NavigationStack {
            ScrollView {
                SessionConnectionBlock(accessPath: accessPath)
                    .padding(.bottom, 14)
                LazyVGrid(columns: columns, spacing: 10) {
                    tool("Control Center", symbol: "switch.2", action: .controlCenter)
                    tool("Notifications", symbol: "bell", action: .notificationCenter)
                    tool("Volume Up", symbol: "speaker.plus", action: .volumeUp)
                    tool("Volume Down", symbol: "speaker.minus", action: .volumeDown)
                }

                Divider()
                    .overlay(RemotePalette.line)
                    .padding(.vertical, 8)

                Button {
                    RemoteHaptics.warning()
                    confirmsLock = true
                } label: {
                    Label("Lock Device", systemImage: "lock")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(RemoteActionButtonStyle(destructive: true))
                .disabled(!controlsEnabled)
                .opacity(controlsEnabled ? 1 : 0.42)

                Button {
                    RemoteHaptics.action()
                    reconnect()
                    dismiss()
                } label: {
                    Label("Reconnect Session", systemImage: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(RemoteActionButtonStyle())
            }
            .padding(16)
            .background(RemotePalette.canvas.ignoresSafeArea())
            .navigationTitle("Session Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(RemotePalette.canvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(RemotePalette.signal)
                }
            }
            .confirmationDialog(
                "Lock \(deviceName)?",
                isPresented: $confirmsLock,
                titleVisibility: .visible
            ) {
                Button("Lock Device", role: .destructive) {
                    send(.lock)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The remote session stays connected after the screen locks.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 10),
            count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
        )
    }

    private func tool(
        _ title: String,
        symbol: String,
        action: RemoteHardwareAction
    ) -> some View {
        Button {
            RemoteHaptics.action()
            send(action)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 24)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 14)
        }
        .buttonStyle(RemoteActionButtonStyle())
        .disabled(!controlsEnabled)
        .opacity(controlsEnabled ? 1 : 0.42)
    }
}

/// Read-only facts about the open session. The trust line is factual: LAN is
/// a trusted network, not an authenticated pairing.
struct SessionConnectionBlock: View {
    let accessPath: RemoteAccessPath

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONNECTION")
                .font(.caption2.weight(.semibold))
                .tracking(1)
                .foregroundStyle(RemotePalette.mutedText)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                row("Path") {
                    HStack(spacing: 8) {
                        AccessPathBadge(path: accessPath)
                        Text(isLAN ? "Local network" : "Relay")
                            .foregroundStyle(RemotePalette.primaryText)
                    }
                }
                Divider().overlay(RemotePalette.line)
                row("Endpoint") {
                    Text(endpointText)
                        .font(.footnote.monospaced())
                        .foregroundStyle(RemotePalette.primaryText)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Divider().overlay(RemotePalette.line)
                row("Trust") {
                    Text(isLAN ? "Trusted network · not paired" : "Authenticated controller")
                        .foregroundStyle(isLAN ? RemotePalette.signal : RemotePalette.online)
                }
            }
            .background(RemotePalette.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(RemotePalette.line, lineWidth: 1)
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(RemotePalette.secondaryText)
                .frame(width: 72, alignment: .leading)
            content()
                .font(.footnote.weight(.medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .accessibilityElement(children: .combine)
    }

    private var isLAN: Bool {
        if case .lan = accessPath { true } else { false }
    }

    private var endpointText: String {
        switch accessPath {
        case .lan(let address): address.displayAddress
        case .relay(let origin):
            if let origin, let host = URLComponents(string: origin)?.host { host } else { origin ?? "Unavailable" }
        }
    }
}
