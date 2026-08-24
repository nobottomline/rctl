@preconcurrency import Foundation
@preconcurrency import LiveKitWebRTC
import RctlProtocol

public final class RctlRealtimeSession: NSObject, @unchecked Sendable {
    public typealias EventHandler = @Sendable (RctlRealtimeEvent) -> Void

    private static let acceptedChannels = Set(["control", "audio", "room-mic", "mic-in"])
    private static let maximumPendingCandidates = 256
    private static let maximumControlBufferedBytes: UInt64 = 64 * 1_024
    private static let connectionTimeout: TimeInterval = 15
    private static let disconnectGrace: TimeInterval = 5

    private let factory: RctlPeerConnectionFactory
    private let urlSession: URLSession
    private let eventHandler: EventHandler
    private let queue = DispatchQueue(label: "com.nobottomline.rctl.realtime.session")

    private var generation: UInt64 = 0
    private var running = false
    private var webSocket: URLSessionWebSocketTask?
    private var peerConnection: LKRTCPeerConnection?
    private var remoteDescriptionReady = false
    private var pendingCandidates: [LKRTCIceCandidate] = []
    private var channels: [String: LKRTCDataChannel] = [:]
    private var videoTrack: LKRTCVideoTrack?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var disconnectWorkItem: DispatchWorkItem?
#if canImport(UIKit)
    private weak var videoView: RctlRemoteVideoView?
#endif

    public init(
        factory: RctlPeerConnectionFactory = RctlPeerConnectionFactory(),
        urlSession: URLSession = .shared,
        eventHandler: @escaping EventHandler
    ) {
        self.factory = factory
        self.urlSession = urlSession
        self.eventHandler = eventHandler
        super.init()
    }

    deinit {
        stopResources()
    }

    public func start(with request: URLRequest) throws {
        try Self.validateWebSocketRequest(request)
        queue.async { [weak self] in
            self?.startLocked(with: request)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.stopLocked(emitClosed: true)
        }
    }

#if canImport(UIKit)
    @MainActor
    public func attachVideo(to view: RctlRemoteVideoView) {
        queue.async { [weak self, weak view] in
            guard let self, let view else { return }
            self.videoView = view
            let track = self.videoTrack
            DispatchQueue.main.async {
                view.setTrack(track)
            }
        }
    }

    @MainActor
    public func detachVideo() {
        queue.async { [weak self] in
            guard let self else { return }
            let view = self.videoView
            self.videoView = nil
            DispatchQueue.main.async {
                view?.setTrack(nil)
            }
        }
    }
#endif

