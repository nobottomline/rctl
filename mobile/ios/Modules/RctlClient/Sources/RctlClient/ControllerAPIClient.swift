import CryptoKit
import Foundation
import Security

public struct ControllerAPIClient: Sendable {
    private static let responseLimit = 1 << 20
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func decodePairing(
        from data: Data,
        now: Date = Date(),
        allowInsecureLoopback: Bool = false
    ) throws -> ControllerPairingPayload {
        guard data.count <= 4_096 else { throw ControllerClientError.invalidPairing }
        return try JSONDecoder().decode(ControllerPairingPayload.self, from: data)
            .validated(now: now, allowInsecureLoopback: allowInsecureLoopback)
    }

    public func claim(
        pairing: ControllerPairingPayload,
        controllerName: String,
        signingKey: ControllerSigningKey,
        now: Date = Date(),
        allowInsecureLoopback: Bool = false
    ) async throws -> ControllerClaimResult {
        let request = try makeClaimRequest(
            pairing: pairing,
            controllerName: controllerName,
            signingKey: signingKey,
            now: now,
            allowInsecureLoopback: allowInsecureLoopback
        )
        let result = try await send(request, as: ControllerClaimResult.self)
        _ = try result.controller.validated()
        _ = try result.tokens.validated()
        return result
    }

    public func controllerInfo(
        origin: String,
        accessToken: String,
        signingKey: ControllerSigningKey,
        allowInsecureLoopback: Bool = false
    ) async throws -> PairedController {
        let request = try makeSignedRequest(
            origin: origin,
            path: "/api/controller/me",
            method: "GET",
            token: accessToken,
            body: Data(),
            signingKey: signingKey,
            expectedTokenPrefix: "cat_",
            allowInsecureLoopback: allowInsecureLoopback
        )
        struct Envelope: Decodable { let controller: PairedController }
        return try await send(request, as: Envelope.self).controller.validated()
    }

    public func refresh(
        origin: String,
        refreshToken: String,
        signingKey: ControllerSigningKey,
        allowInsecureLoopback: Bool = false
    ) async throws -> ControllerTokenPair {
        let request = try makeSignedRequest(
            origin: origin,
            path: "/api/controller/token/refresh",
            method: "POST",
            token: refreshToken,
            body: Data(),
            signingKey: signingKey,
            expectedTokenPrefix: "crt_",
            allowInsecureLoopback: allowInsecureLoopback
        )
        struct Envelope: Decodable { let tokens: ControllerTokenPair }
        return try await send(request, as: Envelope.self).tokens.validated()
    }

