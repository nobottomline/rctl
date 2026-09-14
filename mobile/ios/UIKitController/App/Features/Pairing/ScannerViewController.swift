import UIKit

/// Full-screen pairing QR scanner. PLACEHOLDER — owned by the Pairing feature.
@MainActor
final class ScannerViewController: RCViewController, AppRoutable {
    let route: AppRoute = .scanPairingCode
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(chrome: .stage)
    }
}
