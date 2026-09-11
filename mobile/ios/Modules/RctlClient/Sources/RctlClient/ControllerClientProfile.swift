import CryptoKit
import Foundation

/// Static facts a controller reports about itself. Sent once after pairing and
/// again only when the fingerprint changes (an OS or app update), never on a
/// schedule after a compatible schema acknowledgement. Field names and bounds mirror the relay whitelist; the relay drops
/// unknown keys, so adding a field here is backward compatible.
public struct ControllerClientProfile: Codable, Equatable, Sendable {
    /// Bumped when the accepted field contract changes, including additive keys.
    public static let schemaVersion: Int64 = 2

    public var schemaVersion: Int64? = Self.schemaVersion
    public var protocolMajor: Int64?
    public var protocolMinor: Int64?
    public var buildRevision: String?
    public var installChannel: String?
    /// What this build of the app can do, as stable lowercase tokens. The relay
    /// stores them so a future server can decide per controller instead of
    /// guessing from `app_version`.
    public var capabilities: [String] = []
    public var model: String?
    public var modelName: String?
    public var idiom: String?
    public var systemName: String?
    public var systemVersion: String?
    public var osBuild: String?
    public var appVersion: String?
    public var appBuild: String?
    public var bundleID: String?
    public var deviceName: String?
    public var locale: String?
    public var language: String?
    public var timezone: String?
    public var screen: String?
    public var cpuCount: Int64?
    public var memoryBytes: Int64?
    public var diskBytes: Int64?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case protocolMajor = "protocol_major"
        case protocolMinor = "protocol_minor"
        case buildRevision = "build_revision"
        case installChannel = "install_channel"
        case capabilities
        case model
        case modelName = "model_name"
        case idiom
        case systemName = "system_name"
        case systemVersion = "system_version"
        case osBuild = "os_build"
        case appVersion = "app_version"
        case appBuild = "app_build"
        case bundleID = "bundle_id"
        case deviceName = "device_name"
        case locale, language, timezone, screen
        case cpuCount = "cpu_count"
        case memoryBytes = "memory_bytes"
        case diskBytes = "disk_bytes"
    }

    /// Relay-side limits, applied here too so a long device name never turns a
    /// profile update into a rejected request.
    private static let stringLimits: [CodingKeys: Int] = [
        .model: 64, .modelName: 80, .idiom: 16, .systemName: 32, .systemVersion: 32,
        .osBuild: 32, .appVersion: 32, .appBuild: 32, .bundleID: 128, .deviceName: 80,
        .locale: 32, .language: 32, .timezone: 64, .screen: 48, .installChannel: 24,
        .buildRevision: 64,
    ]

    /// A copy with every string trimmed and truncated to the relay bounds.
    public func bounded() -> ControllerClientProfile {
        var copy = self
        func clamp(_ value: String?, _ key: CodingKeys) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .controlCharacters).joined(separator: " ")
            guard !trimmed.isEmpty else { return nil }
            let limit = Self.stringLimits[key] ?? 32
            return trimmed.unicodeScalars.count > limit ? String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(limit))) : trimmed
        }
        copy.model = clamp(model, .model)
        copy.modelName = clamp(modelName, .modelName)
        copy.idiom = clamp(idiom, .idiom)
        copy.systemName = clamp(systemName, .systemName)
        copy.systemVersion = clamp(systemVersion, .systemVersion)
        copy.osBuild = clamp(osBuild, .osBuild)
        copy.appVersion = clamp(appVersion, .appVersion)
        copy.appBuild = clamp(appBuild, .appBuild)
        copy.bundleID = clamp(bundleID, .bundleID)
        copy.deviceName = clamp(deviceName, .deviceName)
        copy.locale = clamp(locale, .locale)
        copy.language = clamp(language, .language)
        copy.timezone = clamp(timezone, .timezone)
        copy.screen = clamp(screen, .screen)
        copy.installChannel = clamp(installChannel, .installChannel)
        copy.buildRevision = clamp(buildRevision, .buildRevision)
        for key in [\ControllerClientProfile.cpuCount, \.memoryBytes, \.diskBytes, \.protocolMajor, \.protocolMinor, \.schemaVersion] {
            if let value = copy[keyPath: key], value < 0 || value > 1 << 53 { copy[keyPath: key] = nil }
        }
        var seen = Set<String>()
        copy.capabilities = Array(capabilities
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.range(of: "^[a-z0-9][a-z0-9_.:-]{0,31}$", options: .regularExpression) != nil && seen.insert($0).inserted }
            .sorted().prefix(32))
        return copy
    }

    /// Canonical JSON (sorted keys, no nulls) used both on the wire and for the
    /// change fingerprint stored per relay.
    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(bounded())
    }

    public var fingerprint: String {
        guard let data = try? canonicalJSON() else { return "" }
        return Data(SHA256.hash(data: data)).base64URLEncodedString
    }
}

/// Dynamic facts carried by the presence heartbeat while the app is in the
/// foreground. Reports are linked to the persistent controller identity.
public struct ControllerTelemetry: Codable, Equatable, Sendable {
    public var batteryLevel: Int? // percent 0...100
    public var batteryState: String? // unplugged | charging | full | unknown
    public var lowPower: Bool?
    public var thermal: String? // nominal | fair | serious | critical
    public var network: String? // wifi | cellular | wired | none | unknown
    public var networkExpensive: Bool? // hotspot or cellular
    public var networkConstrained: Bool? // Low Data Mode
    public var lanIP: String? // private address on the local network, for LAN diagnostics
    public var diskFreeBytes: Int64?
    public var memoryAvailableBytes: Int64?
    public var uptimeSeconds: Int64?

    public init(batteryLevel: Int? = nil, batteryState: String? = nil, lowPower: Bool? = nil,
                thermal: String? = nil, network: String? = nil, networkExpensive: Bool? = nil,
                networkConstrained: Bool? = nil, lanIP: String? = nil, diskFreeBytes: Int64? = nil,
                memoryAvailableBytes: Int64? = nil, uptimeSeconds: Int64? = nil) {
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.lowPower = lowPower
        self.thermal = thermal
        self.network = network
        self.networkExpensive = networkExpensive
        self.networkConstrained = networkConstrained
        self.lanIP = lanIP
        self.diskFreeBytes = diskFreeBytes
        self.memoryAvailableBytes = memoryAvailableBytes
        self.uptimeSeconds = uptimeSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case batteryLevel = "battery_level"
        case batteryState = "battery_state"
        case lowPower = "low_power"
        case thermal, network
        case networkExpensive = "network_expensive"
        case networkConstrained = "network_constrained"
        case lanIP = "lan_ip"
        case diskFreeBytes = "disk_free_bytes"
        case memoryAvailableBytes = "memory_available_bytes"
        case uptimeSeconds = "uptime_seconds"
    }
}
