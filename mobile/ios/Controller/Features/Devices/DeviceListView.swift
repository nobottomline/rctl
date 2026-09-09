import RctlClient
import SwiftUI

/// Navigation routes owned by the Devices screen. Every secondary screen is a
/// push so the user can always return with the system back gesture.
enum DevicesRoute: Hashable {
    case pairRelay
    case scanPairingCode
    case localDevice(LocalDeviceProfile?)
    case localControl(LocalDeviceProfile)
    case relayControl(deviceID: String)
}

struct DeviceListView: View {
    @ObservedObject var model: ControllerAppModel
    @ObservedObject var localDevices: LocalDevicesModel
    @State private var path: [DevicesRoute] = []
    @State private var resetConfirmation = false
    @State private var removing: LocalDeviceProfile?
    @State private var unavailableReason: String?
    @State private var homeVisible = true

    var body: some View {
        NavigationStack(path: $path) {
            home
                .navigationDestination(for: DevicesRoute.self) { route in
                    destination(for: route)
                }
        }
        // The stack root owns the presentation style: parchment screens are
        // light, while the camera and the media stage are dark. A child's own
        // preferredColorScheme cannot override an ancestor's, so decide here.
        .preferredColorScheme(topRouteIsDark ? .dark : .light)
        .tint(topRouteIsDark ? nil : ControllerPalette.ink)
        .onChange(of: model.profile) { profile in
            // Pairing finished somewhere in the flow: return to the device list.
            if profile != nil, path.contains(where: { $0 == .pairRelay || $0 == .scanPairingCode }) {
                path.removeAll()
            }
        }
    }

    // MARK: - Home

