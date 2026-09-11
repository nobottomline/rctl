import RctlRealtime
import SwiftUI
import UIKit

/// Bonjour discovery on the Devices screen. Discovery is an unverified hint:
/// rows never claim ownership, and every state keeps manual entry reachable.
/// The group keeps a stable shape across states so rows do not jump.
struct NearbySection: View {
    @ObservedObject var localDevices: LocalDevicesModel
    let select: (DiscoveredLocalDevice) -> Void
    let replace: (DiscoveredLocalDevice, LocalDeviceProfile) -> Void
    let addByAddress: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var checking: LocalServiceIdentity?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Nearby", subtitle: subtitle) {
                if localDevices.discoveryEnabled {
                    HStack(spacing: 2) {
                        if localDevices.discoveryState == .searching, !localDevices.selectingNearby {
                            ProgressView()
                                .controlSize(.small)
                                .tint(ControllerPalette.muted)
                                .frame(width: 24, height: 24)
                                .accessibilityLabel("Searching")
                        }
                        Button {
                            ControllerHaptics.tap()
                            localDevices.restartDiscovery()
                        } label: {
                            SectionAccessoryLabel(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(SectionAccessoryButtonStyle())
                        .disabled(localDevices.selectingNearby || localDevices.discoveryState == .permissionDenied)
                        .accessibilityLabel("Search again")
                        Button {
                            ControllerHaptics.tap()
                            localDevices.setDiscoveryEnabled(false)
                        } label: {
                            SectionAccessoryLabel(systemName: "xmark")
                        }
                        .buttonStyle(SectionAccessoryButtonStyle())
                        .accessibilityLabel("Stop searching")
                        .accessibilityIdentifier("stop-discovery")
                    }
                }
            }
            DeviceGroup {
                if localDevices.discoveryEnabled {
                    rows
                    trailing
                } else {
                    AddRow(
                        title: "Find devices on this network",
                        subtitle: "Nothing connects until you choose one",
                        systemImage: "bonjour"
                    ) {
                        ControllerHaptics.tap()
                        localDevices.setDiscoveryEnabled(true)
                    }
                    .accessibilityIdentifier("find-nearby-devices")
                }
            }
            if localDevices.discoveryEnabled {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    Text("Found devices are not verified. Use LAN control only on a network you trust.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(ControllerPalette.faint)
                .padding(.horizontal, 8)
            }
        }
        .animation(ControllerMotion.standard, value: displayed.map(\.id))
        .animation(ControllerMotion.standard, value: localDevices.discoveryEnabled)
        .animation(ControllerMotion.standard, value: localDevices.discoveryState)
        .onChange(of: localDevices.selectingNearby) { selecting in
            if !selecting { checking = nil }
        }
        .onChange(of: localDevices.discoveryEnabled) { enabled in
            if !enabled { checking = nil }
        }
    }

    // MARK: - Rows

    private var displayed: [DiscoveredLocalDevice] {
        localDevices.nearby
    }

