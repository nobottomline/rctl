import SwiftUI

struct RemoteToolsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let deviceName: String
    let controlsEnabled: Bool
    let send: (RemoteHardwareAction) -> Void
    let reconnect: () -> Void

    @State private var confirmsLock = false

    var body: some View {
        NavigationStack {
            ScrollView {
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
