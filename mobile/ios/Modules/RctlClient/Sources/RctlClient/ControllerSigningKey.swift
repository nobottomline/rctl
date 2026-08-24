import CryptoKit
import Foundation

public enum ControllerSigningKey: Sendable {
    case software(P256.Signing.PrivateKey)
    case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)

    public static func generate(preferSecureEnclave: Bool = true) throws -> Self {
        if preferSecureEnclave, SecureEnclave.isAvailable {
            return .secureEnclave(try SecureEnclave.P256.Signing.PrivateKey())
        }
        return .software(P256.Signing.PrivateKey())
    }

    public init(softwareRawRepresentation: Data) throws {
        self = .software(try P256.Signing.PrivateKey(rawRepresentation: softwareRawRepresentation))
    }

    public var publicKeySPKIDER: Data {
        // RFC 5480 SubjectPublicKeyInfo for id-ecPublicKey + prime256v1,
        // followed by the uncompressed SEC1 point used by CryptoKit.
        let prefix = Data([
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
        ])
        return prefix + publicKeyX963Representation
    }

    public var publicKeyFingerprint: String {
        Data(SHA256.hash(data: publicKeySPKIDER)).base64URLEncodedString
    }

    public func signature(for message: Data) throws -> Data {
        let digest = SHA256.hash(data: message)
        switch self {
        case let .software(key):
            return try key.signature(for: digest).derRepresentation
        case let .secureEnclave(key):
            return try key.signature(for: digest).derRepresentation
        }
    }

    var persistedRepresentation: Data {
        switch self {
        case let .software(key):
            return Data([0]) + key.rawRepresentation
        case let .secureEnclave(key):
            return Data([1]) + key.dataRepresentation
        }
    }

    init(persistedRepresentation: Data) throws {
        guard let kind = persistedRepresentation.first, persistedRepresentation.count > 1 else {
            throw ControllerClientError.keyUnavailable
        }
        let value = persistedRepresentation.dropFirst()
        switch kind {
        case 0:
            self = .software(try P256.Signing.PrivateKey(rawRepresentation: value))
        case 1:
            self = .secureEnclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: value))
        default:
            throw ControllerClientError.keyUnavailable
        }
    }

    private var publicKeyX963Representation: Data {
        switch self {
        case let .software(key): return key.publicKey.x963Representation
        case let .secureEnclave(key): return key.publicKey.x963Representation
        }
    }
}