    public func sendControl(_ message: ControlMessage) async throws {
        let data = try WireJSON.encode(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self,
                      let channel = self.channels["control"],
                      channel.readyState == .open else {
                    continuation.resume(throwing: RctlRealtimeError.controlChannelUnavailable)
                    return
                }
                guard channel.bufferedAmount <= Self.maximumControlBufferedBytes else {
                    continuation.resume(throwing: RctlRealtimeError.controlBackpressure)
                    return
                }
                let buffer = LKRTCDataBuffer(data: data, isBinary: false)
                if channel.sendData(buffer) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: RctlRealtimeError.controlChannelUnavailable)
                }
            }
        }
    }

    private func startLocked(with request: URLRequest) {
        guard !running else {
            emit(.failure(.alreadyRunning))
            return
        }
        generation &+= 1
        let currentGeneration = generation
        running = true
        remoteDescriptionReady = false
        pendingCandidates.removeAll(keepingCapacity: true)
        channels.removeAll(keepingCapacity: true)
        emit(.connection(.signaling))

        do {
            let delegate = self
            peerConnection = try factory.makePeerConnection(delegate: delegate)
        } catch let error as RctlRealtimeError {
            failLocked(error, generation: currentGeneration)
            return
        } catch {
            failLocked(.peerConnectionUnavailable, generation: currentGeneration)
            return
        }

        let task = urlSession.webSocketTask(with: request)
        webSocket = task
        task.resume()
        receiveNext(on: task, generation: currentGeneration)
        let timeout = DispatchWorkItem { [weak self] in
            self?.failLocked(
                .negotiationFailed("connection timed out"),
                generation: currentGeneration
            )
        }
        connectionTimeoutWorkItem = timeout
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout, execute: timeout)
    }

    private func receiveNext(on task: URLSessionWebSocketTask, generation currentGeneration: UInt64) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            self.queue.async {
                guard self.running, self.generation == currentGeneration, self.webSocket === task else { return }
                switch result {
                case let .success(message):
                    do {
                        let data: Data
                        switch message {
                        case let .string(value):
                            guard let encoded = value.data(using: .utf8) else {
                                throw RctlRealtimeError.invalidSignalingResponse
                            }
                            data = encoded
                        case let .data(value):
                            data = value
                        @unknown default:
                            throw RctlRealtimeError.invalidSignalingResponse
                        }
                        let signaling = try WireJSON.decode(SignalingMessage.self, from: data)
                        try self.handleSignalingLocked(signaling, generation: currentGeneration)
                        self.receiveNext(on: task, generation: currentGeneration)
                    } catch let error as RctlRealtimeError {
                        self.failLocked(error, generation: currentGeneration)
                    } catch {
                        self.failLocked(.invalidSignalingResponse, generation: currentGeneration)
                    }
                case let .failure(error):
                    self.failLocked(.signalingFailed(Self.safeMessage(error)), generation: currentGeneration)
                }
            }
        }
    }

    private func handleSignalingLocked(_ message: SignalingMessage, generation currentGeneration: UInt64) throws {
        guard let peerConnection else { throw RctlRealtimeError.peerConnectionUnavailable }
        switch message {
        case let .ready(servers):
            let configuration = peerConnection.configuration
            configuration.iceServers = try Self.makeIceServers(servers)
            guard peerConnection.setConfiguration(configuration) else {
                throw RctlRealtimeError.negotiationFailed("ICE configuration was rejected")
            }
        case let .offer(sdp):
            emit(.connection(.connecting))
            let description = LKRTCSessionDescription(type: .offer, sdp: sdp)
            peerConnection.setRemoteDescription(description) { [weak self] error in
                guard let session = self else { return }
                session.queue.async {
                    guard session.running, session.generation == currentGeneration else { return }
                    if let error {
                        session.failLocked(.negotiationFailed(Self.safeMessage(error)), generation: currentGeneration)
                        return
                    }
                    session.remoteDescriptionReady = true
                    session.flushPendingCandidatesLocked(generation: currentGeneration)
                    session.createAnswerLocked(generation: currentGeneration)
                }
            }
        case let .candidate(candidate, mid):
            let value = candidate.hasPrefix("a=") ? String(candidate.dropFirst(2)) : candidate
            let iceCandidate = LKRTCIceCandidate(sdp: value, sdpMLineIndex: 0, sdpMid: mid)
            if remoteDescriptionReady {
                addCandidateLocked(iceCandidate, generation: currentGeneration)
            } else {
                guard pendingCandidates.count < Self.maximumPendingCandidates else {
                    throw RctlRealtimeError.invalidSignalingResponse
                }
                pendingCandidates.append(iceCandidate)
            }
        case .answer:
            throw RctlRealtimeError.invalidSignalingResponse
        }
    }

    private func flushPendingCandidatesLocked(generation currentGeneration: UInt64) {
        let candidates = pendingCandidates
        pendingCandidates.removeAll(keepingCapacity: true)
        for candidate in candidates {
            addCandidateLocked(candidate, generation: currentGeneration)
        }
    }

    private func addCandidateLocked(_ candidate: LKRTCIceCandidate, generation currentGeneration: UInt64) {
        peerConnection?.add(candidate) { [weak self] error in
            guard let error else { return }
            guard let session = self else { return }
            session.queue.async {
                session.failLocked(.negotiationFailed(Self.safeMessage(error)), generation: currentGeneration)
            }
        }
    }

    private func createAnswerLocked(generation currentGeneration: UInt64) {
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection?.answer(for: constraints) { [weak self] description, error in
            guard let session = self else { return }
            session.queue.async {
                guard session.running, session.generation == currentGeneration else { return }
                guard let description, error == nil else {
                    session.failLocked(
                        .negotiationFailed(Self.safeMessage(error)),
                        generation: currentGeneration
                    )
                    return
                }
                session.peerConnection?.setLocalDescription(description) { [weak session] error in
                    guard let activeSession = session else { return }
                    activeSession.queue.async {
                        guard activeSession.running, activeSession.generation == currentGeneration else { return }
                        if let error {
                            activeSession.failLocked(
                                .negotiationFailed(Self.safeMessage(error)),
                                generation: currentGeneration
                            )
                            return
                        }
                        activeSession.sendSignalingLocked(
                            .answer(sdp: description.sdp),
                            generation: currentGeneration
                        )
                    }
                }
            }
        }
    }

    private func sendSignalingLocked(_ message: SignalingMessage, generation currentGeneration: UInt64) {
        do {
            let data = try WireJSON.encode(message)
            guard let value = String(data: data, encoding: .utf8), let webSocket else {
                throw RctlRealtimeError.invalidSignalingResponse
            }
            webSocket.send(.string(value)) { [weak self] error in
                guard let error else { return }
                guard let session = self else { return }
                session.queue.async {
                    session.failLocked(.signalingFailed(Self.safeMessage(error)), generation: currentGeneration)
                }
            }
        } catch let error as RctlRealtimeError {
            failLocked(error, generation: currentGeneration)
        } catch {
            failLocked(.invalidSignalingResponse, generation: currentGeneration)
        }
    }

    private func failLocked(_ error: RctlRealtimeError, generation currentGeneration: UInt64) {
        guard running, generation == currentGeneration else { return }
        emit(.failure(error))
        emit(.connection(.failed))
        stopLocked(emitClosed: false)
    }

    private func stopLocked(emitClosed: Bool) {
        guard running || peerConnection != nil || webSocket != nil else { return }
        generation &+= 1
        running = false
        stopResources()
        if emitClosed {
            emit(.connection(.closed))
        }
    }

    private func stopResources() {
        channels.values.forEach {
            $0.delegate = nil
            $0.close()
        }
        channels.removeAll(keepingCapacity: false)
        videoTrack = nil
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
        disconnectWorkItem?.cancel()
        disconnectWorkItem = nil
#if canImport(UIKit)
        let view = videoView
        DispatchQueue.main.async {
            view?.setTrack(nil)
        }
#endif
        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        pendingCandidates.removeAll(keepingCapacity: false)
        remoteDescriptionReady = false
    }

    private func emit(_ event: RctlRealtimeEvent) {
        let eventHandler = eventHandler
        DispatchQueue.main.async {
            eventHandler(event)
        }
    }

    private static func safeMessage(_ error: Error?) -> String {
        guard let error else { return "unknown error" }
        let message = (error as NSError).localizedDescription
        return String(message.prefix(256))
    }

    static func validateWebSocketRequest(_ request: URLRequest) throws {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              request.httpMethod == nil || request.httpMethod == "GET",
              request.httpBody == nil else {
            throw RctlRealtimeError.invalidSignalingResponse
        }
        if components.scheme == "wss" {
            return
        }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard components.scheme == "ws", loopback else {
            throw RctlRealtimeError.invalidSignalingResponse
        }
    }

    private static func makeIceServers(_ servers: [WireICEServer]) throws -> [LKRTCIceServer] {
        try servers.map { server in
            for value in server.urls {
                guard let scheme = URLComponents(string: value)?.scheme?.lowercased(),
                      ["stun", "stuns", "turn", "turns"].contains(scheme) else {
                    throw RctlRealtimeError.invalidSignalingResponse
                }
            }
            return LKRTCIceServer(
                urlStrings: server.urls,
                username: server.username ?? "",
                credential: server.credential ?? ""
            )
        }
    }
}

