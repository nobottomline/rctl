import UIKit

/// What a remote session connects to.
enum RemoteSessionTarget: Equatable {
    case local(LocalDeviceProfile)
    case relay(deviceID: String)
}

/// Full-screen remote screen/camera session. PLACEHOLDER — owned by the Remote feature.
@MainActor
final class RemoteSessionViewController: RCViewController, AppRoutable {
    let route: AppRoute
    private let environment: AppEnvironment
    private let target: RemoteSessionTarget

    init(environment: AppEnvironment, target: RemoteSessionTarget) {
        self.environment = environment
        self.target = target
        switch target {
        case let .local(device): route = .localControl(device)
        case let .relay(deviceID): route = .relayControl(deviceID: deviceID)
        }
        super.init(chrome: .stage)
    }
}
