import Foundation
import RctlProtocol

public enum ControllerScope: String, Codable, CaseIterable, Hashable, Sendable {
    case screenView = "screen.view"
    case deviceControl = "device.control"
    case audioListen = "audio.listen"
    case microphoneTalk = "microphone.talk"
    case camera
    case filesRead = "files.read"
    case filesWrite = "files.write"
    case terminal
    case systemDestructive = "system.destructive"
    case deviceUpdate = "device.update"
}

public struct ControllerPairingPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let origin: String
    public let pairingID: String
    public let secret: String
    public let expiresAt: Int64
    public let protocolMajor: Int
    public let relayID: String

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case origin
        case pairingID = "pairing_id"
        case secret
        case expiresAt = "expires_at"
        case protocolMajor = "protocol_major"
        case relayID = "relay_id"
    }

    public func validated(now: Date = Date(), allowInsecureLoopback: Bool = false) throws -> Self {
        guard version == 1 else { throw ControllerClientError.unsupportedPairingVersion(version) }
        guard protocolMajor == WireProtocolVersion.current.major else {
            throw ControllerClientError.incompatibleProtocol(
                local: WireProtocolVersion.current.major,
                remote: protocolMajor
            )
        }
        guard expiresAt > Int64(now.timeIntervalSince1970) else {
            throw ControllerClientError.expiredPairing
        }
        guard pairingID.hasPrefix("pair_"), pairingID.utf8.count <= 64,
              pairingID.utf8.allSatisfy({ $0.isBase64URLByte }),
              secret.utf8.count >= 32, secret.utf8.count <= 256,
              secret.utf8.allSatisfy({ $0.isBase64URLByte }),
              relayID.utf8.count >= 32, relayID.utf8.count <= 128,
              relayID.utf8.allSatisfy({ $0.isBase64URLByte }),
              expiresAt <= Int64(now.addingTimeInterval(15 * 60).timeIntervalSince1970) else {
            throw ControllerClientError.invalidPairing
        }
        _ = try validatedOrigin(allowInsecureLoopback: allowInsecureLoopback)
        return self
    }

    public func validatedOrigin(allowInsecureLoopback: Bool = false) throws -> URL {
        guard let components = URLComponents(string: origin),
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let url = components.url else {
            throw ControllerClientError.invalidRelayOrigin
        }
        if components.scheme == "https" { return url }
        let loopback = components.host == "127.0.0.1" || components.host == "localhost" || components.host == "::1"
        guard allowInsecureLoopback, components.scheme == "http", loopback else {
            throw ControllerClientError.insecureRelayOrigin
        }
        return url
    }
}

extension UInt8 {
    var isBase64URLByte: Bool {
        (48...57).contains(self) || (65...90).contains(self) ||
            (97...122).contains(self) || self == 45 || self == 95
    }
}

public struct PairedController: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let platform: String
    public let scopes: [ControllerScope]

    public init(id: String, name: String, platform: String, scopes: [ControllerScope]) {
        self.id = id
        self.name = name
        self.platform = platform
        self.scopes = scopes
    }

    func validated() throws -> Self {
        guard id.hasPrefix("ctl_"), id.utf8.count <= 64,
              id.utf8.allSatisfy({ $0.isBase64URLByte }),
              !name.isEmpty, name.unicodeScalars.count <= 80,
              platform == "ios",
              !scopes.isEmpty, scopes.count <= ControllerScope.allCases.count,
              Set(scopes).count == scopes.count else {
            throw ControllerClientError.invalidResponse
        }
        return self
    }
}

public struct ControllerTokenPair: Codable, Equatable, Sendable {
    public let accessToken: String
    public let accessExpiresAt: Int64
    public let refreshToken: String
    public let refreshExpiresAt: Int64

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accessExpiresAt = "access_expires_at"
        case refreshToken = "refresh_token"
        case refreshExpiresAt = "refresh_expires_at"
    }

    func validated(now: Date = Date()) throws -> Self {
        let oldestAcceptedExpiry = Int64(now.timeIntervalSince1970) - 90
        guard validControllerToken(accessToken, prefix: "cat_") != nil,
              validControllerToken(refreshToken, prefix: "crt_") != nil,
              accessExpiresAt > oldestAcceptedExpiry,
              refreshExpiresAt > accessExpiresAt else {
            throw ControllerClientError.invalidResponse
        }
        return self
    }
}

public struct ControllerClaimResult: Codable, Equatable, Sendable {
    public let controller: PairedController
    public let tokens: ControllerTokenPair
}

public struct ControllerRefreshCredential: Codable, Equatable, Sendable {
    public let origin: String
    public let relayID: String
    public let controller: PairedController
    public let refreshToken: String
    public let refreshExpiresAt: Int64

    public init(
        pairing: ControllerPairingPayload,
        claim: ControllerClaimResult
    ) {
        origin = pairing.origin
        relayID = pairing.relayID
        controller = claim.controller
        refreshToken = claim.tokens.refreshToken
        refreshExpiresAt = claim.tokens.refreshExpiresAt
    }

    public init(
        origin: String,
        relayID: String,
        controller: PairedController,
        refreshToken: String,
        refreshExpiresAt: Int64
    ) {
        self.origin = origin
        self.relayID = relayID
        self.controller = controller
        self.refreshToken = refreshToken
        self.refreshExpiresAt = refreshExpiresAt
    }
}

public enum ControllerClientError: Error, Equatable, Sendable {
    case invalidPairing
    case unsupportedPairingVersion(Int)
    case incompatibleProtocol(local: Int, remote: Int)
    case expiredPairing
    case invalidRelayOrigin
    case insecureRelayOrigin
    case invalidControllerName
    case invalidToken
    case invalidResponse
    case responseTooLarge
    case http(status: Int, code: String)
    case keyUnavailable
    case corruptCredential
    case keychain(operation: String, status: Int32)
}

func validControllerToken(_ token: String, prefix: String? = nil) -> String? {
    guard token.utf8.count <= 256,
          let separator = token.firstIndex(of: "."),
          separator != token.startIndex,
          token.index(after: separator) != token.endIndex else {
        return nil
    }
    let id = token[..<separator]
    let secret = token[token.index(after: separator)...]
    guard id.utf8.allSatisfy({ $0.isBase64URLByte }),
          secret.utf8.allSatisfy({ $0.isBase64URLByte }),
          prefix.map({ id.hasPrefix($0) }) ?? true else {
        return nil
    }
    return String(id)
}
