import Foundation
import Testing
@testable import RctlRealtime

@Suite("Realtime session boundary")
struct RealtimeSessionTests {
    @Test("Signaling permits TLS and explicit loopback plaintext only")
    func signalingOriginValidation() throws {
        try RctlRealtimeSession.validateWebSocketRequest(request("wss://relay.example/api/controller/devices/ipad/signal"))
        try RctlRealtimeSession.validateWebSocketRequest(request("ws://127.0.0.1:8080/ws/signal"))

        #expect(throws: RctlRealtimeError.invalidSignalingResponse) {
            try RctlRealtimeSession.validateWebSocketRequest(request("ws://relay.example/ws/signal"))
        }
        #expect(throws: RctlRealtimeError.invalidSignalingResponse) {
            var value = request("wss://relay.example/signal")
            value.httpMethod = "POST"
            try RctlRealtimeSession.validateWebSocketRequest(value)
        }
        #expect(throws: RctlRealtimeError.invalidSignalingResponse) {
            try RctlRealtimeSession.validateWebSocketRequest(request("https://relay.example/signal"))
        }
    }

    private func request(_ value: String) -> URLRequest {
        URLRequest(url: URL(string: value)!)
    }
}
