import Combine
import Foundation
import RctlClient
import RctlProtocol
import RctlRealtime

enum RemoteConnectionTarget {
    case relay(String)
    case local(LocalDeviceAddress)
}

enum RemoteAccessPath: Equatable {
    case lan(LocalDeviceAddress)
    case relay(origin: String?)

    var label: String { if case .lan = self { "LAN" } else { "Relay" } }
    var endpoint: String {
        switch self {
        case .lan(let address): address.displayAddress
        case .relay(let origin): origin ?? "Unavailable"
        }
    }
}

enum RemoteInteractionMode: String, CaseIterable, Identifiable {
    case view
    case control

    var id: Self { self }
}

enum RemoteHardwareAction {
    case home
    case lock
    case volumeUp
    case volumeDown
    case controlCenter
    case notificationCenter

    fileprivate var command: (page: Int, usage: Int, releases: Bool) {
        switch self {
        case .home: (0x0c, 0x40, true)
        case .lock: (0x0c, 0x30, true)
        case .volumeUp: (0x0c, 0xe9, true)
        case .volumeDown: (0x0c, 0xea, true)
        case .controlCenter: (0xf0, 1, false)
        case .notificationCenter: (0xf0, 2, false)
        }
    }
}

enum RemoteKeyboardKey: String, CaseIterable, Identifiable {
    case escape
    case tab
    case enter
    case backspace
    case deleteForward
    case left
    case up
    case down
    case right

    var id: Self { self }

    fileprivate var usage: Int {
        switch self {
        case .escape: 0x29
        case .tab: 0x2b
        case .enter: 0x28
        case .backspace: 0x2a
        case .deleteForward: 0x4c
        case .left: 0x50
        case .up: 0x52
        case .down: 0x51
        case .right: 0x4f
        }
    }
}

enum RemoteTextInputResult: Equatable {
    case sent(characterCount: Int)
    case rejected(message: String)
}

@MainActor
final class RemoteSessionModel: ObservableObject {
    private static let textKeyInterval = 0.040

    @Published private(set) var state: RctlRealtimeConnectionState = .idle
    @Published private(set) var videoAvailable = false
    @Published private(set) var videoHealth: RctlVideoHealth = .waiting
    @Published private(set) var diagnostics = RctlRealtimeDiagnostics()
    @Published private(set) var reconnecting = false
    @Published private(set) var reconnectAttempt = 0
    @Published private(set) var channelStates: [String: RctlRealtimeChannelState] = [:]
    @Published private(set) var errorMessage: String?
    @Published var media: ControllerMediaRole = .screen
    @Published private(set) var interactionMode: RemoteInteractionMode = .view

    let session: RctlRealtimeSession
    let accessPath: RemoteAccessPath
    private let appModel: ControllerAppModel
    private let target: RemoteConnectionTarget
    private let relayProfile: ControllerProfile?
    private let localClient: LocalDeviceClient
    private var suspended = false
    private var connectionAttempt: UInt64 = 0
    private var preparationTask: Task<URLRequest, Error>?
    private var keyboardAvailableAt: TimeInterval = 0
    private var reconnectTask: Task<Void, Never>?
    private var wantsConnection = false
    private var retryableFailure = true
    private var authorizationObserver: AnyCancellable?
    private var activeTouches: Set<Int> = []
    private static let maximumKeyboardBacklog: TimeInterval = 10.5

    var canControl: Bool {
        state == .connected && videoAvailable && videoHealth == .flowing &&
            media == .screen && channelStates["control"] == .open
    }

    convenience init(appModel: ControllerAppModel, deviceID: String) {
        self.init(appModel: appModel, target: .relay(deviceID))
    }

    init(appModel: ControllerAppModel, target: RemoteConnectionTarget, localClient: LocalDeviceClient = LocalDeviceClient()) {
        self.appModel = appModel
        self.target = target
        self.relayProfile = appModel.profile
        self.sessionScopes = appModel.profile?.controller.scopes
        switch target {
        case .local(let address): accessPath = .lan(address)
        case .relay: accessPath = .relay(origin: appModel.profile?.origin)
        }
        self.localClient = localClient
        let router = EventRouter()
        session = RctlRealtimeSession { [router] event in
            router.send(event)
        }
        router.owner = self
        if case .relay = target {
            authorizationObserver = appModel.$profile.dropFirst().sink { [weak self] updated in
                guard let self, let original = self.relayProfile else { return }
                let sameIdentity = updated?.hasSameIdentity(as: original) == true
                let scopes = updated?.controller.scopes
                // Existing channels retain their negotiated permissions. A new
                // grant must never silently turn an existing viewer into Control.
                let negotiated = [.connecting, .connected, .disconnected].contains(self.state) ||
                    (self.state == .signaling && self.preparationTask == nil)
                if !sameIdentity || (negotiated && scopes != self.sessionScopes) {
                    self.disconnect()
                    self.errorMessage = "Controller access changed. Reconnect to use current permissions."
                }
                self.sessionScopes = scopes
            }
        }
    }

