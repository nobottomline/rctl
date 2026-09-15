#if DEBUG
import Foundation
import RctlClient
import RctlRealtime

/// Synthetic Devices states for screenshots and review (`--rctl-demo[=variant]`).
/// No stored data, discovery or network is touched while a fixture is shown.
enum DevicesDemoFixture: String, CaseIterable {
    /// Every row state at once: saved devices across reachability states,
    /// discovery with rows in several states, and a relay with mixed devices.
    case populated
    case firstRun = "first-run"
    case nearbyDenied = "nearby-denied"
    case nearbySearching = "nearby-searching"
    case nearbyEmpty = "nearby-empty"
    case relayLoading = "relay-loading"

    /// `--rctl-demo` selects `populated`; `--rctl-demo=<variant>` a specific state.
    @MainActor
    static var current: DevicesDemoFixture? {
        if let value = DebugLaunch.argument("rctl-demo") { return DevicesDemoFixture(rawValue: value) ?? .populated }
        return DebugLaunch.isDemo ? .populated : nil
    }

    var snapshot: DevicesSnapshot {
        switch self {
        case .populated:
            var snapshot = DevicesSnapshot()
            snapshot.localDevices = [Self.livingRoom, Self.studio, Self.kitchen, Self.garage]
            snapshot.reachability = [
                Self.livingRoom.id: .reachable(daemonVersion: "0.3.0-180"),
                Self.studio.id: .checking,
                Self.garage.id: .unreachable,
            ]
            snapshot.discoveryEnabled = true
            snapshot.discoveryState = .searching
            snapshot.nearby = [
                .init(id: Self.service("Kitchen iPad"), endpointAddress: Self.kitchen.address),
                .init(id: Self.service("Bedroom iPad"), endpointAddress: Self.address("192.168.1.51:8080")),
                .init(id: Self.service("Office iPad")),
                .init(id: Self.service("Old iPad"), error: .unsupportedVersion),
                .init(id: Self.service("Hallway iPad"), endpointAddress: Self.address("192.168.1.64:8080"), isPresent: false),
            ]
            snapshot.relay = Self.relay(devices: [
                .init(id: "dev-office", name: "Office iPad", online: true, daemonVersion: "0.3.0-180", protocolMajor: 1, protocolMinor: 4),
                .init(id: "dev-travel", name: "Travel iPad", online: false, daemonVersion: "0.3.0-176", protocolMajor: 1, protocolMinor: 4),
                .init(id: "dev-shop", name: "Shop iPad", online: true, daemonVersion: "0.2.9", protocolMajor: 1, protocolMinor: 2,
                      supportsNativeControllerSessions: false),
                .init(id: "dev-legacy", name: "Legacy iPad", online: true, compatible: false,
                      compatibilityError: "Protocol 0.9 is no longer supported", supportsNativeControllerSessions: false),
            ])
            return snapshot
        case .firstRun:
            return DevicesSnapshot()
        case .nearbyDenied:
            var snapshot = DevicesSnapshot()
            snapshot.localDevices = [Self.livingRoom]
            snapshot.reachability = [Self.livingRoom.id: .unknown]
            snapshot.discoveryEnabled = true
            snapshot.discoveryState = .permissionDenied
            return snapshot
        case .nearbySearching, .nearbyEmpty:
            var snapshot = DevicesSnapshot()
            snapshot.discoveryEnabled = true
            snapshot.discoveryState = .searching
            snapshot.discoverySearchSettled = self == .nearbyEmpty
            return snapshot
        case .relayLoading:
            var snapshot = DevicesSnapshot()
            snapshot.localDevices = [Self.livingRoom, Self.studio]
            snapshot.reachability = [Self.livingRoom.id: .reachable(daemonVersion: "0.3.0-180"), Self.studio.id: .unreachable]
            snapshot.relay = Self.relay(devices: [])
            snapshot.isBusy = true
            return snapshot
        }
    }

    // MARK: - Values

    private static let livingRoom = LocalDeviceProfile(id: uuid(1), name: "Living room iPad", address: address("192.168.1.20:8080"))
    private static let studio = LocalDeviceProfile(id: uuid(2), name: "Studio iPad Pro", address: address("192.168.1.42:8080"))
    private static let kitchen = LocalDeviceProfile(id: uuid(3), name: "Kitchen iPad", address: address("192.168.1.30:8080"))
    private static let garage = LocalDeviceProfile(id: uuid(4), name: "Garage iPad mini", address: address("10.0.0.7:8080"))

    private static func relay(devices: [DevicesSnapshot.RelayDevice]) -> DevicesSnapshot.Relay {
        let controller = PairedController(id: "ctl_demo", name: "Demo iPhone", platform: "ios",
                                          scopes: [.screenView, .deviceControl, .camera])
        let selected = ControllerProfile(origin: "https://relay.example.net", relayID: "relay-demo-primary", controller: controller)
        let other = ControllerProfile(origin: "https://home.example.org", relayID: "relay-demo-home", controller: controller)
        return DevicesSnapshot.Relay(selected: selected, saved: [selected, other], devices: devices)
    }

    private static func address(_ value: String) -> LocalDeviceAddress {
        // Fixture literals are valid private addresses.
        try! LocalDeviceAddress(value) // swiftlint:disable:this force_try
    }

    private static func service(_ name: String) -> LocalServiceIdentity {
        try! LocalServiceIdentity(name: name, type: "_rctl._tcp", domain: "local.") // swiftlint:disable:this force_try
    }

    private static func uuid(_ index: UInt8) -> UUID {
        UUID(uuid: (0xD3, 0x7C, 0x00, 0x00, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, index))
    }
}
#endif
