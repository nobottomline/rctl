import Combine
import RctlClient
import RctlProtocol
import RctlRealtime

@MainActor
final class RemoteSessionModel: ObservableObject {
    @Published private(set) var state: RctlRealtimeConnectionState = .idle
    @Published private(set) var videoAvailable = false
    @Published private(set) var channelStates: [String: RctlRealtimeChannelState] = [:]
    @Published private(set) var errorMessage: String?
    @Published var media: ControllerMediaRole = .screen

    let session: RctlRealtimeSession
    private let appModel: ControllerAppModel
    private let deviceID: String
    private var suspended = false
    private var connectionAttempt: UInt64 = 0

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
        session.stop()
    }

    func suspend() {
        guard !suspended else { return }
        connectionAttempt &+= 1
        suspended = true
        videoAvailable = false
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
        media = value
        await connect()
    }

    func sendHome() {
        Task {
            do {
                try await session.sendControl(.key(page: 0x0c, usage: 0x40, down: true))
                try await session.sendControl(.key(page: 0x0c, usage: 0x40, down: false))
            } catch {
                await MainActor.run {
                    errorMessage = "The control channel is not available."
                }
            }
        }
    }

    private func handle(_ event: RctlRealtimeEvent) {
        switch event {
        case let .connection(value):
            state = value
        case .firstVideoFrame:
            videoAvailable = true
        case let .channel(label, value):
            channelStates[label] = value
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
