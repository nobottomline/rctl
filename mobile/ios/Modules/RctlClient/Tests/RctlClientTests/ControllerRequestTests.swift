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
        #expect(claim.publicKey == key.publicKeySPKIDER.base64URLEncodedString)

        let message = [
            "rctl-pair-v1",
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

private struct ClaimBody: Decodable {
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
