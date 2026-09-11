import Foundation
import Testing
@testable import RctlClient

@Suite("Controller pairing identity")
struct ControllerPairingIdentityTests {
    @Test(arguments: ["match", "different", "missing", "numeric", "empty"])
    func validatesClaimResponseIdentity(_ scenario: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingIdentityResponse.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ControllerAPIClient(session: session)
        let pairing = try client.decodePairing(from: payload(scenario: scenario))
        let key = try ControllerSigningKey.generate(preferSecureEnclave: false)
        if scenario == "match" {
            let claim = try await client.claim(pairing: pairing, controllerName: "Test", signingKey: key)
            #expect(claim.relayID == pairing.relayID)
            #expect(ControllerRefreshCredential(pairing: pairing, claim: claim).relayID == pairing.relayID)
        } else {
            let expected: ControllerClientError = ["different", "empty"].contains(scenario)
                ? .relayIdentityMismatch : .invalidResponse
            await #expect(throws: expected) {
                _ = try await client.claim(pairing: pairing, controllerName: "Test", signingKey: key)
            }
        }
    }

    @Test func rejectsNonStringQRIdentity() throws {
        var fields = try #require(JSONSerialization.jsonObject(with: payload(scenario: "match")) as? [String: Any])
        fields["relay_id"] = 7
        let bytes = try JSONSerialization.data(withJSONObject: fields)
        #expect(throws: (any Error).self) { _ = try ControllerAPIClient().decodePairing(from: bytes) }
    }

    @Test func acceptsCanonicalOriginWithTrailingSlash() throws {
        let client = ControllerAPIClient()
        let first = try client.decodePairing(from: payload(scenario: "match"))
        let second = try client.decodePairing(from: payload(scenario: "match", trailingSlash: true))
        let key = try ControllerSigningKey.generate(preferSecureEnclave: false)
        for pairing in [first, second] {
            let request = try client.makeClaimRequest(pairing: pairing, controllerName: "Test", signingKey: key,
                now: Date(), allowInsecureLoopback: false)
            #expect(request.url?.absoluteString == "https://match.relay.example/api/controller/pairings/pair_fixture/claim")
        }
    }

    private func payload(scenario: String, trailingSlash: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "v": 1, "origin": "https://\(scenario).relay.example" + (trailingSlash ? "/" : ""),
            "pairing_id": "pair_fixture", "secret": String(repeating: "s", count: 43),
            "expires_at": Int64(Date().timeIntervalSince1970) + 300, "protocol_major": 1,
            "relay_id": String(repeating: "r", count: 43),
        ])
    }
}

private final class PairingIdentityResponse: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            let url = request.url!
            let scenario = url.host!.split(separator: ".")[0]
            let now = Int64(Date().timeIntervalSince1970)
            var result: [String: Any] = [
                "controller": ["id": "ctl_fixture", "name": "Test", "platform": "ios", "scopes": ["screen.view"]],
                "tokens": ["access_token": "cat_fixture.secret", "access_expires_at": now + 300,
                           "refresh_token": "crt_fixture.secret", "refresh_expires_at": now + 3600],
            ]
            switch scenario {
            case "match": result["relay_id"] = String(repeating: "r", count: 43)
            case "different": result["relay_id"] = String(repeating: "7", count: 43)
            case "numeric": result["relay_id"] = 7
            case "empty": result["relay_id"] = ""
            default: break
            }
            let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: result))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}
