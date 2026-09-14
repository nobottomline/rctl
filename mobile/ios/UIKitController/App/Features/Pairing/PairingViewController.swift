import UIKit

/// Relay pairing introduction: steps, Scan QR, Paste code. PLACEHOLDER — owned by the Pairing feature.
@MainActor
final class PairingViewController: RCViewController, AppRoutable {
    let route: AppRoute = .pairRelay
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(chrome: .adaptive)
    }
}
