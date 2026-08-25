import RctlClient
import SwiftUI

struct RemoteSessionHeader: View {
    let deviceName: String
    let connectionLabel: String
    let connectionColor: Color
    let modeLabel: String
    let modeColor: Color
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: dismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(RemoteIconButtonStyle())
            .accessibilityLabel("Devices")

            VStack(alignment: .leading, spacing: 3) {
                Text(deviceName)
                    .font(.headline)
                    .foregroundStyle(RemotePalette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                HStack(spacing: 6) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 6, height: 6)
                    Text(connectionLabel)
                        .font(.caption)
                        .foregroundStyle(RemotePalette.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Text(modeLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(modeColor)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(modeColor.opacity(0.12), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(modeColor.opacity(0.3), lineWidth: 1)
                }
                .accessibilityLabel("Interaction mode")
                .accessibilityValue(modeLabel)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RemotePalette.canvas.opacity(0.96))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

struct RemoteControlDock: View {
    let media: ControllerMediaRole
    let interactionMode: RemoteInteractionMode
    let canControl: Bool
    let selectMedia: (ControllerMediaRole) -> Void
    let selectMode: (RemoteInteractionMode) -> Void
    let home: () -> Void
    let showKeyboard: () -> Void
    let showTools: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                sourceSelector
                modeSelector
                homeButton
                keyboardButton
                toolsButton
            }

            HStack(spacing: 6) {
                compactSourceMenu
                compactModeSelector
                homeButton
                keyboardButton
                toolsButton
            }
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(RemotePalette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(RemotePalette.line, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 680)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var sourceSelector: some View {
        HStack(spacing: 2) {
            sourceButton(.screen, title: "Screen", symbol: "display")
            sourceButton(.camera, title: "Camera", symbol: "camera")
        }
        .padding(3)
        .background(RemotePalette.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(RemotePalette.line, lineWidth: 1)
        }
    }

    private var modeSelector: some View {
        modeSelector(width: 154)
    }

    private var compactModeSelector: some View {
        modeSelector(width: 106)
    }

    private func modeSelector(width: CGFloat) -> some View {
        HStack(spacing: 2) {
            modeButton(.view, title: "View", symbol: "eye")
            modeButton(.control, title: "Control", symbol: "hand.tap")
        }
        .padding(3)
        .background(RemotePalette.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(RemotePalette.line, lineWidth: 1)
        }
        .frame(width: width)
        .accessibilityElement(children: .contain)
        .accessibilityHint("View mode blocks all remote input")
    }

    private var compactSourceMenu: some View {
        Menu {
            Button {
                chooseMedia(.screen)
            } label: {
                Label("Screen", systemImage: "display")
            }
            Button {
                chooseMedia(.camera)
            } label: {
                Label("Camera", systemImage: "camera")
            }
        } label: {
            Image(systemName: media == .screen ? "display" : "camera.fill")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 46, height: 46)
        }
        .buttonStyle(RemoteIconButtonStyle(selected: true))
        .accessibilityLabel("Source")
        .accessibilityValue(media == .screen ? "Screen" : "Camera")
    }

    private func sourceButton(
        _ value: ControllerMediaRole,
        title: String,
        symbol: String
    ) -> some View {
        let selected = media == value
        return Button {
            chooseMedia(value)
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(minWidth: 74, minHeight: 38)
                .padding(.horizontal, 3)
                .foregroundStyle(selected ? RemotePalette.signalText : RemotePalette.secondaryText)
                .background(selected ? RemotePalette.signal : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func modeButton(
        _ value: RemoteInteractionMode,
        title: String,
        symbol: String
    ) -> some View {
        let selected = interactionMode == value
        return Button {
            guard value == .view || canControl else { return }
            RemoteHaptics.selection()
            selectMode(value)
        } label: {
            ViewThatFits(in: .horizontal) {
                Label(title, systemImage: symbol)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: symbol)
            }
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 38)
                .foregroundStyle(selected ? selectedModeText(value) : RemotePalette.secondaryText)
                .background(selected ? selectedModeBackground(value) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(value == .control && !canControl)
        .opacity(value == .control && !canControl ? 0.42 : 1)
        .accessibilityLabel(title)
    }

    private var homeButton: some View {
        Button {
            RemoteHaptics.action()
            home()
        } label: {
            RemoteHomeGlyph()
                .frame(width: 46, height: 46)
        }
        .buttonStyle(RemoteIconButtonStyle())
        .disabled(!controlsEnabled)
        .opacity(controlsEnabled ? 1 : 0.42)
        .accessibilityLabel("Home")
    }

    private var toolsButton: some View {
        Button {
            RemoteHaptics.selection()
            showTools()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 46, height: 46)
        }
        .buttonStyle(RemoteIconButtonStyle())
        .accessibilityLabel("Session controls")
    }

    private var keyboardButton: some View {
        Button {
            RemoteHaptics.selection()
            showKeyboard()
        } label: {
            Image(systemName: "keyboard")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 46, height: 46)
        }
        .buttonStyle(RemoteIconButtonStyle())
        .disabled(!controlsEnabled)
        .opacity(controlsEnabled ? 1 : 0.42)
        .accessibilityLabel("Keyboard")
    }

    private var controlsEnabled: Bool {
        media == .screen && canControl && interactionMode == .control
    }

    private func chooseMedia(_ value: ControllerMediaRole) {
        guard media != value else { return }
        RemoteHaptics.selection()
        selectMedia(value)
    }

    private func selectedModeText(_ value: RemoteInteractionMode) -> Color {
        value == .control ? RemotePalette.signalText : RemotePalette.primaryText
    }

    private func selectedModeBackground(_ value: RemoteInteractionMode) -> Color {
        value == .control ? RemotePalette.signal : RemotePalette.raised
    }
}
