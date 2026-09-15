import Foundation
import RctlClient
import RctlRealtime

/// Everything the Devices screen displays, captured from the live models (or
/// demo fixtures) in one value. `DevicesViewState` is a pure function of it,
/// so every status, detail and section decision is unit-testable without UIKit.
struct DevicesSnapshot: Equatable {
    /// A Bonjour result, reduced to what the screen reads. `DiscoveredLocalDevice`
    /// has no public initializer, so fixtures and tests build this instead.
    struct NearbyDevice: Equatable {
        let id: LocalServiceIdentity
        var endpointAddress: LocalDeviceAddress?
        var error: LocalDiscoveryError?
        var isPresent: Bool
        var canResolve: Bool

        init(id: LocalServiceIdentity, endpointAddress: LocalDeviceAddress? = nil, error: LocalDiscoveryError? = nil, isPresent: Bool = true, canResolve: Bool? = nil) {
            self.id = id
            self.endpointAddress = endpointAddress
            self.error = error
            self.isPresent = isPresent
            // Mirrors `DiscoveredLocalDevice.canResolve` for synthetic values.
            self.canResolve = canResolve ?? {
                switch error {
                case .malformedRecord, .unsupportedVersion, .unsupportedNetwork: false
                case nil, .unavailable, .timedOut, .busy: true
                }
            }()
        }

        init(_ device: DiscoveredLocalDevice) {
            self.init(id: device.id, endpointAddress: device.endpoint?.address, error: device.error,
                      isPresent: device.isPresent, canResolve: device.canResolve)
        }
    }

    struct RelayDevice: Equatable {
        let id: String
        let name: String
        var online: Bool
        var compatible: Bool
        var compatibilityError: String?
        var daemonVersion: String?
        var protocolMajor: Int?
        var protocolMinor: Int?
        var supportsNativeControllerSessions: Bool

        init(id: String, name: String, online: Bool, compatible: Bool = true, compatibilityError: String? = nil,
             daemonVersion: String? = nil, protocolMajor: Int? = nil, protocolMinor: Int? = nil,
             supportsNativeControllerSessions: Bool = true) {
            self.id = id
            self.name = name
            self.online = online
            self.compatible = compatible
            self.compatibilityError = compatibilityError
            self.daemonVersion = daemonVersion
            self.protocolMajor = protocolMajor
            self.protocolMinor = protocolMinor
            self.supportsNativeControllerSessions = supportsNativeControllerSessions
        }

        init(_ device: ControllerDevice) {
            self.init(id: device.id, name: device.name, online: device.online, compatible: device.compatible,
                      compatibilityError: device.compatibilityError, daemonVersion: device.daemonVersion,
                      protocolMajor: device.protocolMajor, protocolMinor: device.protocolMinor,
                      supportsNativeControllerSessions: device.supportsNativeControllerSessions)
        }
    }

    struct Relay: Equatable {
        var selected: ControllerProfile
        var saved: [ControllerProfile]
        var devices: [RelayDevice]
    }

    var localDevices: [LocalDeviceProfile] = []
    var reachability: [UUID: LocalDeviceReachability] = [:]
    var discoveryEnabled = false
    var discoveryState: LocalBrowserState = .stopped
    var discoverySearchSettled = false
    var nearby: [NearbyDevice] = []
    var selectingNearby = false
    /// The nearby row the user chose; it reads "Checking" while the model prepares it.
    var checkingNearby: LocalServiceIdentity?
    var relay: Relay?
    var isBusy = false
}

enum DevicesTone: Equatable, Sendable {
    case neutral, success, attention, danger
}

/// Every status a device row can show, whatever its source (saved, nearby or
/// relay). `DevicesStatus(_:)` is the single map from meaning to look.
enum DevicesStatusKind: Equatable, CaseIterable, Sendable {
    case online
    case checking
    case resolving
    case saved
    case discovered
    case offline
    case unavailable
    case unsupported
    case needsUpdate
    case incompatible
}

struct DevicesStatus: Equatable {
    var text: String
    var tone: DevicesTone
    var busy = false
}

extension DevicesStatus {
    /// One look per meaning, used by every section: only a working device is
    /// success; in-progress states are neutral and busy; known-but-idle states
    /// (saved, discovered, offline) are neutral, because an offline device is a
    /// normal condition, not a fault; states that need the user's action are
    /// attention; only a protocol mismatch is danger.
    init(_ kind: DevicesStatusKind) {
        switch kind {
        case .online: self.init(text: "Online", tone: .success)
        case .checking: self.init(text: "Checking", tone: .neutral, busy: true)
        case .resolving: self.init(text: "Resolving", tone: .neutral, busy: true)
        case .saved: self.init(text: "Saved", tone: .neutral)
        case .discovered: self.init(text: "Discovered", tone: .neutral)
        case .offline: self.init(text: "Offline", tone: .neutral)
        case .unavailable: self.init(text: "Unavailable", tone: .attention)
        case .unsupported: self.init(text: "Unsupported", tone: .attention)
        case .needsUpdate: self.init(text: "Needs update", tone: .attention)
        case .incompatible: self.init(text: "Incompatible", tone: .danger)
        }
    }
}

