import Foundation
import Testing
import RctlProtocol
@testable import RctlRealtime

@Suite("Local connection boundary", .serialized)
struct LocalConnectionTests {
    @Test("Private addresses normalize without admitting other destinations")
    func addresses() throws {
        #expect(try LocalDeviceAddress(" 192.168.2.3 ").displayAddress == "192.168.2.3:8080")
        #expect(try LocalDeviceAddress("http://10.0.0.4:9000/").displayAddress == "10.0.0.4:9000")
        #expect(try LocalDeviceAddress("[FD01:0:0::5]:8081").displayAddress == "[fd01::5]:8081")
        for value in ["", "example.com", "https://192.168.2.3", "8.8.8.8", "127.0.0.1", "0.0.0.0",
                      "169.254.1.1", "172.15.1.1", "172.32.1.1", "224.0.0.1", "255.255.255.255",
                      "192.168.2.3:0", "192.168.2.3:65536", "192.168.2.3:abc", "192.168.002.3",
                      "192.168.2.3:", "http://192.168.2.3:/",
                      "[::1]", "[::ffff:192.168.2.3]", "[fe80::1]", "[fe80::1%25en0]", "[2001:db8::1]",
                      "user:secret@192.168.2.3", "192.168.2.3/foo", "192.168.2.3?token=x", "192.168.2.3#x"] {
            #expect(throws: LocalConnectionError.invalidAddress, "Rejected address: \(value)") { try LocalDeviceAddress(value) }
        }
        let encoded = try JSONEncoder().encode(LocalDeviceAddress("192.168.2.3"))
        #expect(try JSONDecoder().decode(LocalDeviceAddress.self, from: encoded) == LocalDeviceAddress("192.168.2.3"))
        #expect(throws: LocalConnectionError.invalidAddress) {
            try JSONDecoder().decode(LocalDeviceAddress.self, from: Data(#""http://public.example""#.utf8))
        }
    }

    @Test("LAN is explicit, exact-target, and credential-free")
    func signalingPolicy() throws {
        let address = try LocalDeviceAddress("192.168.2.3")
        for camera in [false, true] {
            let request = address.signalingRequest(camera: camera)
            try RctlRealtimeSession.validateWebSocketRequest(request, localAddress: address)
            #expect(throws: RctlRealtimeError.invalidSignalingResponse) {
                try RctlRealtimeSession.validateWebSocketRequest(request)
            }
        }
        var request = address.signalingRequest()
        request.setValue("sensitive", forHTTPHeaderField: "Authorization")
        #expect(throws: RctlRealtimeError.invalidSignalingResponse) {
            try RctlRealtimeSession.validateWebSocketRequest(request, localAddress: address)
        }
        let other = try LocalDeviceAddress("192.168.2.4")
        #expect(throws: RctlRealtimeError.invalidSignalingResponse) {
            try RctlRealtimeSession.validateWebSocketRequest(other.signalingRequest(), localAddress: address)
        }
        var cookies = address.signalingRequest()
        cookies.httpShouldHandleCookies = true
        #expect(throws: RctlRealtimeError.invalidSignalingResponse) {
            try RctlRealtimeSession.validateWebSocketRequest(cookies, localAddress: address)
        }
    }

    @Test("Local URLSession drops shared headers and storage")
    func isolatedSession() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["Authorization": "sensitive", "Cookie": "sensitive"]
        let session = LocalNetworkSession.make(configuration: config)
        defer { session.invalidateAndCancel() }
        #expect(session.configuration.httpAdditionalHeaders?.isEmpty != false)
        #expect(session.configuration.httpCookieStorage == nil)
        #expect(session.configuration.urlCredentialStorage == nil)
        #expect(session.configuration.urlCache == nil)
        #expect(!session.configuration.httpShouldSetCookies)
    }

    @Test("LAN cannot opt into external ICE servers")
    func localICE() throws {
        #expect(try RctlRealtimeSession.makeIceServers([], local: true).isEmpty)
        let servers = try JSONDecoder().decode([WireICEServer].self,
            from: Data(#"[{"urls":["stun:example.com:3478"]}]"#.utf8))
        #expect(throws: RctlRealtimeError.invalidSignalingResponse) {
            try RctlRealtimeSession.makeIceServers(servers, local: true)
        }
        #expect(try RctlRealtimeSession.makeIceServers(servers).count == 1)
    }

    @Test("Local session delegate refuses a redirect")
    func redirectPolicy() async throws {
        let session = LocalNetworkSession.make()
        defer { session.invalidateAndCancel() }
        let source = try LocalDeviceAddress("192.168.2.3").capabilitiesURL
        let response = try #require(HTTPURLResponse(url: source, statusCode: 302,
            httpVersion: nil, headerFields: ["Location": "https://example.com"]))
        let delegate = try #require(session.delegate as? URLSessionTaskDelegate)
        let task = session.dataTask(with: source)
        defer { task.cancel() }
        let destination: URLRequest? = await withCheckedContinuation { continuation in
            delegate.urlSession?(session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: URL(string: "https://example.com")!)) { continuation.resume(returning: $0) }
        }
        #expect(destination == nil)
    }

    /// The macOS test host supports task delegates, so the pre-iOS 15 dedicated
    /// session path runs only when a test selects it explicitly.
    static let delegations: [RequestDelegation] = [.taskDelegate, .dedicatedSession]

    @Test("LAN capabilities decode on both delegate paths", arguments: delegations)
    func capabilities(_ delegation: RequestDelegation) async throws {
        let client = LocalDeviceClient(configuration: stubConfiguration(), delegation: delegation)
        let capabilities = try await client.capabilities(at: LocalDeviceAddress("192.168.2.3:\(CapabilitiesScenario.valid.rawValue)"))
        #expect(capabilities.component == "daemon")
        #expect(capabilities.features.contains("screen.webrtc"))
        await #expect(throws: LocalConnectionError.unsupportedMedia) {
            _ = try await client.capabilities(at: LocalDeviceAddress("192.168.2.3:\(CapabilitiesScenario.valid.rawValue)"), camera: true)
        }
    }

    @Test("LAN capabilities reject unsafe responses on both delegate paths",
          arguments: CapabilitiesScenario.failures, delegations)
    func capabilityFailures(_ scenario: CapabilitiesScenario, _ delegation: RequestDelegation) async throws {
        let client = LocalDeviceClient(configuration: stubConfiguration(), delegation: delegation)
        let address = try LocalDeviceAddress("192.168.2.3:\(scenario.rawValue)")
        await #expect(throws: scenario.expected) { _ = try await client.capabilities(at: address) }
    }

    @Test("LAN capabilities cancellation aborts a stalled request", arguments: delegations)
    func capabilityCancellation(_ delegation: RequestDelegation) async throws {
        let client = LocalDeviceClient(configuration: stubConfiguration(), delegation: delegation)
        let address = try LocalDeviceAddress("192.168.2.3:\(CapabilitiesScenario.silent.rawValue)")
        let task = Task { try await client.capabilities(at: address) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    /// A dedicated session retains its delegate until invalidated, so a request
    /// that outlives its terminal path would leak the session and its delegate.
    @Test("LAN capabilities request is released after every terminal path",
          arguments: TerminalPath.allCases, delegations)
    func capabilityRequestRelease(_ path: TerminalPath, _ delegation: RequestDelegation) async throws {
        let session = LocalNetworkSession.make(configuration: stubConfiguration())
        defer { session.invalidateAndCancel() }
        let reference = try await finishCapabilities(path, session: session, delegation: delegation)
        let deadline = Date().addingTimeInterval(5)
        while reference.value != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reference.value == nil)
    }

    enum TerminalPath: CaseIterable, Sendable {
        case success, failure, cancelBeforeStart, cancelAfterStart
    }

    enum CapabilitiesScenario: Int, Sendable {
        case valid = 8080, declaredOversize, chunkedOversize, redirectStatus, followedRedirect, unavailable, wrongComponent, silent

        static let failures: [Self] = [.declaredOversize, .chunkedOversize, .redirectStatus, .followedRedirect,
                                       .unavailable, .wrongComponent]

        var expected: LocalConnectionError {
            switch self {
            case .declaredOversize, .chunkedOversize: .responseTooLarge
            case .redirectStatus, .followedRedirect: .redirect
            case .unavailable: .http(503)
            case .valid, .wrongComponent, .silent: .invalidResponse
            }
        }
    }

    private func finishCapabilities(_ path: TerminalPath, session: URLSession,
                                    delegation: RequestDelegation) async throws -> WeakRequest {
        let scenario: CapabilitiesScenario = switch path {
        case .success: .valid
        case .failure: .declaredOversize
        case .cancelBeforeStart, .cancelAfterStart: .silent
        }
        let address = try LocalDeviceAddress("192.168.2.3:\(scenario.rawValue)")
        let operation = LocalCapabilitiesRequest(session: session, address: address, delegation: delegation)
        let reference = WeakRequest(operation)
        if path == .cancelBeforeStart { operation.cancel() }
        let run = Task {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { operation.start($0) }
            } onCancel: { operation.cancel() }
        }
        if path == .cancelAfterStart {
            try await Task.sleep(for: .milliseconds(20))
            run.cancel()
        }
        let result = await run.result
        switch path {
        case .success: #expect((try? result.get()) != nil)
        case .failure: #expect(throws: LocalConnectionError.responseTooLarge) { try result.get() }
        case .cancelBeforeStart, .cancelAfterStart: #expect(throws: CancellationError.self) { try result.get() }
        }
        return reference
    }

    private func stubConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CapabilitiesStub.self]
        return configuration
    }
}

