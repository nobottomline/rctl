import UIKit

/// Root screen: saved local devices, nearby discovery, relay devices.
/// PLACEHOLDER — owned by the Devices feature.
@MainActor
final class DevicesViewController: RCViewController {
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(chrome: .adaptive)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let pair = RCButton(title: "Pair with relay", icon: .qrCode, variant: .accent)
        pair.onTap = { [weak self] in self?.environment.router.push(.pairRelay) }
        let local = RCButton(title: "Add local device", icon: .wifi, variant: .secondary)
        local.onTap = { [weak self] in self?.environment.router.push(.localDevice(editing: nil)) }
        let stack = UIStackView(arrangedSubviews: [RCLabel("Devices", style: .display), pair, local])
        stack.axis = .vertical
        stack.spacing = RCSpace.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: RCLayout.gutter),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -RCLayout.gutter),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: RCSpace.xxl),
        ])
    }
}
