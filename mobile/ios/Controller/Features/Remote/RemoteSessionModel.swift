import Combine
import RctlClient
import RctlProtocol
import RctlRealtime

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

@MainActor
final class RemoteSessionModel: ObservableObject {
    @Published private(set) var state: RctlRealtimeConnectionState = .idle
    @Published private(set) var videoAvailable = false
    @Published private(set) var channelStates: [String: RctlRealtimeChannelState] = [:]
    @Published private(set) var errorMessage: String?
    @Published var media: ControllerMediaRole = .screen
    @Published private(set) var interactionMode: RemoteInteractionMode = .view

    let session: RctlRealtimeSession
    private let appModel: ControllerAppModel
    private let deviceID: String
    private var suspended = false
    private var connectionAttempt: UInt64 = 0

    var canControl: Bool {
        media == .screen && channelStates["control"] == .open
    }

    init(appModel: ControllerAppModel, deviceID: String) {
        self.appModel = appModel
        self.deviceID = deviceID
        let router = EventRouter()
        session = RctlRealtimeSession { [router] event in
            router.send(event)
        }
        router.owner = self
    }

    func connect() async {
        suspended = false
        connectionAttempt &+= 1
        let currentAttempt = connectionAttempt
        session.stop()
        state = .signaling
        videoAvailable = false
        channelStates = [:]
        interactionMode = .view
        errorMessage = nil
        do {
            let request = try await appModel.signalingRequest(deviceID: deviceID, media: media)
            guard !suspended, connectionAttempt == currentAttempt else { return }
            try session.start(with: request)
        } catch {
            guard !suspended, connectionAttempt == currentAttempt else { return }
            state = .failed
            errorMessage = ControllerAppModel.message(for: error)
        }
    }

    func disconnect() {
        connectionAttempt &+= 1
        suspended = false
        interactionMode = .view
        session.stop()
    }

    func suspend() {
        guard !suspended else { return }
        connectionAttempt &+= 1
        suspended = true
        videoAvailable = false
        interactionMode = .view
        session.stop()
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
        media = value
        await connect()
    }

    func setInteractionMode(_ value: RemoteInteractionMode) {
        interactionMode = value == .control && canControl ? .control : .view
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

    private func handle(_ event: RctlRealtimeEvent) {
        switch event {
        case let .connection(value):
            state = value
        case .firstVideoFrame:
            videoAvailable = true
        case .orientation:
            break
        case let .channel(label, value):
            channelStates[label] = value
            if label == "control", value != .open {
                interactionMode = .view
            }
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }

    private final class EventRouter: @unchecked Sendable {
        weak var owner: RemoteSessionModel?

        func send(_ event: RctlRealtimeEvent) {
            Task { @MainActor [weak self] in
                self?.owner?.handle(event)
            }
        }
    }
}
