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

    @Test("Log messages keep their text and redact every value not marked public")
    func logPrivacy() {
        let literal: RealtimeLog.Message = "First remote video frame decoded"
        #expect(literal.publicText == "First remote video frame decoded" && literal.privateText == nil)

        let kind = "negotiation"
        let marked: RealtimeLog.Message = "Realtime session failed: \(kind, privacy: .public)"
        #expect(marked.publicText == "Realtime session failed: negotiation" && marked.privateText == nil)

        let width: Int32 = 1920
        let unmarked: RealtimeLog.Message = "Presented first Metal frame: \(width)x\(1080) rotation=\(90, privacy: .public)"
        #expect(unmarked.publicText == "Presented first Metal frame: ")
        #expect(unmarked.privateText == "1920x1080 rotation=90")
    }

    private func request(_ value: String) -> URLRequest {
        URLRequest(url: URL(string: value)!)
    }
}