private final class WeakRequest: @unchecked Sendable {
    weak var value: LocalCapabilitiesRequest?
    init(_ value: LocalCapabilitiesRequest) { self.value = value }
}

private final class CapabilitiesStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        guard let scenario = url.port.flatMap(LocalConnectionTests.CapabilitiesScenario.init(rawValue:)),
              scenario != .silent else { return }
        let daemon = #"{"product":"rctl","component":"daemon","daemon":{"version":"0.3.3"},"browser":{"version":"0.3.3"},"protocol":{"major":1,"minor":1},"features":["screen.webrtc"]}"#
        let relay = #"{"product":"rctl","component":"relay","relay":{"version":"0.3.3"},"protocol":{"major":1,"minor":1},"features":["screen.webrtc"]}"#
        var headers = ["Content-Type": "application/json"]
        switch scenario {
        case .followedRedirect:
            var target = URLRequest(url: URL(string: "http://192.168.2.4:8080/v1/capabilities")!)
            target.httpShouldHandleCookies = false
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                headerFields: ["Location": target.url!.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: target, redirectResponse: response)
            return
        case .declaredOversize:
            headers["Content-Length"] = String(64 * 1024 + 1)
        default: break
        }
        let status = switch scenario {
        case .redirectStatus: 302
        case .unavailable: 503
        default: 200
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        switch scenario {
        case .declaredOversize:
            // Keep the transfer unfinished: rejection must not depend on EOF.
            client?.urlProtocol(self, didLoad: Data([0]))
        case .chunkedOversize:
            client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: 64 * 1024))
            client?.urlProtocol(self, didLoad: Data([0x20]))
        default:
            client?.urlProtocol(self, didLoad: Data((scenario == .wrongComponent ? relay : daemon).utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
