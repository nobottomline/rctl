import UIKit

/// Add / edit / save-discovered / replace-address form for a LAN device.
/// PLACEHOLDER — owned by the LocalDevice feature.
@MainActor
final class LocalDeviceEditorViewController: RCViewController, AppRoutable {
    let route: AppRoute
    private let environment: AppEnvironment
    private let editingDevice: LocalDeviceProfile?
    private let suggestedDevice: LocalDeviceProfile?

    init(environment: AppEnvironment, editing: LocalDeviceProfile?, suggested: LocalDeviceProfile?) {
        self.environment = environment
        self.editingDevice = editing
        self.suggestedDevice = suggested
        if let suggested {
            route = .discoveredDevice(suggested, replacing: editing)
        } else {
            route = .localDevice(editing: editing)
        }
        super.init(chrome: .adaptive)
    }
}
