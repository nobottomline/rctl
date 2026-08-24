import Foundation

public enum FileControlMessage: ValidatedWireMessage, Encodable {
    case get(path: String)
    case put(path: String, size: UInt64)
    case putEOF
    case cancel
    case getMeta(name: String, size: UInt64)
    case getEOF(cancelled: Bool?)
    case putOK(bytes: UInt64)
    case remoteError(message: String)

    public static let maximumJSONBytes = WireLimits.fileControlJSONBytes

    private enum CodingKeys: String, CodingKey {
        case operation = "op"
        case path
        case size
        case name
        case cancelled
        case bytes
        case message = "msg"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .operation) {
        case "get":
            self = .get(path: try values.decode(String.self, forKey: .path))
        case "put":
            self = .put(
                path: try values.decode(String.self, forKey: .path),
                size: try values.decode(UInt64.self, forKey: .size)
            )
        case "put_eof":
            self = .putEOF
        case "cancel":
            self = .cancel
        case "get_meta":
            self = .getMeta(
                name: try values.decode(String.self, forKey: .name),
                size: try values.decode(UInt64.self, forKey: .size)
            )
        case "get_eof":
            self = .getEOF(cancelled: try values.decodeIfPresent(Bool.self, forKey: .cancelled))
        case "put_ok":
            self = .putOK(bytes: try values.decode(UInt64.self, forKey: .bytes))
        case "err":
            self = .remoteError(message: try values.decode(String.self, forKey: .message))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .operation,
                in: values,
                debugDescription: "unknown file control operation"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch try validated() {
        case let .get(path):
            try values.encode("get", forKey: .operation)
            try values.encode(path, forKey: .path)
        case let .put(path, size):
            try values.encode("put", forKey: .operation)
            try values.encode(path, forKey: .path)
            try values.encode(size, forKey: .size)
        case .putEOF:
            try values.encode("put_eof", forKey: .operation)
        case .cancel:
            try values.encode("cancel", forKey: .operation)
        case let .getMeta(name, size):
            try values.encode("get_meta", forKey: .operation)
            try values.encode(name, forKey: .name)
            try values.encode(size, forKey: .size)
        case let .getEOF(cancelled):
            try values.encode("get_eof", forKey: .operation)
            try values.encodeIfPresent(cancelled, forKey: .cancelled)
        case let .putOK(bytes):
            try values.encode("put_ok", forKey: .operation)
            try values.encode(bytes, forKey: .bytes)
        case let .remoteError(message):
            try values.encode("err", forKey: .operation)
            try values.encode(message, forKey: .message)
        }
    }

    public func validated() throws -> Self {
        switch self {
        case let .get(path):
            guard !path.isEmpty, path.utf8.count <= WireLimits.filePathUTF8Bytes else {
                throw WireValidationError.invalidField("file.path")
            }
        case let .put(path, size):
            guard !path.isEmpty, path.utf8.count <= WireLimits.filePathUTF8Bytes else {
                throw WireValidationError.invalidField("file.path")
            }
            guard size <= WireLimits.fileSizeIntegerMax else {
                throw WireValidationError.invalidField("file.size")
            }
        case let .getMeta(name, size):
            guard !name.isEmpty, name.utf8.count <= 255 else {
                throw WireValidationError.invalidField("file.name")
            }
            guard size <= WireLimits.fileSizeIntegerMax else {
                throw WireValidationError.invalidField("file.size")
            }
        case let .putOK(bytes):
            guard bytes <= WireLimits.fileSizeIntegerMax else {
                throw WireValidationError.invalidField("file.bytes")
            }
        case let .remoteError(message):
            guard !message.isEmpty, message.utf8.count <= 256 else {
                throw WireValidationError.invalidField("file.error")
            }
        case .putEOF, .cancel, .getEOF:
            break
        }
        return self
    }
}
