import Foundation
@preconcurrency import LiveKitWebRTC
@preconcurrency import Network
import Testing
@testable import RctlRealtime

@Suite("Realtime lifecycle", .serialized)
@MainActor
struct RealtimeLifecycleTests {
    @Test("A new lifecycle discards already queued UI events")
    func staleUIEvents() async {
        var events: [RctlRealtimeEvent] = []
        let delivery = RealtimeEventDelivery { events.append($0) }
        let previous = delivery.advance()
        delivery.emit(.channel(label: "control", state: .open), revision: previous)
        let current = delivery.advance()
        delivery.emit(.connection(.closed), revision: previous)
        delivery.emit(.connection(.signaling), revision: current)
        await drainMainQueue()
        #expect(events == [.connection(.signaling)])
        delivery.emit(.failure(.signalingClosed), revision: current)
        delivery.emit(.connection(.failed), revision: current)
        await drainMainQueue()
        #expect(events.suffix(2) == [.failure(.signalingClosed), .connection(.failed)])
    }

    @Test("Foreign peer callbacks cannot close or populate a running session")
    func foreignPeerCallbacks() async throws {
        let server = try IdleSignalingServer()
        defer { server.stop() }
        let url = try await server.start()
        var events: [RctlRealtimeEvent] = []
        let session = RctlRealtimeSession { events.append($0) }
        defer { session.stop() }
        try session.start(with: URLRequest(url: url))
        try await waitUntil { events.contains(.connection(.signaling)) }

        let foreign = try RctlPeerConnectionFactory().makePeerConnection(delegate: session)
        defer { foreign.close() }
        let channel = try #require(foreign.dataChannel(forLabel: "control", configuration: LKRTCDataChannelConfiguration()))
        session.peerConnection(foreign, didOpen: channel)
        session.peerConnection(foreign, didGenerate: LKRTCIceCandidate(sdp: "candidate:test", sdpMLineIndex: 0, sdpMid: "0"))
        session.peerConnection(foreign, didChange: LKRTCPeerConnectionState.connected)
        session.peerConnection(foreign, didChange: LKRTCPeerConnectionState.failed)
        session.peerConnection(foreign, didChange: LKRTCPeerConnectionState.closed)
        // sendControl traverses the same serial queue, providing a barrier
        // after the callbacks without invalidating their pending UI events.
        try? await session.sendControl(.key(page: 7, usage: 4, down: false))
        await drainMainQueue()
        #expect(!events.contains { if case .channel = $0 { true } else { false } })
        #expect(!events.contains { if case .failure = $0 { true } else { false } })
        #expect(!events.contains(.connection(.connected)))
        #expect(!events.contains(.connection(.closed)))
        session.stop()
        try await waitUntil { events.contains(.connection(.closed)) }
    }

    @Test("Stopping an idle session still acknowledges closure")
    func idleStop() async throws {
        var events: [RctlRealtimeEvent] = []
        let session = RctlRealtimeSession { events.append($0) }
        session.stop()
        try await waitUntil { events.contains(.connection(.closed)) }
    }

    @Test("Silent replacement cleanup does not overwrite app authorization state")
    func silentStop() async {
        var events: [RctlRealtimeEvent] = []
        let session = RctlRealtimeSession { events.append($0) }
        session.stop(notify: false)
        try? await session.sendControl(.key(page: 7, usage: 4, down: false))
        await drainMainQueue()
        #expect(events.isEmpty)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

/// No external relay or device is contacted; Network.framework performs the
/// WebSocket handshake and holds the connection until the test stops it.
private final class IdleSignalingServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "rctl.tests.signaling")
    private var connections: [NWConnection] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "ws://127.0.0.1:\(listener.port!.rawValue)/ws/signal")!)
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connections.append(connection)
                connection.start(queue: queue)
                connection.receiveMessage { _, _, _, _ in }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}