extension RctlRealtimeSession: LKRTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {
        guard let track = stream.videoTracks.first else { return }
        queue.async { [weak self] in
            self?.adoptVideoTrackLocked(track)
        }
    }

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}

    public func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.sendSignalingLocked(
                .candidate(candidate: candidate.sdp, mid: candidate.sdpMid ?? "0"),
                generation: self.generation
            )
        }
    }

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        queue.async { [weak self] in
            guard let self, self.running else {
                dataChannel.close()
                return
            }
            guard Self.acceptedChannels.contains(dataChannel.label), self.channels[dataChannel.label] == nil else {
                dataChannel.close()
                return
            }
            self.channels[dataChannel.label] = dataChannel
            dataChannel.delegate = self
            self.emit(.channel(label: dataChannel.label, state: Self.channelState(dataChannel.readyState)))
        }
    }

    public func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didAdd rtpReceiver: LKRTCRtpReceiver,
        streams mediaStreams: [LKRTCMediaStream]
    ) {
        guard let track = rtpReceiver.track as? LKRTCVideoTrack else { return }
        queue.async { [weak self] in
            self?.adoptVideoTrackLocked(track)
        }
    }

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            switch newState {
            case .new:
                self.emit(.connection(.connecting))
            case .connecting:
                self.emit(.connection(.connecting))
            case .connected:
                self.connectionTimeoutWorkItem?.cancel()
                self.connectionTimeoutWorkItem = nil
                self.disconnectWorkItem?.cancel()
                self.disconnectWorkItem = nil
                self.emit(.connection(.connected))
            case .disconnected:
                self.emit(.connection(.disconnected))
                if self.disconnectWorkItem == nil {
                    let generation = self.generation
                    let timeout = DispatchWorkItem { [weak self] in
                        self?.failLocked(
                            .negotiationFailed("peer connection remained disconnected"),
                            generation: generation
                        )
                    }
                    self.disconnectWorkItem = timeout
                    self.queue.asyncAfter(deadline: .now() + Self.disconnectGrace, execute: timeout)
                }
            case .failed:
                self.failLocked(.negotiationFailed("peer connection failed"), generation: self.generation)
            case .closed:
                self.stopLocked(emitClosed: true)
            @unknown default:
                self.failLocked(.negotiationFailed("unknown peer connection state"), generation: self.generation)
            }
        }
    }

    private func adoptVideoTrackLocked(_ track: LKRTCVideoTrack) {
        guard running, videoTrack?.trackId != track.trackId else { return }
        videoTrack = track
#if canImport(UIKit)
        let view = videoView
        DispatchQueue.main.async {
            view?.setTrack(track)
        }
#endif
        emit(.videoTrackAvailable)
    }
}

extension RctlRealtimeSession: LKRTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        queue.async { [weak self] in
            guard let self, self.channels[dataChannel.label] === dataChannel else { return }
            self.emit(.channel(label: dataChannel.label, state: Self.channelState(dataChannel.readyState)))
            if dataChannel.readyState == .closed {
                dataChannel.delegate = nil
                self.channels.removeValue(forKey: dataChannel.label)
            }
        }
    }

    public func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        // Media and file payloads get dedicated bounded consumers. The base
        // session intentionally does not copy or queue them on the UI thread.
    }

    private static func channelState(_ state: LKRTCDataChannelState) -> RctlRealtimeChannelState {
        switch state {
        case .connecting: .connecting
        case .open: .open
        case .closing: .closing
        case .closed: .closed
        @unknown default: .closed
        }
    }
}
