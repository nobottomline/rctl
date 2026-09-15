import Combine
import RctlRealtime
import UIKit

/// Every secondary screen is a push onto one navigation stack rooted at
/// Devices, so the system back gesture always returns.
enum AppRoute: Equatable {
    case pairRelay
    case scanPairingCode
    /// Add (nil) or edit a saved local device.
    case localDevice(editing: LocalDeviceProfile?)
    /// Save a discovered device, optionally replacing a saved entry's address.
    case discoveredDevice(LocalDeviceProfile, replacing: LocalDeviceProfile?)
    case localControl(LocalDeviceProfile)
    case relayControl(deviceID: String)
#if DEBUG
    /// Design-system gallery for visual review (`--rctl-route=gallery`).
    case gallery
#endif

    var isPairing: Bool {
        self == .pairRelay || self == .scanPairingCode
    }
}

/// Screens know the route they were created for; the router uses it to
/// reconcile the stack (e.g. pop pairing screens after a successful claim).
@MainActor
protocol AppRoutable: UIViewController {
    var route: AppRoute { get }
}

@MainActor
final class AppRouter {
    private unowned let environment: AppEnvironment
    private(set) weak var navigationController: RCNavigationController?
    private var cancellables: Set<AnyCancellable> = []

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func makeRootNavigationController() -> RCNavigationController {
        let root = DevicesViewController(environment: environment)
        let navigation = RCNavigationController(rootViewController: root)
        navigationController = navigation
        return navigation
    }

    var routes: [AppRoute] {
        navigationController?.viewControllers.compactMap { ($0 as? AppRoutable)?.route } ?? []
    }

    func push(_ route: AppRoute, animated: Bool = true) {
        guard let navigationController else { return }
        // Ignore double taps that would push the same screen twice.
        if let top = navigationController.topViewController as? AppRoutable, top.route == route { return }
        navigationController.pushViewController(makeViewController(for: route), animated: animated)
    }

    /// Replaces everything above Devices with `routes`.
    func setStack(_ routes: [AppRoute], animated: Bool = true) {
        guard let navigationController, let root = navigationController.viewControllers.first else { return }
        navigationController.setViewControllers([root] + routes.map(makeViewController(for:)), animated: animated)
    }

    func pop(animated: Bool = true) {
        navigationController?.popViewController(animated: animated)
    }

    func popToRoot(animated: Bool = true) {
        navigationController?.popToRootViewController(animated: animated)
    }

    /// Pairing finished somewhere in the flow: return to the device list.
    /// Only a change of the selected relay identity counts; authorization
    /// updates to the current profile (renames, permissions from the heartbeat)
    /// must not close a pairing screen the user is working in.
    func startObservingPairing() {
        environment.appModel.$profile
            .map { profile in profile.map { "\($0.relayID)\n\($0.origin)\n\($0.controller.id)" } }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] identity in
                MainActor.assumeIsolated {
                    guard let self, identity != nil, self.routes.contains(where: \.isPairing) else { return }
                    self.popToRoot()
                }
            }
            .store(in: &cancellables)
    }

    func makeViewController(for route: AppRoute) -> UIViewController {
        switch route {
        case .pairRelay:
            return PairingViewController(environment: environment)
        case .scanPairingCode:
            return ScannerViewController(environment: environment)
        case let .localDevice(editing):
            return LocalDeviceEditorViewController(environment: environment, editing: editing, suggested: nil)
        case let .discoveredDevice(suggested, replacing):
            return LocalDeviceEditorViewController(environment: environment, editing: replacing, suggested: suggested)
        case let .localControl(device):
            return RemoteSessionViewController(environment: environment, target: .local(device))
        case let .relayControl(deviceID):
            return RemoteSessionViewController(environment: environment, target: .relay(deviceID: deviceID))
#if DEBUG
        case .gallery:
            return DesignGalleryViewController(environment: environment)
#endif
        }
    }
}
