import SwiftUI
import UIKit

enum RemotePalette {
    static let canvas = Color(red: 10 / 255, green: 11 / 255, blue: 13 / 255)
    static let surface = Color(red: 16 / 255, green: 19 / 255, blue: 25 / 255)
    static let raised = Color(red: 27 / 255, green: 32 / 255, blue: 41 / 255)
    static let line = Color(red: 44 / 255, green: 51 / 255, blue: 62 / 255)
    static let primaryText = Color(red: 233 / 255, green: 235 / 255, blue: 239 / 255)
    static let secondaryText = Color(red: 170 / 255, green: 177 / 255, blue: 189 / 255)
    static let mutedText = Color(red: 113 / 255, green: 121 / 255, blue: 134 / 255)
    static let signal = Color(red: 246 / 255, green: 169 / 255, blue: 59 / 255)
    static let signalText = Color(red: 26 / 255, green: 18 / 255, blue: 6 / 255)
    static let online = Color(red: 70 / 255, green: 211 / 255, blue: 154 / 255)
    static let danger = Color(red: 251 / 255, green: 111 / 255, blue: 125 / 255)
}

struct RemoteIconButtonStyle: ButtonStyle {
    var selected = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(background(configuration.isPressed), in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(selected ? RemotePalette.signal.opacity(0.7) : RemotePalette.line, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }

    private var foreground: Color {
        if destructive { return RemotePalette.danger }
        return selected ? RemotePalette.signalText : RemotePalette.primaryText
    }

    private func background(_ pressed: Bool) -> Color {
        if selected { return RemotePalette.signal.opacity(pressed ? 0.78 : 1) }
        return RemotePalette.raised.opacity(pressed ? 0.62 : 1)
    }
}

struct RemoteActionButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(destructive ? RemotePalette.danger : RemotePalette.primaryText)
            .background(
                configuration.isPressed ? RemotePalette.line : RemotePalette.raised,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(destructive ? RemotePalette.danger.opacity(0.35) : RemotePalette.line, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct RemoteHomeGlyph: View {
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(lineWidth: 1.8)
                .frame(width: 20, height: 20)
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(lineWidth: 1.6)
                .frame(width: 7, height: 7)
        }
    }
}

@MainActor
enum RemoteHaptics {
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func action() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
