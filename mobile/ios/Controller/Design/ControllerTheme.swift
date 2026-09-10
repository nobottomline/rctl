import SwiftUI
import UIKit

/// Light "warm" palette shared with the web client's `.warm` theme:
/// terracotta signal on cream, sage for healthy state, muted ink for text.
enum ControllerPalette {
    static let canvas = Color(red: 0.953, green: 0.918, blue: 0.843)        // #F3EAD7
    static let canvasDeep = Color(red: 0.933, green: 0.890, blue: 0.804)    // #EEE3CD
    static let surface = Color(red: 0.984, green: 0.961, blue: 0.910)       // #FBF5E8
    static let elevated = Color(red: 0.996, green: 0.980, blue: 0.941)      // #FEFAF0
    static let line = Color(red: 0.902, green: 0.851, blue: 0.749)          // #E6D9BF
    static let lineStrong = Color(red: 0.851, green: 0.780, blue: 0.655)    // #D9C7A7

    static let ink = Color(red: 0.176, green: 0.141, blue: 0.090)           // #2D2417
    static let inkDim = Color(red: 0.341, green: 0.290, blue: 0.216)        // #574A37
    static let muted = Color(red: 0.549, green: 0.482, blue: 0.384)         // #8C7B62
    static let faint = Color(red: 0.678, green: 0.608, blue: 0.498)         // #AD9B7F

    static let signal = Color(red: 0.761, green: 0.369, blue: 0.227)        // #C25E3A
    static let signalHigh = Color(red: 0.831, green: 0.451, blue: 0.298)    // #D4734C
    static let signalSoft = Color(red: 0.945, green: 0.867, blue: 0.792)    // #F1DDCA
    static let onSignal = Color(red: 0.992, green: 0.965, blue: 0.918)      // #FDF6EA

    static let healthy = Color(red: 0.310, green: 0.604, blue: 0.408)       // #4F9A68
    static let healthySoft = Color(red: 0.863, green: 0.925, blue: 0.878)
    static let warning = signal
    static let danger = Color(red: 0.745, green: 0.267, blue: 0.220)        // #BE4438
    static let dangerSoft = Color(red: 0.957, green: 0.847, blue: 0.824)    // #F4D8D2
}

enum ControllerMotion {
    static let standard = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let immediate = Animation.easeOut(duration: 0.16)
}

/// A translucent parchment surface that lets the ambient background show
/// through without competing with the content on top of it.
struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 20
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(ControllerPalette.elevated.opacity(0.82))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.9), ControllerPalette.line.opacity(0.9)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: ControllerPalette.ink.opacity(0.07), radius: 22, x: 0, y: 10)
            .shadow(color: ControllerPalette.ink.opacity(0.04), radius: 2, x: 0, y: 1)
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = 20, padding: CGFloat = 18) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, padding: padding))
    }

    /// Constrains wide layouts (iPad, landscape) so the page reads as a column.
    func pageColumn(maxWidth: CGFloat = 620) -> some View {
        frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
    }
}

/// Filled call-to-action: ink on cream, terracotta for the prominent variant.
struct PrimaryButtonStyle: ButtonStyle {
    enum Tone { case ink, signal, danger }
    var tone: Tone = .ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 18)
            .background(background.opacity(configuration.isPressed ? 0.86 : 1), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: background.opacity(configuration.isPressed ? 0.12 : 0.28), radius: 16, x: 0, y: 8)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(ControllerMotion.immediate, value: configuration.isPressed)
    }

    private var background: Color {
        switch tone {
        case .ink: ControllerPalette.ink
        case .signal: ControllerPalette.signal
        case .danger: ControllerPalette.danger
        }
    }

    private var foreground: Color {
        switch tone {
        case .ink: ControllerPalette.elevated
        case .signal, .danger: ControllerPalette.onSignal
        }
    }
}

/// Outlined secondary action on a light surface.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(ControllerPalette.ink)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 18)
            .background(
                ControllerPalette.elevated.opacity(configuration.isPressed ? 0.6 : 0.9),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(ControllerPalette.lineStrong, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(ControllerMotion.immediate, value: configuration.isPressed)
    }
}

