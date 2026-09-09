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
}