    private var sessionScopes: [ControllerScope]?

    func connect() async {
        cancelReconnect()
        reconnectAttempt = 0
        wantsConnection = true
        await startConnection()
    }

    private func startConnection() async {
        preparationTask?.cancel()
        suspended = false
        connectionAttempt &+= 1
        let currentAttempt = connectionAttempt
        endControl()
        session.stop(notify: false)
        state = .signaling
        videoAvailable = false
        videoHealth = .waiting
        diagnostics = RctlRealtimeDiagnostics()
        retryableFailure = true
        channelStates = [:]
        interactionMode = .view
        errorMessage = nil
        let selectedMedia = media
        let preparation = Task { [appModel, target, localClient, relayProfile] in
            switch target {
            case let .relay(deviceID):
                guard let relayProfile else { throw ControllerClientError.corruptCredential }
                return try await appModel.signalingRequest(deviceID: deviceID, media: selectedMedia, expectedProfile: relayProfile)
            case let .local(address):
                _ = try await localClient.capabilities(at: address, camera: selectedMedia == .camera)
                return address.signalingRequest(camera: selectedMedia == .camera)
            }
        }
        preparationTask = preparation
        defer {
            if connectionAttempt == currentAttempt { preparationTask = nil }
        }
        do {
            let request = try await withTaskCancellationHandler {
                try await preparation.value
            } onCancel: { preparation.cancel() }
            let localAddress: LocalDeviceAddress?
            switch target {
            case .relay:
                localAddress = nil
            case let .local(address):
                localAddress = address
            }
            guard !suspended, connectionAttempt == currentAttempt else { return }
            try Task.checkCancellation()
            try session.start(with: request, localAddress: localAddress)
        } catch is CancellationError {
            guard !suspended, connectionAttempt == currentAttempt else { return }
            handle(.connection(.closed))
        } catch {
            guard !suspended, connectionAttempt == currentAttempt else { return }
            state = .failed
            if case .local = target { errorMessage = LocalDevicesModel.message(for: error) }
            else { errorMessage = ControllerAppModel.message(for: error) }
            if let error = error as? URLError,
               [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet].contains(error.code) {
                scheduleReconnect()
            }
        }
    }

    func disconnect() {
        wantsConnection = false
        cancelReconnect()
        endControl()
        preparationTask?.cancel()
        preparationTask = nil
        connectionAttempt &+= 1
        suspended = false
        interactionMode = .view
        cancelKeyboardInput()
        session.stop()
        handle(.connection(.closed))
    }

    func suspend() {
        guard !suspended else { return }
        cancelReconnect()
        endControl()
        preparationTask?.cancel()
        preparationTask = nil
        connectionAttempt &+= 1
        suspended = true
        videoAvailable = false
        interactionMode = .view
        cancelKeyboardInput()
        session.stop()
        handle(.connection(.closed))
    }

    func resume() async {
        guard suspended else { return }
        suspended = false
        await connect()
    }

    func dismissError() {
        errorMessage = nil
    }

    func selectMedia(_ value: ControllerMediaRole) async {
        guard media != value else { return }
        interactionMode = .view
        cancelKeyboardInput()
        media = value
        await connect()
    }

    func setInteractionMode(_ value: RemoteInteractionMode) {
        let resolvedValue: RemoteInteractionMode = value == .control && canControl ? .control : .view
        if interactionMode == .control, resolvedValue != .control {
            endControl()
        }
        interactionMode = resolvedValue
    }

    func sendTouch(phase: Int, finger: Int, x: Double, y: Double) {
        // UI cancellation can arrive after the mode changed to View.
        if phase == 2 {
            guard activeTouches.remove(finger) != nil else { return }
            if !session.enqueueControl(.touch(phase: phase, finger: finger, x: x, y: y)) { inputRejected() }
            return
        }
        guard interactionMode == .control, canControl else { return }
        guard phase == 0 || (phase == 1 && activeTouches.contains(finger)) else { return }
        if session.enqueueControl(.touch(phase: phase, finger: finger, x: x, y: y)) {
            activeTouches.insert(finger)
        } else { inputRejected() }
    }

    func sendHardware(_ action: RemoteHardwareAction) {
        guard interactionMode == .control, canControl else { return }
        let command = action.command
        guard session.enqueueControl(.key(page: command.page, usage: command.usage, down: true)) else {
            inputRejected(); return
        }
        if command.releases {
            if !session.enqueueControl(
                .key(page: command.page, usage: command.usage, down: false),
                after: 0.07
            ) { inputRejected() }
        }
    }

    func sendKeyboard(_ key: RemoteKeyboardKey) {
        guard interactionMode == .control, canControl else { return }
        guard let delay = reserveKeyboardWindow(duration: Self.textKeyInterval),
              session.enqueueKeyboardControl(.keyTap(page: HIDKeyboard.page, usage: key.usage), after: delay) else {
            inputRejected(); return
        }
    }

