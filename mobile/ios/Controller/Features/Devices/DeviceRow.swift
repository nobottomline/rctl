import RctlClient
import SwiftUI

/// One saved or relay device. Status is semantic text plus a dot, never color alone.
struct DeviceRow: View {
    struct Status {
        let text: String
        let tone: StatusPill.Tone
    }

    let name: String
    let detail: String
    let status: Status
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(enabled ? ControllerPalette.signalSoft : ControllerPalette.canvasDeep)
                    Image(systemName: "ipad.landscape")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(enabled ? ControllerPalette.signal : ControllerPalette.faint)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ControllerPalette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(ControllerPalette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                StatusPill(text: status.text, tone: status.tone)
                    .fixedSize()
                    .layoutPriority(1)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ControllerPalette.faint)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(DeviceRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(status.text)")
        .accessibilityHint(enabled ? "Opens remote control" : "Shows why this device is unavailable")
    }
}

private struct DeviceRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                ControllerPalette.ink.opacity(configuration.isPressed ? 0.05 : 0),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .animation(ControllerMotion.immediate, value: configuration.isPressed)
    }
}

/// A group of rows inside one glass surface with hairline separators.
struct DeviceGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .glassSurface(cornerRadius: 22, padding: 6)
    }
}

struct RowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(ControllerPalette.line.opacity(0.8))
            .frame(height: 1)
            .padding(.leading, 68)
            .padding(.trailing, 12)
    }
}

/// Compact inline call-to-action row used at the end of a group.
struct AddRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(ControllerPalette.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ControllerPalette.signal)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ControllerPalette.ink)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(ControllerPalette.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "plus")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(ControllerPalette.faint)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(DeviceRowButtonStyle())
    }
}

/// Section title row with an optional trailing accessory (menu, counter).
struct SectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            SectionLabel(text: title)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(ControllerPalette.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 6)
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        accessory = EmptyView()
    }
}

/// First-run hero shown while nothing is saved or paired.
struct DevicesHero: View {
    let pairRelay: () -> Void
    let addLocal: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            HeroEmblem()
                .padding(.top, 6)
            VStack(spacing: 8) {
                Text("Your iPad, one tap away")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(ControllerPalette.ink)
                    .multilineTextAlignment(.center)
                Text("Add a device on your local network, or pair with your relay to control it from anywhere.")
                    .font(.subheadline)
                    .foregroundStyle(ControllerPalette.inkDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                Button(action: pairRelay) {
                    Label("Pair with relay", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("pair-relay")
                Button(action: addLocal) {
                    Label("Add local device", systemImage: "wifi")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("add-local-device")
            }
        }
        .glassSurface(cornerRadius: 26, padding: 24)
    }
}

/// Emblem for the empty state: the brand mark ringed by soft signal halos.
private struct HeroEmblem: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { ring in
                Circle()
                    .strokeBorder(ControllerPalette.signal.opacity(0.22 - Double(ring) * 0.06), lineWidth: 1)
                    .frame(width: 96 + CGFloat(ring) * 34, height: 96 + CGFloat(ring) * 34)
                    .scaleEffect(pulse && !reduceMotion ? 1.06 : 1)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 2.6).repeatForever(autoreverses: true).delay(Double(ring) * 0.25),
                        value: pulse
                    )
            }
            BrandMark(size: 72)
                .shadow(color: ControllerPalette.ink.opacity(0.22), radius: 18, x: 0, y: 10)
        }
        .frame(height: 170)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }
}

/// Two short explainers that sit under the hero.
struct ConnectionModesStrip: View {
    var body: some View {
        HStack(spacing: 12) {
            ModeTile(
                symbol: "wifi",
                title: "Local network",
                text: "Direct connection by private address. No account, no VPS."
            )
            ModeTile(
                symbol: "globe",
                title: "Relay",
                text: "From anywhere, with a one-time pairing and a device-bound key."
            )
        }
    }

    private struct ModeTile: View {
        let symbol: String
        let title: String
        let text: String

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ControllerPalette.signal)
                    .frame(width: 34, height: 34)
                    .background(ControllerPalette.signalSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ControllerPalette.ink)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(ControllerPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 18, padding: 14)
            .accessibilityElement(children: .combine)
        }
    }
}
