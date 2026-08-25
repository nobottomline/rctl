import Foundation

public struct RemoteStateMessage: ValidatedWireMessage, Encodable {
    public static let maximumJSONBytes = WireLimits.controlJSONBytes

    public let version: Int
    public let orientation: Int

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case orientation
    }

    public init(version: Int = 1, orientation: Int) {
        self.version = version
        self.orientation = orientation
    }

    public func validated() throws -> Self {
        guard version == 1 else {
            throw WireValidationError.invalidField("state.version")
        }
        guard (1...4).contains(orientation) else {
            throw WireValidationError.invalidField("state.orientation")
        }
        return self
    }
}