    func makeClaimRequest(
        pairing: ControllerPairingPayload,
        controllerName: String,
        signingKey: ControllerSigningKey,
        now: Date,
        allowInsecureLoopback: Bool
    ) throws -> URLRequest {
        let validated = try pairing.validated(now: now, allowInsecureLoopback: allowInsecureLoopback)
        let name = normalizedControllerName(controllerName)
        guard !name.isEmpty else { throw ControllerClientError.invalidControllerName }
        let proofMessage = [
            "rctl-pair-v1",
            validated.pairingID,
            validated.secret,
            name,
            "ios",
            signingKey.publicKeyFingerprint,
        ].joined(separator: "\n")
        let body = try JSONEncoder().encode(ControllerClaimRequest(
            secret: validated.secret,
            name: name,
            platform: "ios",
            publicKey: signingKey.publicKeySPKIDER.base64URLEncodedString,
            proof: try signingKey.signature(for: Data(proofMessage.utf8)).base64URLEncodedString
        ))
        let origin = try validated.validatedOrigin(allowInsecureLoopback: allowInsecureLoopback)
        guard let url = URL(string: "/api/controller/pairings/\(validated.pairingID)/claim", relativeTo: origin)?.absoluteURL else {
            throw ControllerClientError.invalidRelayOrigin
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    func makeSignedRequest(
        origin: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String,
        token: String,
        body: Data,
        signingKey: ControllerSigningKey,
        expectedTokenPrefix: String? = nil,
        allowInsecureLoopback: Bool = false,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970),
        nonce: Data? = nil
    ) throws -> URLRequest {
        guard body.count <= Self.responseLimit,
              path.hasPrefix("/"), !path.contains("?"), !path.contains("#") else {
            throw ControllerClientError.invalidResponse
        }
        let tokenID = try controllerTokenID(token, expectedPrefix: expectedTokenPrefix)
        let canonicalQuery = try Self.canonicalQuery(queryItems)
        guard var components = URLComponents(string: origin), components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw ControllerClientError.invalidRelayOrigin
        }
        if components.scheme != "https" {
            let loopback = components.host == "127.0.0.1" || components.host == "localhost" || components.host == "::1"
            guard allowInsecureLoopback, components.scheme == "http", loopback else {
                throw ControllerClientError.insecureRelayOrigin
            }
        }
        components.percentEncodedPath = path
        components.percentEncodedQuery = canonicalQuery.isEmpty ? nil : canonicalQuery
        guard let url = components.url else { throw ControllerClientError.invalidRelayOrigin }

        let nonceData = try nonce ?? randomNonce()
        guard (16...32).contains(nonceData.count) else { throw ControllerClientError.invalidResponse }
        let encodedNonce = nonceData.base64URLEncodedString
        let bodyHash = Data(SHA256.hash(data: body)).base64URLEncodedString
        let proofMessage = [
            "rctl-request-v1",
            tokenID,
            String(timestamp),
            encodedNonce,
            method.uppercased(),
            path,
            canonicalQuery,
            bodyHash,
        ].joined(separator: "\n")

        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.httpBody = body.isEmpty ? nil : body
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-RCTL-Timestamp")
        request.setValue(encodedNonce, forHTTPHeaderField: "X-RCTL-Nonce")
        request.setValue(
            try signingKey.signature(for: Data(proofMessage.utf8)).base64URLEncodedString,
            forHTTPHeaderField: "X-RCTL-Signature"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !body.isEmpty { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    static func canonicalQuery(_ items: [URLQueryItem]) throws -> String {
        var pairs: [(String, String)] = []
        pairs.reserveCapacity(items.count)
        for item in items {
            let value = item.value ?? ""
            guard !item.name.contains("\r"), !item.name.contains("\n"),
                  !value.contains("\r"), !value.contains("\n") else {
                throw ControllerClientError.invalidResponse
            }
            pairs.append((rfc3986Encode(item.name), rfc3986Encode(value)))
        }
        pairs.sort { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    private func send<Response: Decodable>(_ request: URLRequest, as type: Response.Type) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard data.count <= Self.responseLimit else { throw ControllerClientError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else { throw ControllerClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error) ?? "http_error"
            throw ControllerClientError.http(status: http.statusCode, code: code)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ControllerClientError.invalidResponse
        }
    }

    private func normalizedControllerName(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "My controller" : trimmed
        return String(value.unicodeScalars.prefix(80))
    }

    private func controllerTokenID(_ token: String, expectedPrefix: String?) throws -> String {
        guard let id = validControllerToken(token, prefix: expectedPrefix) else {
            throw ControllerClientError.invalidToken
        }
        return id
    }

    private func randomNonce() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ControllerClientError.keyUnavailable
        }
        return Data(bytes)
    }
}

private struct ControllerClaimRequest: Encodable {
    let secret: String
    let name: String
    let platform: String
    let publicKey: String
    let proof: String

    private enum CodingKeys: String, CodingKey {
        case secret
        case name
        case platform
        case publicKey = "public_key"
        case proof
    }
}

private struct ErrorEnvelope: Decodable {
    let error: String
}

private func rfc3986Encode(_ value: String) -> String {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
    return value.utf8.map { byte in
        allowed.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
    }.joined()
}