    func sendText(_ text: String) -> RemoteTextInputResult {
        guard interactionMode == .control, canControl else {
            return .rejected(message: "Control mode is required for keyboard input.")
        }
        guard !text.isEmpty else {
            return .rejected(message: "Enter text before sending.")
        }

        let strokes: [HIDKeyStroke]
        do {
            strokes = try HIDKeyboard.strokes(for: text)
        } catch let error as HIDKeyboardMappingError {
            switch error {
            case let .tooLong(maximumCharacters):
                return .rejected(message: "Text is limited to \(maximumCharacters) characters per send.")
            case let .unsupportedCharacter(character):
                return .rejected(message: "The character '\(character)' needs clipboard support, which is not available yet.")
            }
        } catch {
            return .rejected(message: "The text could not be converted to keyboard input.")
        }

        guard let baseDelay = reserveKeyboardWindow(
            duration: Double(strokes.count) * Self.textKeyInterval
        ) else { return .rejected(message: "The keyboard queue is full. Wait for pending text to finish.") }
        var messages: [ScheduledControlMessage] = []
        for (index, stroke) in strokes.enumerated() {
            let start = baseDelay + Double(index) * Self.textKeyInterval
            if stroke.requiresShift {
                messages.append(ScheduledControlMessage(
                    .key(page: HIDKeyboard.page, usage: HIDKeyboard.leftShift, down: true),
                    after: start
                ))
            }
            messages.append(ScheduledControlMessage(.keyTap(page: HIDKeyboard.page, usage: stroke.usage),
                after: start + (stroke.requiresShift ? 0.006 : 0)))
            if stroke.requiresShift {
                messages.append(ScheduledControlMessage(
                    .key(page: HIDKeyboard.page, usage: HIDKeyboard.leftShift, down: false),
                    after: start + 0.024
                ))
            }
        }
        guard session.enqueueKeyboardControls(messages) else {
            inputRejected()
            return .rejected(message: "Text was not queued. The control connection is unavailable or congested.")
        }
        return .sent(characterCount: strokes.count)
    }

    private func reserveKeyboardWindow(duration: TimeInterval) -> TimeInterval? {
        let now = ProcessInfo.processInfo.systemUptime
        let start = max(now, keyboardAvailableAt)
        guard start + duration - now <= Self.maximumKeyboardBacklog else { return nil }
        keyboardAvailableAt = start + duration
        return start - now
    }

    private func cancelKeyboardInput() {
        keyboardAvailableAt = 0
        session.cancelQueuedKeyboardControl()
    }

    private func endControl() {
        interactionMode = .view
        activeTouches.removeAll()
        keyboardAvailableAt = 0
        session.releaseAllControl()
    }

    private func inputRejected() {
        endControl()
        errorMessage = "Input stopped: the control connection is unavailable or congested."
        retryableFailure = false
        session.stop(notify: false)
        handle(.connection(.failed))
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnecting = false
    }

    private func scheduleReconnect() {
        guard wantsConnection, !suspended, reconnectTask == nil, reconnectAttempt < 3 else { return }
        reconnectAttempt += 1
        reconnecting = true
        let revision = connectionAttempt
        let delay = UInt64(1 << (reconnectAttempt - 1))
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled, self.wantsConnection, !self.suspended,
                  self.connectionAttempt == revision else { return }
            self.reconnectTask = nil
            self.reconnecting = false
            await self.startConnection()
        }
    }

    func handle(_ event: RctlRealtimeEvent) {
        switch event {
        case let .connection(value):
            state = value
            if value != .connected {
                endControl()
            }
            if value == .failed || value == .closed || value == .idle {
                channelStates = [:]
                videoAvailable = false
                videoHealth = .waiting
                diagnostics = RctlRealtimeDiagnostics()
            }
            if (value == .failed || value == .closed), retryableFailure { scheduleReconnect() }
        case .firstVideoFrame:
            // A first-frame callback may already be stale when delivered.
            // Only the separately evaluated health event enables control.
            break
        case let .videoHealth(health):
            videoHealth = health
            videoAvailable = health == .flowing
            if health != .flowing { endControl() }
        case let .diagnostics(value):
            diagnostics = value
        case .orientation:
            break
        case let .channel(label, value):
            channelStates[label] = value
            if label == "control", value != .open {
                endControl()
            }
        case let .failure(error):
            errorMessage = error.localizedDescription
            switch error {
            case .negotiationFailed, .signalingFailed, .signalingClosed, .videoStalled:
                retryableFailure = true
            default: retryableFailure = false
            }
        }
    }

    @MainActor
    private final class EventRouter {
        weak var owner: RemoteSessionModel?

        func send(_ event: RctlRealtimeEvent) {
            owner?.handle(event)
        }
    }
}
