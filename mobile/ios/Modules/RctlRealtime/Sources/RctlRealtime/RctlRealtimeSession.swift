@preconcurrency import Foundation
@preconcurrency import LiveKitWebRTC
import OSLog
import RctlProtocol

public final class RctlRealtimeSession: NSObject, @unchecked Sendable {
    public typealias EventHandler = @MainActor @Sendable (RctlRealtimeEvent) -> Void

    private static let acceptedChannels = Set(["control", "audio", "room-mic", "mic-in", "state"])
    private static let maximumPendingCandidates = 256
    private static let maximumControlBufferedBytes: UInt64 = 64 * 1_024
    private static let connectionTimeout: TimeInterval = 15
    private static let disconnectGrace: TimeInterval = 5
    private static let logger = Logger(subsystem: "com.greatlove.rctl.controller", category: "WebRTC")

    private let factory: RctlPeerConnectionFactory
    private let urlSession: URLSession
    private let localURLSession = LocalNetworkSession.make()
    private let eventDelivery: RealtimeEventDelivery
    private let queue = DispatchQueue(label: "com.greatlove.rctl.realtime.session")
    private let controlBuffer = RealtimeControlBuffer()
    private var controlTimer: DispatchSourceTimer?
    private var pressedControl = PressedControlState()

    private var generation: UInt64 = 0
    private var eventRevision: UInt64 = 0
    private var running = false
    private var localConnection = false
    private var webSocket: URLSessionWebSocketTask?
    private var peerConnection: LKRTCPeerConnection?
    private var readyReceived = false
    private var remoteDescriptionReady = false
    private var pendingCandidates: [LKRTCIceCandidate] = []
    private var localCandidateCount = 0
    private var remoteCandidateCount = 0
    private var iceConnectionState = "new"
    private var iceGatheringState = "new"
    private var channels: [String: LKRTCDataChannel] = [:]
    private var videoTrack: LKRTCVideoTrack?
    private var firstVideoFrameReceived = false
    private var orientation: Int?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var disconnectWorkItem: DispatchWorkItem?
    private var monitorTimer: DispatchSourceTimer?
    private var freshness = VideoFreshness()
    private var videoHealth: RctlVideoHealth = .waiting
    private var connectedAt: TimeInterval?
    private var statistics = VideoStatisticsAccumulator()
    private var statisticsPending = false
    private var lastStatisticsAt: TimeInterval = 0
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
        self.eventDelivery = RealtimeEventDelivery(handler: eventHandler)
        super.init()
    }

    deinit {
        stopResources()
        localURLSession.invalidateAndCancel()
    }

    public func start(with request: URLRequest, localAddress: LocalDeviceAddress? = nil) throws {
        try Self.validateWebSocketRequest(request, localAddress: localAddress)
        eventDelivery.advance { revision in
            queue.async { [weak self] in
                guard let self, self.eventDelivery.isCurrent(revision) else { return }
                self.eventRevision = revision
                self.startLocked(with: request, local: localAddress != nil)
            }
        }
    }

    public func stop(notify: Bool = true) {
        controlBuffer.reset(open: false)
        eventDelivery.advance { revision in
            queue.async { [weak self] in
                guard let self else { return }
                self.eventRevision = revision
                self.stopLocked(emitClosed: false)
                if notify { self.emit(.connection(.closed)) }
            }
        }
    }