    private var home: some View {
        ZStack {
            AmbientBackground(paused: !homeVisible)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    titleBlock
                    if showsHero {
                        DevicesHero(
                            pairRelay: { path.append(.pairRelay) },
                            addLocal: { path.append(.localDevice(nil)) }
                        )
                        ConnectionModesStrip()
                    } else {
                        localSection
                        relaySection
                    }
                    footer
                }
                .pageColumn()
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 44)
            }
            .refreshable { await refresh() }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            homeVisible = true
            if let route = Self.debugLaunchRoute, path.isEmpty { path = route }
        }
        .onDisappear { homeVisible = false }
        .task(id: localDevices.devices) {
            await localDevices.probeReachability()
        }
        .confirmationDialog(
            "Remove this controller from this device?",
            isPresented: $resetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove relay profile", role: .destructive) { model.resetProfile() }
        } message: {
            Text("This does not revoke the controller in relay admin and does not remove saved local devices.")
        }
        .confirmationDialog(
            "Remove saved local device?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let removing { localDevices.remove(removing) }
                removing = nil
            }
        } message: {
            Text("Only the saved address is removed. The iPad is not changed.")
        }
        .alert(
            "Device unavailable",
            isPresented: Binding(get: { unavailableReason != nil }, set: { if !$0 { unavailableReason = nil } })
        ) {
            Button("OK") { unavailableReason = nil }
        } message: {
            Text(unavailableReason ?? "")
        }
        .alert(
            "Local devices",
            isPresented: Binding(get: { localDevices.errorMessage != nil }, set: { if !$0 { localDevices.errorMessage = nil } })
        ) {
            Button("OK") { localDevices.errorMessage = nil }
        } message: {
            Text(localDevices.errorMessage ?? "")
        }
    }

    private var showsHero: Bool {
        localDevices.devices.isEmpty && model.profile == nil
    }

    private var topRouteIsDark: Bool {
        switch path.last {
        case .scanPairingCode, .localControl, .relayControl: true
        case .pairRelay, .localDevice, nil: false
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BrandMark(size: 36)
            Text("rctl")
                .font(.title3.weight(.bold))
                .tracking(-0.4)
                .foregroundStyle(ControllerPalette.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if model.profile != nil {
                Button {
                    ControllerHaptics.tap()
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(model.isBusy ? 360 : 0))
                        .animation(model.isBusy ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: model.isBusy)
                }
                .buttonStyle(HeaderIconButtonStyle())
                .disabled(model.isBusy)
                .accessibilityLabel("Refresh devices")
            }
            Menu {
                Button {
                    path.append(.pairRelay)
                } label: {
                    Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                }
                .disabled(model.profile != nil)
                Button {
                    path.append(.localDevice(nil))
                } label: {
                    Label("Add local device", systemImage: "wifi")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ControllerPalette.elevated)
                    .frame(width: 42, height: 42)
                    .background(ControllerPalette.ink, in: Circle())
                    .shadow(color: ControllerPalette.ink.opacity(0.22), radius: 12, x: 0, y: 6)
            }
            .menuOrder(.fixed)
            .accessibilityLabel("Add device")
            .accessibilityIdentifier("add-device-menu")
        }
        .padding(.top, 4)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Devices")
                .font(.system(size: 38, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(ControllerPalette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(ControllerPalette.muted)
        }
    }

    private var summary: String {
        let total = localDevices.devices.count + model.devices.count
        guard total > 0 else { return "Nothing added yet. Start with the network you are on." }
        let online = model.devices.filter(\.online).count + localDevices.devices.filter { device in
            if case .reachable = localDevices.reachability(of: device) { return true }
            return false
        }.count
        let devices = total == 1 ? "1 device" : "\(total) devices"
        return "\(online) online · \(devices)"
    }

    // MARK: - Local network

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Local network",
                subtitle: localDevices.devices.isEmpty ? nil : "\(localDevices.devices.count) saved"
            )
            DeviceGroup {
                ForEach(localDevices.devices) { device in
                    let status = localStatus(for: device)
                    DeviceRow(
                        name: device.name,
                        detail: localDetail(for: device),
                        status: status,
                        enabled: true
                    ) {
                        ControllerHaptics.tap()
                        path.append(.localControl(device))
                    }
                    .contextMenu {
                        Button {
                            path.append(.localDevice(device))
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            removing = device
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    RowSeparator()
                }
                AddRow(
                    title: "Add local device",
                    subtitle: "Private IP address, optional port",
                    systemImage: "wifi"
                ) {
                    path.append(.localDevice(nil))
                }
                .accessibilityIdentifier("add-local-device")
            }
        }
    }

    private func localStatus(for device: LocalDeviceProfile) -> DeviceRow.Status {
        switch localDevices.reachability(of: device) {
        case .unknown: .init(text: "Saved", tone: .neutral)
        case .checking: .init(text: "Checking", tone: .neutral)
        case .reachable: .init(text: "Online", tone: .healthy)
        case .unreachable: .init(text: "Offline", tone: .attention)
        }
    }

    private func localDetail(for device: LocalDeviceProfile) -> String {
        if case let .reachable(version) = localDevices.reachability(of: device), let version {
            return "\(device.address.displayAddress) · rctld \(version)"
        }
        return device.address.displayAddress
    }

    // MARK: - Relay

    @ViewBuilder
    private var relaySection: some View {
        if let profile = model.profile {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Relay", subtitle: host(of: profile.origin)) {
                    Menu {
                        Button {
                            Task { await model.refreshDevices() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isBusy)
                        Button(role: .destructive) {
                            resetConfirmation = true
                        } label: {
                            Label("Remove relay profile", systemImage: "person.crop.circle.badge.xmark")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(ControllerPalette.inkDim)
                            .frame(width: 30, height: 24)
                            .background(ControllerPalette.elevated.opacity(0.9), in: Capsule())
                            .overlay { Capsule().strokeBorder(ControllerPalette.line, lineWidth: 1) }
                    }
                    .menuOrder(.fixed)
                    .accessibilityLabel("Relay options")
                }
                DeviceGroup {
                    if model.devices.isEmpty {
                        RelayPlaceholder(busy: model.isBusy)
                    }
                    ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                        let available = device.online && device.compatible && device.supportsNativeControllerSessions
                        DeviceRow(
                            name: device.name,
                            detail: relayDetail(for: device),
                            status: relayStatus(for: device),
                            enabled: available
                        ) {
                            if available {
                                ControllerHaptics.tap()
                                path.append(.relayControl(deviceID: device.id))
                            } else {
                                ControllerHaptics.warning()
                                unavailableReason = unavailableMessage(for: device)
                            }
                        }
                        if index < model.devices.count - 1 { RowSeparator() }
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.caption2)
                    Text("Paired as \(profile.controller.name) · \(profile.controller.scopes.count) permissions")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(ControllerPalette.faint)
                .padding(.horizontal, 8)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Relay")
                DeviceGroup {
                    AddRow(
                        title: "Pair with relay",
                        subtitle: "Scan a one-time code from relay admin to control devices from anywhere",
                        systemImage: "qrcode.viewfinder"
                    ) {
                        path.append(.pairRelay)
                    }
                    .accessibilityIdentifier("pair-relay")
                }
            }
        }
    }

    private func relayStatus(for device: ControllerDevice) -> DeviceRow.Status {
        if !device.compatible { return .init(text: "Incompatible", tone: .danger) }
        if !device.online { return .init(text: "Offline", tone: .neutral) }
        if !device.supportsNativeControllerSessions { return .init(text: "Needs update", tone: .attention) }
        return .init(text: "Online", tone: .healthy)
    }

    private func relayDetail(for device: ControllerDevice) -> String {
        if !device.compatible, let reason = device.compatibilityError { return reason }
        var parts: [String] = []
        if let version = device.daemonVersion { parts.append("rctld \(version)") }
        if let major = device.protocolMajor, let minor = device.protocolMinor { parts.append("protocol \(major).\(minor)") }
        return parts.isEmpty ? "Relay device" : parts.joined(separator: " · ")
    }

    private func unavailableMessage(for device: ControllerDevice) -> String {
        if !device.compatible {
            return device.compatibilityError ?? "The iPad uses an incompatible protocol version."
        }
        if !device.online {
            return "\(device.name) is offline. Wait for it to reconnect to the relay, then refresh."
        }
        if let version = device.daemonVersion {
            return "Update rctld \(version) on \(device.name) before using the native controller. Browser control remains available."
        }
        return "Update rctld on \(device.name) before using the native controller. Browser control remains available."
    }

    private func host(of origin: String) -> String? {
        URLComponents(string: origin)?.host
    }

    // MARK: - Footer and helpers

    private var footer: some View {
        HStack {
            Spacer()
            Text("rctl controller \(Self.version)")
                .font(.caption2)
                .foregroundStyle(ControllerPalette.faint)
            Spacer()
        }
        .padding(.top, 8)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Debug-only deep link for screenshots and manual review, for example
    /// `--rctl-route=pair`. Release builds ignore it.
    private static var debugLaunchRoute: [DevicesRoute]? {
#if DEBUG
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--rctl-route=") }) else {
            return nil
        }
        switch argument.dropFirst("--rctl-route=".count) {
        case "pair": return [.pairRelay]
        case "scan": return [.pairRelay, .scanPairingCode]
        case "local": return [.localDevice(nil)]
        default: return nil
        }
#else
        return nil
#endif
    }

    private func refresh() async {
        async let relay: Void = model.refreshDevices()
        async let local: Void = localDevices.probeReachability()
        _ = await (relay, local)
    }

    @ViewBuilder
    private func destination(for route: DevicesRoute) -> some View {
        switch route {
        case .pairRelay:
            PairingView(model: model) { path.append(.scanPairingCode) }
        case .scanPairingCode:
            PairingScannerView(model: model)
        case let .localDevice(editing):
            LocalDeviceEditor(model: localDevices, editing: editing) { device in
                path = [.localControl(device)]
            }
        case let .localControl(device):
            RemoteControlView(appModel: model, localDevice: device, localClient: localDevices.client)
        case let .relayControl(deviceID):
            if let device = model.devices.first(where: { $0.id == deviceID }) {
                RemoteControlView(appModel: model, device: device)
            } else {
                DeviceMissingView()
            }
        }
    }
}

/// Placeholder row inside the relay group while the list is empty.
private struct RelayPlaceholder: View {
    let busy: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(ControllerPalette.canvasDeep)
                if busy {
                    ProgressView().tint(ControllerPalette.signal)
                } else {
                    Image(systemName: "tray")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(ControllerPalette.faint)
                }
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(busy ? "Loading devices" : "No approved devices")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(ControllerPalette.ink)
                Text(busy ? "Talking to the relay…" : "Approve devices for this controller in relay admin, then refresh.")
                    .font(.footnote)
                    .foregroundStyle(ControllerPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}

/// Shown when a pushed relay device disappears from the refreshed list.
private struct DeviceMissingView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AmbientBackground(particleOpacity: 0.6)
            VStack(spacing: 16) {
                Image(systemName: "ipad.slash")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(ControllerPalette.faint)
                Text("Device no longer available")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ControllerPalette.ink)
                Text("It was removed from this controller's device list. Refresh and try again.")
                    .font(.subheadline)
                    .foregroundStyle(ControllerPalette.inkDim)
                    .multilineTextAlignment(.center)
                Button("Back to devices") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 8)
            }
            .glassSurface(cornerRadius: 24, padding: 24)
            .frame(maxWidth: 360)
            .padding(24)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}
