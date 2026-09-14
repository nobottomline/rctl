import CryptoKit
import Foundation
import Testing
@testable import RctlClient

@Suite("Controller request proofs")
struct ControllerRequestTests {
    @Test("Claim body proves possession of the submitted key")
    func claimProof() throws {
        let key = try deterministicKey()
        let pairing = try pairing()
        let request = try ControllerAPIClient().makeClaimRequest(
            pairing: pairing,
            controllerName: "  Owner phone  ",
            signingKey: key,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            allowInsecureLoopback: false
        )
        let body = try #require(request.httpBody)
        let claim = try JSONDecoder().decode(ClaimBody.self, from: body)

        #expect(request.url?.absoluteString == "https://relay.example/api/controller/pairings/pair_abcdefghijklmnopqrstuvwxyz/claim")
        #expect(claim.name == "Owner phone")
        #expect(claim.platform == "ios")
        #expect(claim.relayID == pairing.relayID)
        #expect(claim.publicKey == key.publicKeySPKIDER.base64URLEncodedString)

        let message = [
            "rctl-pair-v2",
            pairing.relayID,
            pairing.origin,
            pairing.pairingID,
            pairing.secret,
            claim.name,
            claim.platform,
            key.publicKeyFingerprint,
        ].joined(separator: "\n")
        let signature = try #require(Data(base64URLString: claim.proof))
        #expect(try verifies(signature: signature, message: Data(message.utf8), key: key))
    }

    @Test("Signed requests use the canonical Go query contract")
    func signedRequest() throws {
        let key = try deterministicKey()
        let nonce = Data(repeating: 0xab, count: 24)
        let request = try ControllerAPIClient().makeSignedRequest(
            origin: "https://relay.example",
            path: "/api/controller/me",
            queryItems: [
                URLQueryItem(name: "b", value: "hello world"),
                URLQueryItem(name: "a", value: "~"),
                URLQueryItem(name: "a", value: "/"),
            ],
            method: "get",
            token: "cat_example.secret-value",
            body: Data(),
            signingKey: key,
            timestamp: 1_700_000_010,
            nonce: nonce
        )

        #expect(request.url?.absoluteString == "https://relay.example/api/controller/me?a=%2F&a=~&b=hello%20world")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cat_example.secret-value")
        #expect(request.value(forHTTPHeaderField: "X-RCTL-Nonce") == nonce.base64URLEncodedString)

        let bodyHash = Data(SHA256.hash(data: Data())).base64URLEncodedString
        let message = [
            "rctl-request-v1",
            "cat_example",
            "1700000010",
            nonce.base64URLEncodedString,
            "GET",
            "/api/controller/me",
            "a=%2F&a=~&b=hello%20world",
            bodyHash,
        ].joined(separator: "\n")
        let encodedSignature = try #require(request.value(forHTTPHeaderField: "X-RCTL-Signature"))
        let signature = try #require(Data(base64URLString: encodedSignature))
        #expect(try verifies(signature: signature, message: Data(message.utf8), key: key))
    }

