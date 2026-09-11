import CryptoKit
import Foundation

/// Static facts a controller reports about itself. Sent once after pairing and
/// again only when the fingerprint changes (an OS or app update), never on a
/// schedule. Field names and bounds mirror the relay whitelist; the relay drops
/// unknown keys, so adding a field here is backward compatible.
public struct ControllerClientProfile: Codable, Equatable, Sendable {
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
    public var diskFreeBytes: Int64?

    public init() {}

    private enum CodingKeys: String, CodingKey {
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
        case diskFreeBytes = "disk_free_bytes"
    }

    /// Relay-side limits, applied here too so a long device name never turns a
    /// profile update into a rejected request.
    private static let stringLimits: [CodingKeys: Int] = [
        .model: 64, .modelName: 80, .idiom: 16, .systemName: 32, .systemVersion: 32,
        .osBuild: 32, .appVersion: 32, .appBuild: 32, .bundleID: 128, .deviceName: 80,
        .locale: 32, .language: 32, .timezone: 64, .screen: 48,
    ]

    /// A copy with every string trimmed and truncated to the relay bounds.
    public func bounded() -> ControllerClientProfile {
        var copy = self
        func clamp(_ value: String?, _ key: CodingKeys) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
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
        for key in [\ControllerClientProfile.cpuCount, \.memoryBytes, \.diskBytes, \.diskFreeBytes] {
            if let value = copy[keyPath: key], value < 0 { copy[keyPath: key] = nil }
        }
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
/// foreground. Nothing here identifies the person; it describes the phone's
/// current condition so an operator can see why a controller went quiet.
public struct ControllerTelemetry: Codable, Equatable, Sendable {
    public var batteryLevel: Int? // percent 0...100
    public var batteryState: String? // unplugged | charging | full | unknown
    public var lowPower: Bool?
    public var thermal: String? // nominal | fair | serious | critical
    public var network: String? // wifi | cellular | wired | none | unknown
    public var diskFreeBytes: Int64?

    public init(batteryLevel: Int? = nil, batteryState: String? = nil, lowPower: Bool? = nil,
                thermal: String? = nil, network: String? = nil, diskFreeBytes: Int64? = nil) {
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.lowPower = lowPower
        self.thermal = thermal
        self.network = network
        self.diskFreeBytes = diskFreeBytes
    }

    private enum CodingKeys: String, CodingKey {
        case batteryLevel = "battery_level"
        case batteryState = "battery_state"
        case lowPower = "low_power"
        case thermal, network
        case diskFreeBytes = "disk_free_bytes"
    }
}
