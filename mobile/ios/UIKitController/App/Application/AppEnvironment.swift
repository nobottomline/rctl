import Combine
import UIKit

/// Scene-wide dependencies. Created once per (single) scene and passed to
/// every screen through its initializer; there are no global singletons.
@MainActor
final class AppEnvironment {
    let appModel: ControllerAppModel
    let localDevices: LocalDevicesModel
    let appearance: RCAppearanceStore
    let lifecycle: AppLifecycle
    private(set) var router: AppRouter!
    private let presence: PresenceCoordinator
    private let alerts: AppAlertsCoordinator

    init(
        appModel: ControllerAppModel = ControllerAppModel(),
        localDevices: LocalDevicesModel = LocalDevicesModel(),
        appearance: RCAppearanceStore = RCAppearanceStore(),
        lifecycle: AppLifecycle = AppLifecycle()
    ) {
        self.appModel = appModel
        self.localDevices = localDevices
        self.appearance = appearance
        self.lifecycle = lifecycle
        presence = PresenceCoordinator(appModel: appModel, lifecycle: lifecycle)
        alerts = AppAlertsCoordinator(appModel: appModel, localDevices: localDevices)
        router = AppRouter(environment: self)
    }

    func start(in window: UIWindow) {
        alerts.window = window
        router.startObservingPairing()
        Task { await appModel.restore() }
        DebugLaunch.apply(to: self)
    }
}

/// Foreground state of the scene, observable by screens and coordinators.
@MainActor
final class AppLifecycle: ObservableObject {
    @Published private(set) var isActive = false

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
    }
}

/// Keeps the selected relay's presence heartbeat running while the scene is
/// active (including during remote sessions), exactly like the SwiftUI
/// root's `.task(id:)`: identity or activity changes restart or cancel it.
@MainActor
private final class PresenceCoordinator {
    private struct Identity: Equatable {
        let relayID: String
        let origin: String
        let controllerID: String
    }

    private let appModel: ControllerAppModel
    private var task: Task<Void, Never>?
    private var identity: Identity?
    private var cancellables: Set<AnyCancellable> = []

    init(appModel: ControllerAppModel, lifecycle: AppLifecycle) {
        self.appModel = appModel
        appModel.$profile.combineLatest(lifecycle.$isActive)
            .sink { [weak self] profile, active in
                MainActor.assumeIsolated { self?.update(profile: profile, active: active) }
            }
            .store(in: &cancellables)
    }

    private func update(profile: ControllerProfile?, active: Bool) {
        let next = active ? profile.map { Identity(relayID: $0.relayID, origin: $0.origin, controllerID: $0.controller.id) } : nil
        guard next != identity else { return }
        identity = next
        task?.cancel()
        task = nil
        guard next != nil, let profile else { return }
        task = Task { [appModel] in
            await appModel.maintainPresence(for: profile)
        }
    }
}

/// Presents model-level errors that are not owned by a specific screen.
/// One dialog per source at a time; a newer error that arrives while one is
/// shown is presented after it, and a model error is cleared only if it is
/// still the message the user saw.
@MainActor
private final class AppAlertsCoordinator {
    weak var window: UIWindow? {
        didSet {
            requestErrors.window = window
            localErrors.window = window
            requestErrors.presentIfNeeded()
            localErrors.presentIfNeeded()
        }
    }
    private var cancellables: Set<AnyCancellable> = []
    private let requestErrors: ErrorChannel
    private let localErrors: ErrorChannel

    init(appModel: ControllerAppModel, localDevices: LocalDevicesModel) {
        requestErrors = ErrorChannel(
            title: "Relay error",
            read: { [weak appModel] in appModel?.presentedError },
            clear: { [weak appModel] in appModel?.presentedError = nil }
        )
        localErrors = ErrorChannel(
            title: "Local network",
            read: { [weak localDevices] in localDevices?.errorMessage },
            clear: { [weak localDevices] in localDevices?.errorMessage = nil }
        )
        // `@Published` emits before storing; reading on the next turn sees the settled value.
        appModel.$presentedError
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.requestErrors.presentIfNeeded() } }
            .store(in: &cancellables)
        localDevices.$errorMessage
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.localErrors.presentIfNeeded() } }
            .store(in: &cancellables)
    }
}

@MainActor
private final class ErrorChannel {
    weak var window: UIWindow?
    private let title: String
    private let read: @MainActor () -> String?
    private let clear: @MainActor () -> Void
    /// Message currently on screen (or queued in the dialog queue).
    private var shown: String?

    init(title: String, read: @escaping @MainActor () -> String?, clear: @escaping @MainActor () -> Void) {
        self.title = title
        self.read = read
        self.clear = clear
    }

    func presentIfNeeded() {
        guard shown == nil, let message = read(), let root = window?.rootViewController else { return }
        shown = message
        RCDialog.present(
            title: title,
            message: message,
            icon: .circleAlert,
            tone: .danger,
            actions: [RCDialogAction("OK", style: .primary)],
            from: root,
            onFinish: { [weak self] in self?.didFinish(message) }
        )
    }

    /// Runs once the dialog is gone, whether OK was tapped or the card was torn
    /// down with its presenter, so the channel can never stay blocked.
    private func didFinish(_ message: String) {
        shown = nil
        if read() == message {
            clear()
        } else {
            presentIfNeeded()
        }
    }
}