/// One device row. `isEnabled` only changes the look and the VoiceOver hint:
/// unavailable rows still respond, explaining why they cannot open.
struct DevicesRowState: Equatable {
    enum Kind: Equatable {
        case local(UUID)
        case nearby(LocalServiceIdentity)
        case relay(String)
    }

    let kind: Kind
    var title: String
    var detail: String
    /// Secondary metadata shown after the detail ("rctld 0.3.0", "saved as …").
    /// Rendered as " · accessory"; it is truncated or dropped before the detail.
    var detailAccessory: String? = nil
    var detailIsMonospaced: Bool
    var status: DevicesStatus
    var isEnabled: Bool
    /// Nearby only: the long-press menu can put this address on a saved device.
    var offersAddressReplacement = false

    var id: String {
        switch kind {
        case let .local(id): "local:\(id.uuidString)"
        case let .nearby(identity): "nearby:\(identity.name)"
        case let .relay(id): "relay:\(id)"
        }
    }

    var accessibilityHint: String {
        isEnabled ? "Opens remote control" : "Shows why this device is unavailable"
    }
}

struct DevicesViewState: Equatable {
    enum Layout: Equatable {
        /// No saved local devices and no relay: discovery first, then the other ways in.
        case firstRun
        case populated
    }

    struct Summary: Equatable {
        var text: String
        var online: Int
        var total: Int
        var showsOnlineIndicator: Bool { online > 0 }
    }

    struct LocalSection: Equatable {
        var subtitle: String?
        var rows: [DevicesRowState]
    }

    /// Trailing state row inside the Nearby group.
    enum NearbyNotice: Hashable, CaseIterable {
        case permissionDenied
        case unavailable
        case searching
        case empty
    }

    struct NearbySection: Equatable {
        var isEnabled: Bool
        var subtitle: String?
        var showsSpinner: Bool
        var canSearchAgain: Bool
        var rows: [DevicesRowState]
        var notice: NearbyNotice?
    }

    struct RelayChoice: Equatable {
        var relayID: String
        var title: String
        var isSelected: Bool
    }

    enum RelayPlaceholder: Equatable {
        case loading
        case empty
    }

    struct PairedRelay: Equatable {
        var subtitle: String?
        var choices: [RelayChoice]
        var rows: [DevicesRowState]
        var placeholder: RelayPlaceholder?
        var footer: String
        var isBusy: Bool
    }

    enum RelaySection: Equatable {
        /// Local devices exist but no relay is paired: one invitation row.
        case unpaired
        case paired(PairedRelay)
    }

    /// Parts of the screen whose content is replaced by a different state
    /// (not updated row by row) between two renders. The screen fades the old
    /// state out before the new one fades in, so the two never show at once.
    struct Switches: OptionSet, Hashable {
        let rawValue: Int
        /// First run ↔ populated composition.
        static let layout = Switches(rawValue: 1 << 0)
        /// Discovery turned on/off, or the Nearby notice appears, changes or goes.
        static let nearby = Switches(rawValue: 1 << 1)
        /// Pairing invitation, loading skeleton, empty notice and device rows replace each other.
        static let relay = Switches(rawValue: 1 << 2)
    }

    var layout: Layout
    var summary: Summary
    /// The top bar refresh button exists only when a relay profile does.
    var showsRefresh: Bool
    var isBusy: Bool
    var local: LocalSection
    var nearby: NearbySection
    var relay: RelaySection

    init(_ snapshot: DevicesSnapshot) {
        layout = snapshot.localDevices.isEmpty && snapshot.relay == nil ? .firstRun : .populated
        summary = Self.summary(snapshot)
        showsRefresh = snapshot.relay != nil
        isBusy = snapshot.isBusy
        local = LocalSection(
            subtitle: snapshot.localDevices.isEmpty ? nil : "\(snapshot.localDevices.count) saved",
            rows: snapshot.localDevices.map { Self.localRow($0, in: snapshot) }
        )
        nearby = Self.nearbySection(snapshot)
        relay = snapshot.relay.map { .paired(Self.pairedRelay($0, isBusy: snapshot.isBusy)) } ?? .unpaired
    }

    // MARK: - Switches

