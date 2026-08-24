import Foundation

public struct WireProtocolVersion: Codable, Equatable, Sendable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public func compatibility(with remote: Self) -> ProtocolCompatibility {
        guard major == remote.major else {
            return .incompatibleMajor(local: major, remote: remote.major)
        }
        guard minor == remote.minor else {
            return .minorDifference(local: minor, remote: remote.minor)
        }
        return .compatible
    }
}

public enum ProtocolCompatibility: Equatable, Sendable {
    case compatible
    case minorDifference(local: Int, remote: Int)
    case incompatibleMajor(local: Int, remote: Int)

    public var canConnect: Bool {
        if case .incompatibleMajor = self { return false }
        return true
    }
}

public struct ComponentBuild: Codable, Equatable, Sendable {
    public let version: String

    public init(version: String) {
        self.version = version
    }
}

public struct Capabilities: Decodable, Equatable, Sendable {
    public let product: String
    public let component: String
    public let daemon: ComponentBuild?
    public let browser: ComponentBuild?
    public let relay: ComponentBuild?
    public let protocolVersion: WireProtocolVersion
    public let features: Set<String>

    private enum CodingKeys: String, CodingKey {
        case product
        case component
        case daemon
        case browser
        case relay
        case protocolVersion = "protocol"
        case features
    }

    public func validated() throws -> Self {
        guard product == "rctl" else { throw CapabilitiesValidationError.unexpectedProduct }
        guard !component.isEmpty, component.utf8.count <= 32 else {
            throw CapabilitiesValidationError.invalidComponent
        }
        switch component {
        case "daemon":
            guard daemon != nil, browser != nil else {
                throw CapabilitiesValidationError.missingComponentVersion
            }
        case "relay":
            guard relay != nil else { throw CapabilitiesValidationError.missingComponentVersion }
        default:
            throw CapabilitiesValidationError.unsupportedComponent
        }
        let builds = [daemon, browser, relay].compactMap { $0 }
        guard builds.allSatisfy({ !$0.version.isEmpty && $0.version.utf8.count <= 64 }) else {
            throw CapabilitiesValidationError.invalidComponentVersion
        }
        guard protocolVersion.major >= 1, protocolVersion.minor >= 0 else {
            throw CapabilitiesValidationError.invalidProtocolVersion
        }
        guard features.count <= 128 else { throw CapabilitiesValidationError.tooManyFeatures }
        guard features.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 96 }) else {
            throw CapabilitiesValidationError.invalidFeature
        }
        return self
    }
}

public enum CapabilitiesValidationError: Error, Equatable, Sendable {
    case unexpectedProduct
    case invalidComponent
    case unsupportedComponent
    case missingComponentVersion
    case invalidComponentVersion
    case invalidProtocolVersion
    case tooManyFeatures
    case invalidFeature
}