/// Small circular toolbar control used in the page header.
struct HeaderIconButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(prominent ? ControllerPalette.elevated : ControllerPalette.ink)
            .frame(width: 42, height: 42)
            .background(
                (prominent ? ControllerPalette.ink : ControllerPalette.elevated)
                    .opacity(configuration.isPressed ? 0.7 : 0.92),
                in: Circle()
            )
            .overlay {
                Circle().strokeBorder(prominent ? Color.clear : ControllerPalette.line, lineWidth: 1)
            }
            .shadow(color: ControllerPalette.ink.opacity(0.08), radius: 10, x: 0, y: 4)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(ControllerMotion.immediate, value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// Uppercase, tracked label used for section titles.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.1)
            .foregroundStyle(ControllerPalette.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Semantic status chip: a dot plus text, never color alone. `busy` swaps the
/// dot for a small activity indicator while the state is being determined.
struct StatusPill: View {
    enum Tone { case healthy, attention, danger, neutral }
    let text: String
    let tone: Tone
    var busy = false

    var body: some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .tint(dot)
                    .scaleEffect(0.7)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(dot)
                    .frame(width: 7, height: 7)
                    .overlay {
                        if tone == .healthy {
                            Circle().strokeBorder(dot.opacity(0.35), lineWidth: 3).padding(-3)
                        }
                    }
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(foreground)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(background, in: Capsule())
    }

    private var dot: Color {
        switch tone {
        case .healthy: ControllerPalette.healthy
        case .attention: ControllerPalette.signal
        case .danger: ControllerPalette.danger
        case .neutral: ControllerPalette.faint
        }
    }

    private var foreground: Color {
        switch tone {
        case .healthy: ControllerPalette.healthy
        case .attention: ControllerPalette.signal
        case .danger: ControllerPalette.danger
        case .neutral: ControllerPalette.inkDim
        }
    }

    private var background: Color {
        switch tone {
        case .healthy: ControllerPalette.healthySoft
        case .attention: ControllerPalette.signalSoft
        case .danger: ControllerPalette.dangerSoft
        case .neutral: ControllerPalette.canvasDeep
        }
    }
}

/// Small capsule glyph used as a section-header accessory (menus, refresh,
/// stop). The visual is compact; the hit area is kept at 44 points.
struct SectionAccessoryLabel: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.footnote.weight(.bold))
            .foregroundStyle(ControllerPalette.inkDim)
            .frame(width: 34, height: 26)
            .background(ControllerPalette.elevated.opacity(0.9), in: Capsule())
            .overlay { Capsule().strokeBorder(ControllerPalette.line, lineWidth: 1) }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

struct SectionAccessoryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(ControllerMotion.immediate, value: configuration.isPressed)
    }
}

/// The product mark: a tablet outline with a touch point and ripple rings,
/// matching the app icon. Drawn with shapes so it scales with Dynamic Type.
struct BrandMark: View {
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.27, green: 0.215, blue: 0.15), ControllerPalette.ink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [ControllerPalette.signalHigh.opacity(0.38), .clear],
                                center: UnitPoint(x: 0.85, y: 0.15),
                                startRadius: 0,
                                endRadius: size * 0.75
                            )
                        )
                }
            RoundedRectangle(cornerRadius: size * 0.09, style: .continuous)
                .strokeBorder(ControllerPalette.onSignal.opacity(0.94), lineWidth: size * 0.05)
                .frame(width: size * 0.5, height: size * 0.72)
                .offset(y: -size * 0.0)
            ZStack {
                Circle()
                    .strokeBorder(ControllerPalette.signalHigh.opacity(0.45), lineWidth: size * 0.025)
                    .frame(width: size * 0.43, height: size * 0.43)
                Circle()
                    .strokeBorder(ControllerPalette.signalHigh.opacity(0.9), lineWidth: size * 0.036)
                    .frame(width: size * 0.27, height: size * 0.27)
                Circle()
                    .fill(ControllerPalette.signalHigh)
                    .frame(width: size * 0.13, height: size * 0.13)
                Circle()
                    .fill(ControllerPalette.onSignal)
                    .frame(width: size * 0.052, height: size * 0.052)
            }
            .offset(y: size * 0.03)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
enum ControllerHaptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
