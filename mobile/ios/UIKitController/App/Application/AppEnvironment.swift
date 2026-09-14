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
@MainActor
private final class AppAlertsCoordinator {
    weak var window: UIWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var presentingRequestError = false
    private var presentingLocalError = false

    init(appModel: ControllerAppModel, localDevices: LocalDevicesModel) {
        appModel.$presentedError
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak appModel] message in
                MainActor.assumeIsolated {
                    guard let self, let message, !self.presentingRequestError else { return }
                    self.presentingRequestError = true
                    self.present(title: "Request failed", message: message) {
                        self.presentingRequestError = false
                        appModel?.presentedError = nil
                    }
                }
            }
            .store(in: &cancellables)
        localDevices.$errorMessage
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak localDevices] message in
                MainActor.assumeIsolated {
                    guard let self, let message, !self.presentingLocalError else { return }
                    self.presentingLocalError = true
                    self.present(title: "Local devices", message: message) {
                        self.presentingLocalError = false
                        localDevices?.errorMessage = nil
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func present(title: String, message: String, completion: @escaping @MainActor () -> Void) {
        guard let root = window?.rootViewController else { completion(); return }
        RCDialog.present(
            title: title,
            message: message,
            icon: .circleAlert,
            tone: .danger,
            actions: [RCDialogAction("OK", style: .primary, handler: completion)],
            from: root
        )
    }
}
