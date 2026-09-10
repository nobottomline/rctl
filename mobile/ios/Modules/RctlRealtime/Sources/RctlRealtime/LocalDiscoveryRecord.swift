import Foundation
import RctlProtocol

public enum LocalDiscoveryError: Error, Equatable, Sendable {
    case malformedRecord, unsupportedVersion, unsupportedNetwork, unavailable, timedOut, busy
}

public struct LocalDiscoveryRecord: Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public var compatible: Bool { major == WireProtocolVersion.current.major }
    public static let maximumBytes = WireLimits.discoveryTXTBytes

    public init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw LocalDiscoveryError.malformedRecord }
        let bytes = Array(data)
        var fields: [String: [UInt8]] = [:]
        var index = 0
        while index < bytes.count {
            let count = Int(bytes[index]); index += 1
            guard count > 0, count <= bytes.count - index else { throw LocalDiscoveryError.malformedRecord }
            let entry = Array(bytes[index..<index + count]); index += count
            let separator = entry.firstIndex(of: 61) ?? entry.count
            let keyBytes = entry[..<separator]
            guard !keyBytes.isEmpty, keyBytes.allSatisfy({ (32...126).contains($0) && $0 != 61 }) else {
                throw LocalDiscoveryError.malformedRecord
            }
            let key = String(decoding: keyBytes, as: UTF8.self).lowercased()
            guard fields[key] == nil else { throw LocalDiscoveryError.malformedRecord }
            fields[key] = separator < entry.count ? Array(entry[(separator + 1)...]) : []
        }
        guard fields["txtvers"] == Array("1".utf8), let version = fields["pv"],
              version.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else {
            throw LocalDiscoveryError.malformedRecord
        }
        let parts = String(decoding: version, as: UTF8.self).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]),
              (1...65535).contains(major), (0...65535).contains(minor),
              String(major) == parts[0], String(minor) == parts[1] else { throw LocalDiscoveryError.malformedRecord }
        self.major = major; self.minor = minor
    }
}

public struct LocalServiceIdentity: Hashable, Sendable {
    public let name: String
    public let type: String
    public let domain: String

    public init(name: String, type: String, domain: String) throws {
        var type = type.lowercased()
        if type.hasSuffix(".") { type.removeLast() }
        guard type == "_rctl._tcp", domain.lowercased() == "local.",
              !name.isEmpty, name.utf8.count <= 63,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LocalDiscoveryError.malformedRecord
        }
        self.name = name; self.type = "_rctl._tcp"; self.domain = "local."
    }
}

public struct ResolvedLocalDevice: Equatable, Sendable {
    public let address: LocalDeviceAddress
    public let record: LocalDiscoveryRecord
    public let interfaceIndex: UInt32
}
