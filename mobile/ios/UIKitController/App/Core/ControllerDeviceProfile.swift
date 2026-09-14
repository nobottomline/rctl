import Foundation
import Network
import RctlClient
import RctlProtocol
import UIKit
import os

/// Builds the self-description a controller reports to its relay. Static facts
/// go to `ControllerClientProfile` (sent once per change); condition goes to
/// `ControllerTelemetry` (rides on the foreground heartbeat). Nothing here is a
/// advertising identifier. Reports are nevertheless linked to the controller ID.
enum ControllerDeviceProfile {
    /// What this build can do, as stable tokens the relay stores per controller.
    /// Keep it honest: a token here means the feature ships in this version.
    static let capabilities: [String] = [
        "relay",            // paired relay sessions
        "lan",              // direct local-network sessions
        "nearby",           // Bonjour discovery of local devices
        "webrtc.screen",    // screen video over WebRTC
        "webrtc.camera",    // camera video over WebRTC
        "control.input",    // touch / pointer / keyboard input
        "device.lock",      // lock the remote device
        "presence",         // foreground heartbeat with telemetry
        "client_profile",   // this report
    ]

    @MainActor
    static func current(bundle: Bundle = .main, device: UIDevice = .current) -> ControllerClientProfile {
        var profile = ControllerClientProfile()
        profile.protocolMajor = Int64(WireProtocolVersion.current.major)
        profile.protocolMinor = Int64(WireProtocolVersion.current.minor)
        profile.buildRevision = bundle.object(forInfoDictionaryKey: "RCTLBuildRevision") as? String
        profile.installChannel = installChannel(bundle: bundle)
        profile.capabilities = capabilities
        let identifier = hardwareIdentifier()
        profile.model = identifier
        profile.modelName = marketingName(for: identifier)
        profile.idiom = device.userInterfaceIdiom == .pad ? "pad" : "phone"
        profile.systemName = device.systemName
        profile.systemVersion = device.systemVersion
        profile.osBuild = sysctlString("kern.osversion")
        profile.appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        profile.appBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        profile.bundleID = bundle.bundleIdentifier
        profile.deviceName = device.name
        profile.locale = Locale.current.identifier
        profile.language = Locale.preferredLanguages.first
        profile.timezone = TimeZone.current.identifier
        let screen = UIScreen.main
        let size = screen.nativeBounds.size
        let scale = screen.nativeScale
        if size.width > 0, scale > 0 {
            let points = CGSize(width: size.width / scale, height: size.height / scale)
            profile.screen = "\(Int(points.width))×\(Int(points.height)) @\(Int(scale.rounded()))x"
        }
        profile.cpuCount = Int64(ProcessInfo.processInfo.activeProcessorCount)
        profile.memoryBytes = Int64(clamping: ProcessInfo.processInfo.physicalMemory)
        return profile.bounded()
    }

    /// A readable default controller name. iOS 16+ hides the user-assigned
    /// device name from apps without a special entitlement and returns a bare
    /// "iPhone"; the marketing name is more useful in the admin list and the
    /// admin can rename the controller anyway.
    @MainActor
    static func defaultControllerName(device: UIDevice = .current) -> String {
        let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic = ["iphone", "ipad", "ipod touch", "ipod"].contains(name.lowercased())
        if !generic, !name.isEmpty { return name }
        return marketingName(for: hardwareIdentifier()) ?? (name.isEmpty ? "My phone" : name)
    }

    @MainActor
    static func telemetry(network: NetworkPathObserver.Snapshot, device: UIDevice = .current) -> ControllerTelemetry {
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        var telemetry = ControllerTelemetry()
        if device.batteryLevel >= 0 {
            telemetry.batteryLevel = Int((device.batteryLevel * 100).rounded())
        }
        telemetry.batteryState = switch device.batteryState {
        case .unplugged: "unplugged"
        case .charging: "charging"
        case .full: "full"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
        telemetry.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        telemetry.thermal = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        telemetry.network = network.kind
        telemetry.networkExpensive = network.expensive
        telemetry.networkConstrained = network.constrained
        telemetry.lanIP = lanAddress()
        let available = os_proc_available_memory()
        telemetry.memoryAvailableBytes = Int64(clamping: available)
        return telemetry
    }

    /// How the app got onto the phone: debug build, TestFlight, App Store, or a
    /// signed distribution profile. Diagnostics only; nothing is gated on it.
    static func installChannel(bundle: Bundle = .main) -> String {
#if DEBUG
        return "debug"
#else
        // Receipts and provisioning files do not reliably identify sideloaded builds.
        return "unknown"
#endif
    }

    /// The phone's private IPv4 address on Wi-Fi (en0), not proof that two peers
    /// share a network. Nothing else about
    /// the network (SSID, gateway, peers) is collected.
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var fallback: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (Int32(interface.ifa_flags) & IFF_UP) != 0, (Int32(interface.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard isPrivateIPv4(value) else { continue }
            let name = String(cString: interface.ifa_name)
            if name == "en0" { return value }
            if fallback == nil, name.hasPrefix("en") { fallback = value }
        }
        return fallback
    }

    static func isPrivateIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
    }