#if canImport(UIKit)
    @MainActor
    public func attachVideo(to view: RctlRemoteVideoView) {
        queue.async { [weak self, weak view] in
            guard let self, let view else { return }
            let previousView = self.videoView
            self.videoView = view
            let track = self.videoTrack
            let trackID = track?.trackId
            let orientation = self.orientation
            let generation = self.generation
            DispatchQueue.main.async {
                if previousView !== view {
                    previousView?.setTrack(nil)
                }
                view.setDeviceOrientation(orientation)
                view.setTrack(track) { [weak self] timestamp in
                    self?.queue.async {
                        self?.handleVideoFrameLocked(at: timestamp, generation: generation, trackID: trackID)
                    }
                }
            }
        }
    }

    @MainActor
    public func detachVideo(from view: RctlRemoteVideoView) {
        queue.async { [weak self, weak view] in
            guard let self else { return }
            guard let view, self.videoView === view else { return }
            self.videoView = nil
            DispatchQueue.main.async {
                view.setTrack(nil)
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
                guard channel.bufferedAmount + UInt64(data.count) <= Self.maximumControlBufferedBytes else {
                    continuation.resume(throwing: RctlRealtimeError.controlBackpressure)
                    return
                }
                let buffer = LKRTCDataBuffer(data: data, isBinary: false)
                if channel.sendData(buffer) {
                    self.pressedControl.sent(message)
                    continuation.resume()
                } else {
                    continuation.resume(throwing: RctlRealtimeError.controlChannelUnavailable)
                }
            }
        }
    }

    @discardableResult
    public func enqueueControl(_ message: ControlMessage, after delay: TimeInterval = 0) -> Bool {
        enqueueControl(message, after: delay, cancellableKeyboardInput: false)
    }

    @discardableResult
    public func enqueueKeyboardControl(_ message: ControlMessage, after delay: TimeInterval = 0) -> Bool {
        enqueueControl(message, after: delay, cancellableKeyboardInput: true)
    }

    @discardableResult
    public func enqueueKeyboardControls(_ messages: [ScheduledControlMessage]) -> Bool {
        guard controlBuffer.append(messages, keyboard: true) else { return false }
        scheduleControlDrain()
        return true
    }

    private func enqueueControl(
        _ message: ControlMessage,
        after delay: TimeInterval,
        cancellableKeyboardInput: Bool
    ) -> Bool {
        guard controlBuffer.append(message, delay: delay, keyboard: cancellableKeyboardInput) else { return false }
        scheduleControlDrain()
        return true
    }

    private func scheduleControlDrain() {
        guard let revision = controlBuffer.scheduleDrain() else { return }
        queue.async { [weak self] in
            guard let self, self.controlBuffer.beginDrain(revision) else { return }
            self.drainControlLocked(revision: revision)
        }
    }

    private func drainControlLocked(revision: UInt64) {
        guard running, controlBuffer.isCurrent(revision) else { return }
        controlTimer?.cancel()
        controlTimer = nil
        for entry in controlBuffer.takeDue(now: ProcessInfo.processInfo.systemUptime, revision: revision) {
            guard controlBuffer.isCurrent(entry) else { continue }
            do {
                try transmitControlLocked(entry.message, data: entry.data)
            } catch let error as RctlRealtimeError {
                // Only intermediate touch motion is lossy. Dropping a down/up
                // silently can leave the remote device in a pressed state.
                if case .touch(1, _, _, _) = entry.message, error == .controlBackpressure { continue }
                failLocked(error, generation: generation)
                return
            } catch {
                failLocked(.controlChannelUnavailable, generation: generation)
                return
            }
        }
        if let deadline = controlBuffer.nextDeadline {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime))
            timer.setEventHandler { [weak self] in self?.drainControlLocked(revision: revision) }
            controlTimer = timer
            timer.resume()
        }
    }

    private func transmitControlLocked(_ message: ControlMessage, data: Data? = nil) throws {
        guard let channel = channels["control"], channel.readyState == .open else {
            throw RctlRealtimeError.controlChannelUnavailable
        }
        let data = try data ?? WireJSON.encode(message)
        guard channel.bufferedAmount + UInt64(data.count) <= Self.maximumControlBufferedBytes else {
            throw RctlRealtimeError.controlBackpressure
        }
        guard channel.sendData(LKRTCDataBuffer(data: data, isBinary: false)) else {
            throw RctlRealtimeError.controlChannelUnavailable
        }
        pressedControl.sent(message)
    }

    /// Does not consult the app's mode: release remains legal after Control ends.
    public func releaseAllControl() {
        controlBuffer.reset()
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.releasePressedControlLocked()
        }
    }

    private func releasePressedControlLocked(keyboardOnly: Bool = false, failOnError: Bool = true) {
        for message in pressedControl.releases(keyboardOnly: keyboardOnly) {
            do { try transmitControlLocked(message) }
            catch {
                if failOnError { failLocked(.controlChannelUnavailable, generation: generation) }
                return
            }
        }
    }

    public func cancelQueuedKeyboardControl() {
        controlBuffer.cancelKeyboard()
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.releasePressedControlLocked(keyboardOnly: true)
        }
    }

    private func startLocked(with request: URLRequest, local: Bool) {
        guard !running else {
            emit(.failure(.alreadyRunning))
            return
        }
        generation &+= 1
        let currentGeneration = generation
        running = true
        controlBuffer.reset(open: true)
        localConnection = local
        readyReceived = false
        remoteDescriptionReady = false
        pendingCandidates.removeAll(keepingCapacity: true)
        channels.removeAll(keepingCapacity: true)
        localCandidateCount = 0
        remoteCandidateCount = 0
        iceConnectionState = "new"
        iceGatheringState = "new"
        firstVideoFrameReceived = false
        freshness = VideoFreshness()
        videoHealth = .waiting
        statistics = VideoStatisticsAccumulator()
        connectedAt = nil
        statisticsPending = false
        lastStatisticsAt = 0
        orientation = nil
        emit(.connection(.signaling))

        let task = (local ? localURLSession : urlSession).webSocketTask(with: request)
        webSocket = task
        task.resume()
        receiveNext(on: task, generation: currentGeneration)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.failLocked(
                .negotiationFailed(self.timeoutDescriptionLocked()),
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
                    let failure: RctlRealtimeError = task.closeCode == .policyViolation
                        ? .authorizationChanged : .signalingFailed(Self.safeMessage(error))
                    self.failLocked(failure, generation: currentGeneration)
                }
            }
        }
    }

    private func handleSignalingLocked(_ message: SignalingMessage, generation currentGeneration: UInt64) throws {
        switch message {
        case let .ready(servers):
            guard !readyReceived else { throw RctlRealtimeError.invalidSignalingResponse }
            readyReceived = true
            let iceServers = try Self.makeIceServers(servers, local: localConnection)
            if let peerConnection {
                let configuration = peerConnection.configuration
                configuration.iceServers = iceServers
                guard peerConnection.setConfiguration(configuration) else {
                    throw RctlRealtimeError.negotiationFailed("ICE configuration was rejected")
                }
            } else {
                peerConnection = try factory.makePeerConnection(
                    iceServers: iceServers,
                    delegate: self
                )
            }
            Self.logger.debug("Signaling ready with \(servers.count, privacy: .public) ICE server entries")
        case let .offer(sdp):
            let peerConnection = try ensurePeerConnectionLocked()
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
            remoteCandidateCount += 1
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

    private func ensurePeerConnectionLocked() throws -> LKRTCPeerConnection {
        if let peerConnection {
            return peerConnection
        }
        let peerConnection = try factory.makePeerConnection(delegate: self)
        self.peerConnection = peerConnection
        Self.logger.debug("Created host-only peer for signaling endpoint without ready")
        return peerConnection
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
        Self.logger.error("Realtime session failed: \(Self.failureKind(error), privacy: .public)")
        emit(.failure(error))
        stopLocked(emitClosed: false)
        emit(.connection(.failed))
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
        controlBuffer.reset(open: false)
        controlTimer?.cancel()
        controlTimer = nil
        monitorTimer?.cancel()
        monitorTimer = nil
        connectedAt = nil
        statisticsPending = false
        releasePressedControlLocked(failOnError: false)
        for label in channels.keys {
            emit(.channel(label: label, state: .closed))
        }
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
        readyReceived = false
        remoteDescriptionReady = false
    }

    private func timeoutDescriptionLocked() -> String {
        "connection timed out (ICE \(iceConnectionState), gathering \(iceGatheringState), " +
            "candidates local=\(localCandidateCount) remote=\(remoteCandidateCount))"
    }

    private static func failureKind(_ error: RctlRealtimeError) -> String {
        switch error {
        case .alreadyRunning: "already-running"
        case .invalidSignalingResponse: "invalid-signaling"
        case .peerConnectionUnavailable: "peer-unavailable"
        case .negotiationFailed: "negotiation"
        case .signalingFailed: "signaling"
        case .signalingClosed: "signaling-closed"
        case .authorizationChanged: "authorization-changed"
        case .controlChannelUnavailable: "control-unavailable"
        case .controlBackpressure: "control-backpressure"
        case .videoStalled: "video-stalled"
        }
    }

    private func emit(_ event: RctlRealtimeEvent) {
        eventDelivery.emit(event, revision: eventRevision)
    }

    private static func safeMessage(_ error: Error?) -> String {
        guard let error else { return "unknown error" }
        let message = (error as NSError).localizedDescription
        return String(message.prefix(256))
    }

    static func validateWebSocketRequest(_ request: URLRequest, localAddress: LocalDeviceAddress? = nil) throws {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              request.httpMethod == nil || request.httpMethod == "GET",
              request.httpBody == nil, request.httpBodyStream == nil else {
            throw RctlRealtimeError.invalidSignalingResponse
        }
        if let localAddress {
            guard request.allHTTPHeaderFields?.isEmpty != false,
                  !request.httpShouldHandleCookies,
                  url == localAddress.signalingRequest().url || url == localAddress.signalingRequest(camera: true).url else {
                throw RctlRealtimeError.invalidSignalingResponse
            }
            return
        }
        if components.scheme == "wss" {
            return
        }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard components.scheme == "ws", loopback else {
            throw RctlRealtimeError.invalidSignalingResponse
        }
    }

    static func makeIceServers(_ servers: [WireICEServer], local: Bool = false) throws -> [LKRTCIceServer] {
        guard !local || servers.isEmpty else { throw RctlRealtimeError.invalidSignalingResponse }
        return try servers.map { server in
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
            guard let self, self.running, self.peerConnection === peerConnection else { return }
            self.adoptVideoTrackLocked(track)
        }
    }

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}

    public func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        queue.async { [weak self] in
            guard let self, self.running, self.peerConnection === peerConnection else { return }
            self.iceConnectionState = Self.iceConnectionStateName(newState)
            Self.logger.debug("ICE connection state: \(self.iceConnectionState, privacy: .public)")
        }
    }

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {
        queue.async { [weak self] in
            guard let self, self.running, self.peerConnection === peerConnection else { return }
            self.iceGatheringState = Self.iceGatheringStateName(newState)
            Self.logger.debug("ICE gathering state: \(self.iceGatheringState, privacy: .public)")
        }
    }

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        queue.async { [weak self] in
            guard let self, self.running, self.peerConnection === peerConnection else { return }
            self.localCandidateCount += 1
            self.sendSignalingLocked(
                .candidate(candidate: candidate.sdp, mid: candidate.sdpMid ?? "0"),
                generation: self.generation
            )
        }
    }

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        queue.async { [weak self] in
            guard let self, self.running, self.peerConnection === peerConnection else {
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
            guard let self, self.running, self.peerConnection === peerConnection else { return }
            self.adoptVideoTrackLocked(track)
        }
    }

    public func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        queue.async { [weak self] in
            guard let self, self.running, self.peerConnection === peerConnection else { return }
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
                self.startMonitorLocked()
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
        firstVideoFrameReceived = false
        freshness = VideoFreshness()
        videoHealth = .waiting
        emit(.videoHealth(.waiting))
#if canImport(UIKit)
        let view = videoView
        let generation = generation
        let trackID = track.trackId
        DispatchQueue.main.async {
            view?.setTrack(track) { [weak self] timestamp in
                self?.queue.async {
                    self?.handleVideoFrameLocked(at: timestamp, generation: generation, trackID: trackID)
                }
            }
        }
#endif
        Self.logger.debug("Remote video track attached; waiting for decoded frame")
    }

    private func handleVideoFrameLocked(at time: TimeInterval, generation currentGeneration: UInt64, trackID: String?) {
        guard running, generation == currentGeneration, let trackID, videoTrack?.trackId == trackID else { return }
        freshness.frame(at: time)
        if !firstVideoFrameReceived {
            firstVideoFrameReceived = true
            Self.logger.info("First remote video frame decoded")
            emit(.firstVideoFrame)
        }
        updateVideoHealthLocked()
    }

    private func startMonitorLocked() {
        guard monitorTimer == nil else { return }
        connectedAt = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.monitorLocked() }
        monitorTimer = timer
        timer.resume()
    }

    private func updateVideoHealthLocked() {
        let health = freshness.health(at: ProcessInfo.processInfo.systemUptime)
        guard videoHealth != health else { return }
        videoHealth = health
        emit(.videoHealth(health))
    }

    private func monitorLocked() {
        guard running, let peerConnection else { return }
        let now = ProcessInfo.processInfo.systemUptime
        updateVideoHealthLocked()
        if let lastActivity = freshness.lastFrame ?? connectedAt, now - lastActivity >= 15 {
            failLocked(.videoStalled, generation: generation)
            return
        }
        guard !statisticsPending, now - lastStatisticsAt >= 1 else { return }
        statisticsPending = true
        lastStatisticsAt = now
        let currentGeneration = generation
        peerConnection.statistics { [weak self] report in
            let sample = VideoStatisticsSample(report: report)
            self?.queue.async { [weak self] in
                guard let self, self.running, self.generation == currentGeneration else { return }
                self.statisticsPending = false
                self.emit(.diagnostics(self.statistics.update(sample)))
            }
        }
    }

    private static func iceConnectionStateName(_ state: LKRTCIceConnectionState) -> String {
        switch state {
        case .new: "new"
        case .checking: "checking"
        case .connected: "connected"
        case .completed: "completed"
        case .failed: "failed"
        case .disconnected: "disconnected"
        case .closed: "closed"
        case .count: "invalid"
        @unknown default: "unknown"
        }
    }

    private static func iceGatheringStateName(_ state: LKRTCIceGatheringState) -> String {
        switch state {
        case .new: "new"
        case .gathering: "gathering"
        case .complete: "complete"
        @unknown default: "unknown"
        }
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
        guard dataChannel.label == "state", !buffer.isBinary else { return }
        let data = buffer.data
        queue.async { [weak self, weak dataChannel] in
            guard let self, let dataChannel,
                  self.channels["state"] === dataChannel,
                  let state = try? WireJSON.decode(RemoteStateMessage.self, from: data) else {
                return
            }
            self.orientation = state.orientation
#if canImport(UIKit)
            let view = self.videoView
            DispatchQueue.main.async {
                view?.setDeviceOrientation(state.orientation)
            }
#endif
            self.emit(.orientation(state.orientation))
        }
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
