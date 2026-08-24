import Foundation
import Testing
@testable import RctlClient

@Suite("Live Go relay interoperability", .serialized)
struct LiveRelayInteropTests {
    @Test("Swift claim, signed request, and refresh recovery match Go")
    func roundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let origin = environment["RCTL_CONTROLLER_TEST_ORIGIN"],
              let adminSecret = environment["RCTL_CONTROLLER_TEST_ADMIN_SECRET"] else {
            return
        }

        let admin = URLSession(configuration: .ephemeral)
        let login = try await adminRequest(
            admin,
            origin: origin,
            path: "/api/admin/login",
            body: ["secret": adminSecret]
        )
        let setCookie = try #require(login.response.value(forHTTPHeaderField: "Set-Cookie"))
        let adminCookie = try #require(setCookie.split(separator: ";").first.map(String.init))

        let pairingResponse = try await adminRequest(
            admin,
            origin: origin,
            path: "/api/admin/controller-pairings",
            body: [
                "name": "Swift interop",
                "scopes": ["screen.view", "device.control"],
                "ttl_seconds": 120,
            ] as [String: Any],
            cookie: adminCookie
        )
        let pairingData = try JSONSerialization.data(
            withJSONObject: try #require(
                (try JSONSerialization.jsonObject(with: pairingResponse.data) as? [String: Any])?["pairing"]
            )
        )
        let client = ControllerAPIClient(session: URLSession(configuration: .ephemeral))
        let pairing = try client.decodePairing(
            from: pairingData,
            allowInsecureLoopback: true
        )
        let key = try ControllerSigningKey.generate(preferSecureEnclave: false)
        let claim = try await client.claim(
            pairing: pairing,
            controllerName: "Swift interop",
            signingKey: key,
            allowInsecureLoopback: true
        )

        let beforeRefresh = try await client.controllerInfo(
            origin: pairing.origin,
            accessToken: claim.tokens.accessToken,
            signingKey: key,
            allowInsecureLoopback: true
        )
        #expect(beforeRefresh.id == claim.controller.id)

        let refreshed = try await client.refresh(
            origin: pairing.origin,
            refreshToken: claim.tokens.refreshToken,
            signingKey: key,
            allowInsecureLoopback: true
        )
        #expect(refreshed.refreshToken == claim.tokens.refreshToken)
        let recovered = try await client.refresh(
            origin: pairing.origin,
            refreshToken: claim.tokens.refreshToken,
            signingKey: key,
            allowInsecureLoopback: true
        )
        #expect(recovered.refreshToken == claim.tokens.refreshToken)
        let afterRefresh = try await client.controllerInfo(
            origin: pairing.origin,
            accessToken: recovered.accessToken,
            signingKey: key,
            allowInsecureLoopback: true
        )
        #expect(afterRefresh.id == claim.controller.id)

        _ = try await adminRequest(
            admin,
            origin: origin,
            path: "/api/admin/controllers/\(claim.controller.id)/revoke",
            body: [:],
            cookie: adminCookie
        )
    }

    private func adminRequest(
        _ session: URLSession,
        origin: String,
        path: String,
        body: [String: Any],
        cookie: String? = nil
    ) async throws -> AdminResponse {
        let data = try JSONSerialization.data(withJSONObject: body)
        let url = try #require(URL(string: origin + path))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (responseData, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        guard (200..<300).contains(http.statusCode) else {
            throw LiveError.http(http.statusCode, String(decoding: responseData, as: UTF8.self))
        }
        return AdminResponse(data: responseData, response: http)
    }

    private enum LiveError: Error {
        case http(Int, String)
    }

    private struct AdminResponse {
        let data: Data
        let response: HTTPURLResponse
    }
}