    static func hardwareIdentifier() -> String? {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { buffer -> String in
            let bytes = buffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? nil : machine
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    /// Marketing names for identifiers the relay operator is likely to meet.
    /// Unknown identifiers fall back to the identifier itself, which the admin
    /// console shows alongside the name anyway.
    static func marketingName(for identifier: String?) -> String? {
        guard let identifier else { return nil }
        if identifier == "arm64" || identifier == "x86_64" { return "Simulator" }
        return marketingNames[identifier] ?? identifier
    }

    private static let marketingNames: [String: String] = [
        "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2nd gen)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd gen)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
        "iPad7,11": "iPad (7th gen)", "iPad7,12": "iPad (7th gen)", "iPad11,6": "iPad (8th gen)", "iPad11,7": "iPad (8th gen)",
        "iPad12,1": "iPad (9th gen)", "iPad12,2": "iPad (9th gen)", "iPad13,18": "iPad (10th gen)", "iPad13,19": "iPad (10th gen)",
        "iPad15,7": "iPad (11th gen)", "iPad15,8": "iPad (11th gen)",
        "iPad11,1": "iPad mini (5th gen)", "iPad11,2": "iPad mini (5th gen)", "iPad14,1": "iPad mini (6th gen)", "iPad14,2": "iPad mini (6th gen)",
        "iPad16,1": "iPad mini (A17 Pro)", "iPad16,2": "iPad mini (A17 Pro)",
        "iPad11,3": "iPad Air (3rd gen)", "iPad11,4": "iPad Air (3rd gen)", "iPad13,1": "iPad Air (4th gen)", "iPad13,2": "iPad Air (4th gen)",
        "iPad13,16": "iPad Air (5th gen)", "iPad13,17": "iPad Air (5th gen)",
        "iPad14,8": "iPad Air 11-inch (M2)", "iPad14,9": "iPad Air 11-inch (M2)", "iPad14,10": "iPad Air 13-inch (M2)", "iPad14,11": "iPad Air 13-inch (M2)",
        "iPad15,3": "iPad Air 11-inch (M3)", "iPad15,4": "iPad Air 11-inch (M3)", "iPad15,5": "iPad Air 13-inch (M3)", "iPad15,6": "iPad Air 13-inch (M3)",
        "iPad8,1": "iPad Pro 11-inch (1st gen)", "iPad8,2": "iPad Pro 11-inch (1st gen)", "iPad8,3": "iPad Pro 11-inch (1st gen)", "iPad8,4": "iPad Pro 11-inch (1st gen)",
        "iPad8,5": "iPad Pro 12.9-inch (3rd gen)", "iPad8,6": "iPad Pro 12.9-inch (3rd gen)", "iPad8,7": "iPad Pro 12.9-inch (3rd gen)", "iPad8,8": "iPad Pro 12.9-inch (3rd gen)",
        "iPad8,9": "iPad Pro 11-inch (2nd gen)", "iPad8,10": "iPad Pro 11-inch (2nd gen)", "iPad8,11": "iPad Pro 12.9-inch (4th gen)", "iPad8,12": "iPad Pro 12.9-inch (4th gen)",
        "iPad13,4": "iPad Pro 11-inch (3rd gen)", "iPad13,5": "iPad Pro 11-inch (3rd gen)", "iPad13,6": "iPad Pro 11-inch (3rd gen)", "iPad13,7": "iPad Pro 11-inch (3rd gen)",
        "iPad13,8": "iPad Pro 12.9-inch (5th gen)", "iPad13,9": "iPad Pro 12.9-inch (5th gen)", "iPad13,10": "iPad Pro 12.9-inch (5th gen)", "iPad13,11": "iPad Pro 12.9-inch (5th gen)",
        "iPad14,3": "iPad Pro 11-inch (4th gen)", "iPad14,4": "iPad Pro 11-inch (4th gen)", "iPad14,5": "iPad Pro 12.9-inch (6th gen)", "iPad14,6": "iPad Pro 12.9-inch (6th gen)",
        "iPad16,3": "iPad Pro 11-inch (M4)", "iPad16,4": "iPad Pro 11-inch (M4)", "iPad16,5": "iPad Pro 13-inch (M4)", "iPad16,6": "iPad Pro 13-inch (M4)",
    ]
}

/// Tracks the interface the phone currently uses so the heartbeat can say
/// whether the controller is on Wi-Fi or cellular. Cheap: one monitor for the
/// app lifetime, no polling.
final class NetworkPathObserver: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var kind = "unknown"
        var expensive: Bool?
        var constrained: Bool?
    }

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var snapshot = Snapshot()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            var next = Snapshot()
            if path.status != .satisfied { next.kind = "none" }
            else if path.usesInterfaceType(.wifi) { next.kind = "wifi" }
            else if path.usesInterfaceType(.cellular) { next.kind = "cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { next.kind = "wired" }
            next.expensive = path.isExpensive
            next.constrained = path.isConstrained
            self.lock.lock()
            self.snapshot = next
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "rctl.controller.network-path", qos: .utility))
    }

    deinit { monitor.cancel() }

    var current: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}