    static func switches(from old: DevicesViewState, to new: DevicesViewState) -> Switches {
        var switches: Switches = []
        if old.layout != new.layout { switches.insert(.layout) }
        if old.nearby.isEnabled != new.nearby.isEnabled || old.nearby.notice != new.nearby.notice {
            switches.insert(.nearby)
        }
        switch (old.relay, new.relay) {
        case (.unpaired, .unpaired): break
        case let (.paired(before), .paired(after)) where before.placeholder == after.placeholder: break
        default: switches.insert(.relay)
        }
        return switches
    }

    // MARK: - Summary

    static func summary(_ snapshot: DevicesSnapshot) -> Summary {
        let relayDevices = snapshot.relay?.devices ?? []
        let total = snapshot.localDevices.count + relayDevices.count
        guard total > 0 else { return Summary(text: "No devices yet.", online: 0, total: 0) }
        let online = relayDevices.filter(\.online).count + snapshot.localDevices.filter { device in
            if case .reachable = snapshot.reachability[device.id] ?? .unknown { return true }
            return isAdvertisedNearby(device, in: snapshot)
        }.count
        let devices = total == 1 ? "1 device" : "\(total) devices"
        return Summary(text: "\(online) online · \(devices)", online: online, total: total)
    }

    // MARK: - Local network

    /// Exact-endpoint match between a saved address and a resolved discovery
    /// result. A hint for the status only; it proves nothing about which
    /// device answered and never edits the saved entry.
    static func isAdvertisedNearby(_ device: LocalDeviceProfile, in snapshot: DevicesSnapshot) -> Bool {
        snapshot.discoveryEnabled && snapshot.nearby.contains { $0.endpointAddress == device.address }
    }

    static func localRow(_ device: LocalDeviceProfile, in snapshot: DevicesSnapshot) -> DevicesRowState {
        DevicesRowState(
            kind: .local(device.id),
            title: device.name,
            detail: device.address.displayAddress,
            detailAccessory: localDetailAccessory(for: device, in: snapshot),
            detailIsMonospaced: true,
            status: DevicesStatus(localStatus(for: device, in: snapshot)),
            isEnabled: true
        )
    }

    static func localStatus(for device: LocalDeviceProfile, in snapshot: DevicesSnapshot) -> DevicesStatusKind {
        if isAdvertisedNearby(device, in: snapshot) { return .discovered }
        switch snapshot.reachability[device.id] ?? .unknown {
        case .unknown: return .saved
        case .checking: return .checking
        case .reachable: return .online
        case .unreachable: return .offline
        }
    }

    /// Metadata after the address; the row drops it before shortening the address.
    static func localDetailAccessory(for device: LocalDeviceProfile, in snapshot: DevicesSnapshot) -> String? {
        if case let .reachable(version) = snapshot.reachability[device.id] ?? .unknown, let version {
            return "rctld \(version)"
        }
        if isAdvertisedNearby(device, in: snapshot) { return "advertised" }
        return nil
    }

    // MARK: - Nearby

    static func nearbySection(_ snapshot: DevicesSnapshot) -> NearbySection {
        let enabled = snapshot.discoveryEnabled
        return NearbySection(
            isEnabled: enabled,
            subtitle: nearbySubtitle(snapshot),
            // The browser stays `.searching` for as long as discovery is on; spin
            // only during the initial search window (it restarts on Search again).
            showsSpinner: enabled && snapshot.discoveryState == .searching && !snapshot.selectingNearby
                && !snapshot.discoverySearchSettled,
            canSearchAgain: enabled && !snapshot.selectingNearby && snapshot.discoveryState != .permissionDenied,
            rows: enabled ? snapshot.nearby.map { nearbyRow($0, in: snapshot) } : [],
            notice: enabled ? nearbyNotice(snapshot) : nil
        )
    }

    static func nearbySubtitle(_ snapshot: DevicesSnapshot) -> String? {
        guard snapshot.discoveryEnabled else { return nil }
        switch snapshot.discoveryState {
        case .permissionDenied: return "Permission needed"
        case .unavailable: return "Unavailable"
        case .searching, .stopped:
            let count = snapshot.nearby.filter(\.isPresent).count
            if count == 0, !snapshot.nearby.isEmpty { return "Recently seen" }
            if count == 0 { return snapshot.discoverySearchSettled ? "None found" : "Searching" }
            return count == 1 ? "1 found" : "\(count) found"
        }
    }

    static func nearbyNotice(_ snapshot: DevicesSnapshot) -> NearbyNotice? {
        switch snapshot.discoveryState {
        case .permissionDenied: return .permissionDenied
        case .unavailable: return .unavailable
        case .searching, .stopped:
            guard snapshot.nearby.isEmpty else { return nil }
            return snapshot.discoverySearchSettled ? .empty : .searching
        }
    }

    static func savedMatch(for device: DevicesSnapshot.NearbyDevice, in snapshot: DevicesSnapshot) -> LocalDeviceProfile? {
        guard let address = device.endpointAddress else { return nil }
        return snapshot.localDevices.first { $0.address == address }
    }

