import Foundation

public struct ControllerDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let online: Bool
    public let daemonVersion: String?
    public let browserVersion: String?
    public let protocolMajor: Int?
    public let protocolMinor: Int?
    public let features: [String]
    public let compatible: Bool
    public let compatibilityError: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case online
        case daemonVersion = "daemon_version"
        case browserVersion = "browser_version"
        case protocolMajor = "protocol_major"
        case protocolMinor = "protocol_minor"
        case features
        case compatible
        case compatibilityError = "compatibility_error"
    }

    func validated() throws -> Self {
        guard !id.isEmpty, id.utf8.count <= 80,
              id.utf8.allSatisfy({ $0.isDeviceIDByte }),
              !name.isEmpty, name.unicodeScalars.count <= 120,
              status == "approved",
              daemonVersion.map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true,
              browserVersion.map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true,
              protocolMajor.map({ $0 > 0 }) ?? true,
              protocolMinor.map({ $0 >= 0 }) ?? true,
              features.count <= 128, Set(features).count == features.count,
              features.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 96 }),
              compatibilityError.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true else {
            throw ControllerClientError.invalidResponse
        }
        return self
    }
}

public enum ControllerMediaRole: String, Sendable {
    case screen
    case camera
}

extension UInt8 {
    var isDeviceIDByte: Bool {
        (48...57).contains(self) || (65...90).contains(self) ||
            (97...122).contains(self) || self == 45 || self == 46 || self == 95
    }
}
