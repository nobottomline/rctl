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

    var canControl: Bool {
        state == .connected && media == .screen && channelStates["control"] == .open
    }

    convenience init(appModel: ControllerAppModel, deviceID: String) {
        self.init(appModel: appModel, target: .relay(deviceID))
    }

    init(appModel: ControllerAppModel, target: RemoteConnectionTarget, localClient: LocalDeviceClient = LocalDeviceClient()) {
        self.appModel = appModel
        self.target = target
        self.relayProfile = appModel.profile
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
    }

    func connect() async {
        preparationTask?.cancel()
        suspended = false
        connectionAttempt &+= 1
        let currentAttempt = connectionAttempt
        cancelKeyboardInput()
        session.stop(notify: false)
        state = .signaling
        videoAvailable = false
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
        }
    }

    func disconnect() {
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
            cancelKeyboardInput()
        }
        interactionMode = resolvedValue
    }

    func sendTouch(phase: Int, finger: Int, x: Double, y: Double) {
        guard interactionMode == .control, canControl else { return }
        session.enqueueControl(.touch(phase: phase, finger: finger, x: x, y: y))
    }

    func sendHardware(_ action: RemoteHardwareAction) {
        guard interactionMode == .control, canControl else { return }
        let command = action.command
        session.enqueueControl(.key(page: command.page, usage: command.usage, down: true))
        if command.releases {
            session.enqueueControl(
                .key(page: command.page, usage: command.usage, down: false),
                after: 0.07
            )
        }
    }

    func sendKeyboard(_ key: RemoteKeyboardKey) {
        guard interactionMode == .control, canControl else { return }
        enqueueKeyTap(
            usage: key.usage,
            at: reserveKeyboardWindow(duration: Self.textKeyInterval)
        )
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

        let baseDelay = reserveKeyboardWindow(
            duration: Double(strokes.count) * Self.textKeyInterval
        )
        for (index, stroke) in strokes.enumerated() {
            let start = baseDelay + Double(index) * Self.textKeyInterval
            if stroke.requiresShift {
                session.enqueueKeyboardControl(
                    .key(page: HIDKeyboard.page, usage: HIDKeyboard.leftShift, down: true),
                    after: start
                )
            }
            enqueueKeyTap(
                usage: stroke.usage,
                at: start + (stroke.requiresShift ? 0.006 : 0)
            )
            if stroke.requiresShift {
                session.enqueueKeyboardControl(
                    .key(page: HIDKeyboard.page, usage: HIDKeyboard.leftShift, down: false),
                    after: start + 0.024
                )
            }
        }
        return .sent(characterCount: strokes.count)
    }

    private func enqueueKeyTap(usage: Int, at delay: Double) {
        session.enqueueKeyboardControl(
            .keyTap(page: HIDKeyboard.page, usage: usage),
            after: delay
        )
    }

    private func reserveKeyboardWindow(duration: TimeInterval) -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        let start = max(now, keyboardAvailableAt)
        keyboardAvailableAt = start + duration
        return start - now
    }

    private func cancelKeyboardInput() {
        let hadKeyboardInput = keyboardAvailableAt > 0
        keyboardAvailableAt = 0
        session.cancelQueuedKeyboardControl()
        guard hadKeyboardInput else { return }
        session.enqueueControl(
            .key(page: HIDKeyboard.page, usage: HIDKeyboard.leftShift, down: false)
        )
    }

    func handle(_ event: RctlRealtimeEvent) {
        switch event {
        case let .connection(value):
            state = value
            if value != .connected {
                interactionMode = .view
                cancelKeyboardInput()
            }
            if value == .failed || value == .closed || value == .idle {
                channelStates = [:]
                videoAvailable = false
            }
        case .firstVideoFrame:
            videoAvailable = true
        case .orientation:
            break
        case let .channel(label, value):
            channelStates[label] = value
            if label == "control", value != .open {
                cancelKeyboardInput()
                interactionMode = .view
            }
        case let .failure(error):
            errorMessage = error.localizedDescription
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