    static func nearbyRow(_ device: DevicesSnapshot.NearbyDevice, in snapshot: DevicesSnapshot) -> DevicesRowState {
        let saved = savedMatch(for: device, in: snapshot)
        return DevicesRowState(
            kind: .nearby(device.id),
            title: device.id.name,
            detail: nearbyDetail(for: device),
            detailAccessory: nearbyDetailAccessory(for: device, saved: saved),
            detailIsMonospaced: device.isPresent && device.error == nil && device.endpointAddress != nil,
            status: DevicesStatus(nearbyStatus(for: device, saved: saved, in: snapshot)),
            isEnabled: device.canResolve && !snapshot.selectingNearby,
            offersAddressReplacement: device.isPresent && device.endpointAddress != nil && !snapshot.localDevices.isEmpty
        )
    }

    static func nearbyStatus(for device: DevicesSnapshot.NearbyDevice, saved: LocalDeviceProfile?, in snapshot: DevicesSnapshot) -> DevicesStatusKind {
        if snapshot.checkingNearby == device.id, snapshot.selectingNearby { return .checking }
        if !device.isPresent { return .unavailable }
        if let error = device.error {
            switch error {
            case .unsupportedVersion: return .incompatible
            case .unsupportedNetwork: return .unsupported
            case .malformedRecord, .timedOut, .busy, .unavailable: return .unavailable
            }
        }
        if device.endpointAddress == nil { return .resolving }
        if saved != nil { return .saved }
        return .discovered
    }

    static func nearbyDetail(for device: DevicesSnapshot.NearbyDevice) -> String {
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
        return device.endpointAddress?.displayAddress ?? "Resolving address…"
    }

    /// Names the saved entry at the same address when it is saved under another name.
    static func nearbyDetailAccessory(for device: DevicesSnapshot.NearbyDevice, saved: LocalDeviceProfile?) -> String? {
        guard device.isPresent, device.error == nil, device.endpointAddress != nil,
              let saved, saved.name != device.id.name else { return nil }
        return "saved as \(saved.name)"
    }

    // MARK: - Relay

    static func pairedRelay(_ relay: DevicesSnapshot.Relay, isBusy: Bool) -> PairedRelay {
        let scopes = relay.selected.controller.scopes.count
        return PairedRelay(
            subtitle: host(of: relay.selected.origin),
            choices: relay.saved.map {
                RelayChoice(relayID: $0.relayID, title: host(of: $0.origin) ?? $0.origin, isSelected: $0.relayID == relay.selected.relayID)
            },
            rows: relay.devices.map(relayRow),
            placeholder: relay.devices.isEmpty ? (isBusy ? .loading : .empty) : nil,
            footer: "Paired as \(relay.selected.controller.name) · \(scopes == 1 ? "1 permission" : "\(scopes) permissions")",
            isBusy: isBusy
        )
    }

    static func relayRow(_ device: DevicesSnapshot.RelayDevice) -> DevicesRowState {
        DevicesRowState(
            kind: .relay(device.id),
            title: device.name,
            detail: relayDetail(for: device),
            detailIsMonospaced: false,
            status: DevicesStatus(relayStatus(for: device)),
            isEnabled: isRelayDeviceAvailable(device)
        )
    }

    static func isRelayDeviceAvailable(_ device: DevicesSnapshot.RelayDevice) -> Bool {
        device.online && device.compatible && device.supportsNativeControllerSessions
    }

    static func relayStatus(for device: DevicesSnapshot.RelayDevice) -> DevicesStatusKind {
        if !device.compatible { return .incompatible }
        if !device.online { return .offline }
        if !device.supportsNativeControllerSessions { return .needsUpdate }
        return .online
    }

    static func relayDetail(for device: DevicesSnapshot.RelayDevice) -> String {
        if !device.compatible, let reason = device.compatibilityError { return reason }
        var parts: [String] = []
        if let version = device.daemonVersion { parts.append("rctld \(version)") }
        if let major = device.protocolMajor, let minor = device.protocolMinor { parts.append("protocol \(major).\(minor)") }
        return parts.isEmpty ? "Relay device" : parts.joined(separator: " · ")
    }

    static func unavailableMessage(for device: DevicesSnapshot.RelayDevice) -> String {
        if !device.compatible {
            return device.compatibilityError ?? "The device uses an incompatible protocol version."
        }
        if !device.online {
            return "\(device.name) is offline. Wait for it to reconnect to the relay, then refresh."
        }
        if let version = device.daemonVersion {
            return "Update rctld \(version) on \(device.name) before using the native controller. Browser control remains available."
        }
        return "Update rctld on \(device.name) before using the native controller. Browser control remains available."
    }

    static func host(of origin: String) -> String? {
        URLComponents(string: origin)?.host
    }
}
