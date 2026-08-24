import Foundation

public protocol ValidatedWireMessage: Decodable, Equatable, Sendable {
    static var maximumJSONBytes: Int { get }
    func validated() throws -> Self
}

public enum WireJSON {
    public static func decode<Message: ValidatedWireMessage>(
        _ type: Message.Type,
        from data: Data,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> Message {
        guard data.count <= Message.maximumJSONBytes else {
            throw WireValidationError.messageTooLarge(
                actual: data.count,
                maximum: Message.maximumJSONBytes
            )
        }
        return try decoder.decode(type, from: data).validated()
    }

    public static func encode<Message: ValidatedWireMessage & Encodable>(
        _ message: Message,
        using encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        let data = try encoder.encode(message.validated())
        guard data.count <= Message.maximumJSONBytes else {
            throw WireValidationError.messageTooLarge(
                actual: data.count,
                maximum: Message.maximumJSONBytes
            )
        }
        return data
    }
}

public enum WireValidationError: Error, Equatable, Sendable {
    case messageTooLarge(actual: Int, maximum: Int)
    case invalidField(String)
}

extension Capabilities: ValidatedWireMessage {
    public static let maximumJSONBytes = WireLimits.capabilitiesJSONBytes
}