    private var rows: some View {
        ForEach(Array(displayed.enumerated()), id: \.element.id) { index, device in
            let saved = savedMatch(for: device)
            DeviceRow(
                name: device.id.name,
                detail: detail(for: device, saved: saved),
                status: status(for: device, saved: saved),
                enabled: device.canResolve && !localDevices.selectingNearby
            ) {
                ControllerHaptics.tap()
                checking = device.id
                select(device)
            }
            .contextMenu {
                if device.isPresent, device.endpoint != nil, !localDevices.devices.isEmpty {
                    Menu {
                        ForEach(localDevices.devices) { profile in
                            Button {
                                checking = device.id
                                replace(device, profile)
                            } label: {
                                Text("\(profile.name) · \(profile.address.displayAddress)")
                            }
                        }
                    } label: {
                        Label("Use address for a saved device", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
            if index < displayed.count - 1 || hasTrailing {
                RowSeparator()
            }
        }
    }

    private var hasTrailing: Bool {
        localDevices.discoveryState == .permissionDenied
            || localDevices.discoveryState == .unavailable
            || displayed.isEmpty
    }

    @ViewBuilder
    private var trailing: some View {
        switch localDevices.discoveryState {
        case .permissionDenied:
            DiscoveryNotice(
                symbol: "hand.raised",
                title: "Local Network access is off",
                text: "Allow it in Settings to find devices. Adding by address needs the same permission.",
                primary: ("Open Settings", openSettings),
                secondary: ("Add by address", addByAddress)
            )
        case .unavailable:
            DiscoveryNotice(
                symbol: "antenna.radiowaves.left.and.right.slash",
                title: "Discovery is unavailable",
                text: "Bonjour is not working on this network right now. Try again, or add the device by address.",
                primary: ("Try again", { localDevices.restartDiscovery() }),
                secondary: ("Add by address", addByAddress)
            )
        case .searching, .stopped:
            if displayed.isEmpty {
                if localDevices.discoverySearchSettled {
                    DiscoveryNotice(
                        symbol: "magnifyingglass",
                        title: "No devices found",
                        text: "Make sure the device is on this network with LAN control on. Devices set to Relay only do not advertise.",
                        primary: ("Add by address", addByAddress),
                        secondary: nil
                    )
                } else {
                    SearchingRow()
                }
            }
        }
    }

    // MARK: - Row content

    private func savedMatch(for device: DiscoveredLocalDevice) -> LocalDeviceProfile? {
        guard let address = device.endpoint?.address else { return nil }
        return localDevices.devices.first { $0.address == address }
    }

    private func status(for device: DiscoveredLocalDevice, saved: LocalDeviceProfile?) -> DeviceRow.Status {
        if checking == device.id, localDevices.selectingNearby {
            return .init(text: "Checking", tone: .neutral, busy: true)
        }
        if !device.isPresent { return .init(text: "Unavailable", tone: .attention) }
        if let error = device.error {
            switch error {
            case .unsupportedVersion: return .init(text: "Incompatible", tone: .danger)
            case .unsupportedNetwork: return .init(text: "Unsupported", tone: .attention)
            case .malformedRecord, .timedOut, .busy, .unavailable: return .init(text: "Unavailable", tone: .attention)
            }
        }
        if device.endpoint == nil { return .init(text: "Resolving", tone: .neutral, busy: true) }
        if saved != nil { return .init(text: "Saved", tone: .neutral) }
        return .init(text: "Discovered", tone: .neutral)
    }

    private func detail(for device: DiscoveredLocalDevice, saved: LocalDeviceProfile?) -> String {
        if !device.isPresent { return "No longer advertised on this network" }
        if let error = device.error {
            switch error {
            case .unsupportedVersion: return "Protocol mismatch"
            case .unsupportedNetwork: return "No private IPv4"
            case .timedOut: return "No answer"
            case .malformedRecord: return "Invalid record"
            case .busy, .unavailable: return "Not resolved"
            }
        }
        guard let endpoint = device.endpoint else { return "Resolving address…" }
        let address = endpoint.address.displayAddress
        if let saved, saved.name != device.id.name { return "\(address) · saved as \(saved.name)" }
        return address
    }

    private var subtitle: String? {
        guard localDevices.discoveryEnabled else { return nil }
        switch localDevices.discoveryState {
        case .permissionDenied: return "Permission needed"
        case .unavailable: return "Unavailable"
        case .searching, .stopped:
            let count = displayed.filter(\.isPresent).count
            if count == 0, !displayed.isEmpty { return "Recently seen" }
            if count == 0 { return localDevices.discoverySearchSettled ? "None found" : "Searching" }
            return count == 1 ? "1 found" : "\(count) found"
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

// MARK: - State rows

/// Placeholder row while the first results are still arriving.
struct SearchingRow: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(ControllerPalette.canvasDeep)
                ProgressView().tint(ControllerPalette.signal)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Looking for rctl devices")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ControllerPalette.ink)
                Text("On the network this phone is connected to")
                    .font(.footnote)
                    .foregroundStyle(ControllerPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Inline notice for denied permission, unavailable discovery, or an empty
/// result, with the manual fallback always one tap away.
struct DiscoveryNotice: View {
    let symbol: String
    let title: String
    let text: String
    let primary: (String, () -> Void)?
    let secondary: (String, () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(ControllerPalette.canvasDeep)
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(ControllerPalette.inkDim)
                }
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(ControllerPalette.ink)
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(ControllerPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if primary != nil || secondary != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { actions }
                    VStack(alignment: .leading, spacing: 8) { actions }
                }
                .padding(.leading, 56)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var actions: some View {
        if let primary {
            Button(primary.0, action: primary.1)
                .buttonStyle(NoticeButtonStyle(prominent: true))
        }
        if let secondary {
            Button(secondary.0, action: secondary.1)
                .buttonStyle(NoticeButtonStyle(prominent: false))
        }
    }
}

private struct NoticeButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.semibold))
            .foregroundStyle(prominent ? ControllerPalette.elevated : ControllerPalette.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(
                (prominent ? ControllerPalette.ink : ControllerPalette.elevated).opacity(configuration.isPressed ? 0.75 : 1),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(prominent ? Color.clear : ControllerPalette.lineStrong, lineWidth: 1)
            }
            .animation(ControllerMotion.immediate, value: configuration.isPressed)
    }
}

// MARK: - Selection sheet

/// Presented after a discovered device answered its capabilities preflight.
/// The wording keeps the trust boundary explicit: reachable, not verified.
struct NearbyDeviceSheet: View {
    let profile: LocalDeviceProfile
    let savedDevices: [LocalDeviceProfile]
    let open: () -> Void
    let save: () -> Void
    let replace: (LocalDeviceProfile) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ControllerPalette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(ControllerPalette.signalSoft)
                            Image(systemName: "ipad.and.iphone")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(ControllerPalette.signal)
                        }
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(ControllerPalette.ink)
                                .lineLimit(2)
                            Text(profile.address.displayAddress)
                                .font(.footnote.monospaced())
                                .foregroundStyle(ControllerPalette.muted)
                                .textSelection(.enabled)
                            StatusPill(text: "Answered just now", tone: .healthy)
                                .padding(.top, 2)
                        }
                        Spacer(minLength: 0)
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(ControllerPalette.inkDim)
                                .frame(width: 32, height: 32)
                                .background(ControllerPalette.elevated, in: Circle())
                                .overlay { Circle().strokeBorder(ControllerPalette.line, lineWidth: 1) }
                        }
                        .accessibilityLabel("Close")
                    }
                    .accessibilityElement(children: .contain)

                    Callout(
                        text: "Found on this network by name. Discovery does not verify which device this is; connect only on a network you trust. Sessions start in View mode.",
                        symbol: "info.circle",
                        tone: .neutral
                    )

                    VStack(spacing: 10) {
                        Button(action: open) {
                            Label("Open in View mode", systemImage: "eye")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("nearby-open")
                        Button(action: save) {
                            Label("Save device", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("nearby-save")
                        if !savedDevices.isEmpty {
                            Menu {
                                ForEach(savedDevices) { saved in
                                    Button {
                                        replace(saved)
                                    } label: {
                                        Text("\(saved.name) · \(saved.address.displayAddress)")
                                    }
                                }
                            } label: {
                                Text("Use this address for a saved device…")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(ControllerPalette.signal)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .menuOrder(.fixed)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .pageColumn(maxWidth: 520)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

#if DEBUG
/// Static gallery of the discovery building blocks for design review in the
/// simulator (`--rctl-route=gallery`). Not compiled into Release.
struct DiscoveryDesignGallery: View {
    /// 0: discovery rows and notices; 1: session components and the sheet.
    var part = 0

    var body: some View {
        ZStack {
            AmbientBackground(particleOpacity: 0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if part == 0 { discoveryBlocks } else { sessionBlocks }
                }
                .pageColumn()
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var discoveryBlocks: some View {
                    SectionLabel(text: "Rows")
                    DeviceGroup {
                        DeviceRow(name: "Kitchen iPad", detail: "Resolving address…", status: .init(text: "Resolving", tone: .neutral, busy: true), enabled: false) {}
                        RowSeparator()
                        DeviceRow(name: "Kitchen iPad", detail: "192.168.1.20:8080", status: .init(text: "Discovered", tone: .neutral), enabled: true) {}
                        RowSeparator()
                        DeviceRow(name: "Studio iPad Pro", detail: "10.0.0.7:8080 · saved as Studio", status: .init(text: "Saved", tone: .neutral), enabled: true) {}
                        RowSeparator()
                        DeviceRow(name: "Kitchen iPad", detail: "192.168.1.20:8080", status: .init(text: "Checking", tone: .neutral, busy: true), enabled: false) {}
                        RowSeparator()
                        DeviceRow(name: "Old iPad", detail: "Protocol mismatch", status: .init(text: "Incompatible", tone: .danger), enabled: false) {}
                        RowSeparator()
                        DeviceRow(name: "Guest iPad", detail: "No private IPv4", status: .init(text: "Unsupported", tone: .attention), enabled: false) {}
                    }
                    SectionLabel(text: "Searching")
                    DeviceGroup { SearchingRow() }
                    SectionLabel(text: "Permission")
                    DeviceGroup {
                        DiscoveryNotice(
                            symbol: "hand.raised",
                            title: "Local Network access is off",
                            text: "Allow it in Settings to find devices. Adding by address needs the same permission.",
                            primary: ("Open Settings", {}),
                            secondary: ("Add by address", {})
                        )
                    }
                    SectionLabel(text: "Unavailable")
                    DeviceGroup {
                        DiscoveryNotice(
                            symbol: "antenna.radiowaves.left.and.right.slash",
                            title: "Discovery is unavailable",
                            text: "Bonjour is not working on this network right now. Try again, or add the device by address.",
                            primary: ("Try again", {}),
                            secondary: ("Add by address", {})
                        )
                    }
                    SectionLabel(text: "Empty")
                    DeviceGroup {
                        DiscoveryNotice(
                            symbol: "magnifyingglass",
                            title: "No devices found",
                            text: "Make sure the device is on this network with LAN control on. Devices set to Relay only do not advertise.",
                            primary: ("Add by address", {}),
                            secondary: nil
                        )
                    }
    }

    @ViewBuilder
    private var sessionBlocks: some View {
                    SectionLabel(text: "Session header")
                    if let lan = try? LocalDeviceAddress("192.168.1.20:8080") {
                        VStack(spacing: 8) {
                            RemoteSessionHeader(
                                deviceName: "Living room iPad", accessPath: .lan(lan),
                                connectionLabel: "Live screen", connectionColor: RemotePalette.online,
                                modeLabel: "VIEW ONLY", modeColor: RemotePalette.secondaryText, dismiss: {}
                            )
                            RemoteSessionHeader(
                                deviceName: "Studio iPad Pro", accessPath: .relay(origin: "https://relay.example"),
                                connectionLabel: "Reconnecting", connectionColor: RemotePalette.signal,
                                modeLabel: "CONTROL", modeColor: RemotePalette.signal, dismiss: {}
                            )
                        }
                        .background(RemotePalette.canvas)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .environment(\.colorScheme, .dark)
                        SectionLabel(text: "Session controls")
                        VStack(spacing: 14) {
                            SessionConnectionBlock(accessPath: .lan(lan))
                            SessionConnectionBlock(accessPath: .relay(origin: "https://relay.example"))
                        }
                        .padding(16)
                        .background(RemotePalette.canvas)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .environment(\.colorScheme, .dark)
                    }
                    SectionLabel(text: "Selection sheet")
                    if let found = try? LocalDeviceAddress("192.168.1.30:8080"),
                       let kept = try? LocalDeviceAddress("192.168.1.2:8080") {
                        NearbyDeviceSheet(
                            profile: LocalDeviceProfile(id: UUID(), name: "Kitchen iPad", address: found),
                            savedDevices: [LocalDeviceProfile(id: UUID(), name: "Studio", address: kept)],
                            open: {}, save: {}, replace: { _ in }
                        )
                        .frame(height: 430)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(ControllerPalette.line, lineWidth: 1) }
                    }
    }
}
#endif
