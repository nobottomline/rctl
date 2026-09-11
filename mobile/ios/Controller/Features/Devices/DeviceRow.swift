import RctlClient
import SwiftUI

/// One saved or relay device. Status is semantic text plus a dot, never color alone.
struct DeviceRow: View {
    struct Status {
        let text: String
        let tone: StatusPill.Tone
        var busy = false
    }

    let name: String
    let detail: String
    let status: Status
    let enabled: Bool
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            HStack(alignment: stacked ? .top : .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(enabled ? ControllerPalette.signalSoft : ControllerPalette.canvasDeep)
                    Image(systemName: "ipad.and.iphone")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(enabled ? ControllerPalette.signal : ControllerPalette.faint)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

                if stacked {
                    // Large text: stack the chip under the text so an address
                    // is never truncated to make room for it.
                    VStack(alignment: .leading, spacing: 6) {
                        texts
                        StatusPill(text: status.text, tone: status.tone, busy: status.busy)
                    }
                    Spacer(minLength: 6)
                } else {
                    texts
                    Spacer(minLength: 6)
                    StatusPill(text: status.text, tone: status.tone, busy: status.busy)
                        .fixedSize()
                        .layoutPriority(1)
                }
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

    /// XXXL and the accessibility sizes stack the chip under the text.
    private var stacked: Bool {
        dynamicTypeSize >= .xxxLarge
    }

    private var texts: some View {
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
                .minimumScaleFactor(stacked ? 0.7 : 0.85)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
        }
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