    @Test("Canonical query rejects header injection")
    func queryInjection() {
        #expect(throws: ControllerClientError.invalidResponse) {
            try ControllerAPIClient.canonicalQuery([URLQueryItem(name: "safe", value: "bad\nvalue")])
        }
    }

    @Test("Signaling request preserves proof path while upgrading to WSS")
    func signalingRequest() throws {
        let key = try deterministicKey()
        let request = try ControllerAPIClient().makeSignalingRequest(
            origin: "https://relay.example",
            deviceID: "ipad.air_3",
            media: .camera,
            accessToken: "cat_example.secret-value",
            signingKey: key
        )

        #expect(request.url?.absoluteString ==
            "wss://relay.example/api/controller/devices/ipad.air_3/signal?media=camera")
        #expect(request.value(forHTTPHeaderField: "Authorization") ==
            "Bearer cat_example.secret-value")
        #expect(request.value(forHTTPHeaderField: "X-RCTL-Signature")?.isEmpty == false)
        #expect(throws: ControllerClientError.invalidResponse) {
            try ControllerAPIClient().makeSignalingRequest(
                origin: "https://relay.example",
                deviceID: "../admin",
                media: .screen,
                accessToken: "cat_example.secret-value",
                signingKey: key
            )
        }
    }

    @Test("Controller device response rejects administrative and malformed rows")
    func deviceValidation() throws {
        let approved = try JSONDecoder().decode(ControllerDevice.self, from: Data("""
        {
          "id": "ipad.air_3",
          "name": "iPad Air 3",
          "status": "approved",
          "online": true,
          "daemon_version": "0.3.3",
          "browser_version": "0.3.3",
          "protocol_major": 1,
          "protocol_minor": 0,
          "features": ["screen.webrtc", "controller.scoped_sessions"],
          "compatible": true
        }
        """.utf8))
        #expect(try approved.validated() == approved)
        #expect(approved.supportsNativeControllerSessions)
        #expect(approved.supports(.screen))
        #expect(!approved.supports(.camera))

        let legacy = try JSONDecoder().decode(ControllerDevice.self, from: Data("""
        {
          "id": "legacy.ipad",
          "name": "Legacy iPad",
          "status": "approved",
          "online": true,
          "daemon_version": "0.3.3",
          "browser_version": "0.3.3",
          "protocol_major": 1,
          "protocol_minor": 0,
          "features": ["screen.webrtc", "camera.live"],
          "compatible": true
        }
        """.utf8))
        #expect(!legacy.supportsNativeControllerSessions)
        #expect(!legacy.supports(.screen))
        #expect(!legacy.supports(.camera))

        let pending = try JSONDecoder().decode(ControllerDevice.self, from: Data("""
        {
          "id": "pending",
          "name": "Pending iPad",
          "status": "pending",
          "online": false,
          "features": [],
          "compatible": true
        }
        """.utf8))
        #expect(throws: ControllerClientError.invalidResponse) {
            try pending.validated()
        }
    }

    @Test("Bearer tokens reject header injection and wrong kinds")
    func tokenValidation() throws {
        let key = try deterministicKey()
        #expect(throws: ControllerClientError.invalidToken) {
            try ControllerAPIClient().makeSignedRequest(
                origin: "https://relay.example",
                path: "/api/controller/me",
                method: "GET",
                token: "cat_example.secret\r\nInjected",
                body: Data(),
                signingKey: key,
                expectedTokenPrefix: "cat_"
            )
        }
        #expect(throws: ControllerClientError.invalidToken) {
            try ControllerAPIClient().makeSignedRequest(
                origin: "https://relay.example",
                path: "/api/controller/me",
                method: "GET",
                token: "crt_example.secret",
                body: Data(),
                signingKey: key,
                expectedTokenPrefix: "cat_"
            )
        }
    }

    @Test("Signed requests decode success and surface relay status codes", arguments: requestDelegations)
    func signedRequestStatus(_ delegation: RequestDelegation) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SignedRequestStatusStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ControllerAPIClient(session: session, delegation: delegation)
        let key = try deterministicKey()
        func info(_ scenario: String) async throws -> PairedController {
            try await client.controllerInfo(origin: "https://\(scenario).relay.example",
                accessToken: "cat_example.secret-value", signingKey: key)
        }

        #expect(try await info("ok") == PairedController(id: "ctl_example", name: "Owner phone",
            platform: "ios", scopes: [.screenView]))
        await #expect(throws: ControllerClientError.http(status: 401, code: "token_revoked")) {
            _ = try await info("revoked")
        }
        await #expect(throws: ControllerClientError.http(status: 503, code: "http_error")) {
            _ = try await info("unavailable")
        }
        await #expect(throws: ControllerClientError.invalidResponse) { _ = try await info("malformed") }
    }

    @Test("Decoded credentials reject malformed and stale server data")
    func responseValidation() throws {
        let controller = PairedController(
            id: "ctl_example",
            name: "Owner phone",
            platform: "ios",
            scopes: [.screenView]
        )
        #expect(try controller.validated() == controller)
        #expect(throws: ControllerClientError.invalidResponse) {
            try PairedController(
                id: "ctl_example",
                name: "Owner phone",
                platform: "ios",
                scopes: [.screenView, .screenView]
            ).validated()
        }

        let validTokens = try JSONDecoder().decode(ControllerTokenPair.self, from: Data("""
        {
          "access_token": "cat_example.access-secret",
          "access_expires_at": 1700000600,
          "refresh_token": "crt_example.refresh-secret",
          "refresh_expires_at": 1702592000
        }
        """.utf8))
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(try validTokens.validated(now: issuedAt) == validTokens)
        #expect(throws: ControllerClientError.invalidResponse) {
            try validTokens.validated(now: Date(timeIntervalSince1970: 1_800_000_000))
        }
    }

    private func pairing() throws -> ControllerPairingPayload {
        let data = Data("""
        {
          "v": 1,
          "origin": "https://relay.example",
          "pairing_id": "pair_abcdefghijklmnopqrstuvwxyz",
          "secret": "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
          "expires_at": 1700000300,
          "protocol_major": 1,
          "relay_id": "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"
        }
        """.utf8)
        return try JSONDecoder().decode(ControllerPairingPayload.self, from: data)
    }

    private func deterministicKey() throws -> ControllerSigningKey {
        var scalar = Data(repeating: 0, count: 32)
        scalar[31] = 1
        return try ControllerSigningKey(softwareRawRepresentation: scalar)
    }

    private func verifies(signature: Data, message: Data, key: ControllerSigningKey) throws -> Bool {
        let parsed = try P256.Signing.ECDSASignature(derRepresentation: signature)
        let publicKey = try P256.Signing.PublicKey(x963Representation: key.publicKeySPKIDER.suffix(65))
        return publicKey.isValidSignature(parsed, for: SHA256.hash(data: message))
    }
}

private final class SignedRequestStatusStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        guard request.value(forHTTPHeaderField: "X-RCTL-Signature")?.isEmpty == false,
              url.path == "/api/controller/me" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, body): (Int, String) = switch url.host!.split(separator: ".")[0] {
        case "ok": (200, #"{"controller":{"id":"ctl_example","name":"Owner phone","platform":"ios","scopes":["screen.view"]}}"#)
        case "revoked": (401, #"{"error":"token_revoked"}"#)
        case "unavailable": (503, "Service Unavailable")
        default: (200, #"{"controller":{}}"#)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct ClaimBody: Decodable {
    let relayID: String
    let secret: String
    let name: String
    let platform: String
    let publicKey: String
    let proof: String

    private enum CodingKeys: String, CodingKey {
        case relayID = "relay_id"
        case secret
        case name
        case platform
        case publicKey = "public_key"
        case proof
    }
}
