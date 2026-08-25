import SwiftUI

@main
struct RctlControllerApp: App {
    @StateObject private var model = ControllerAppModel()

    var body: some Scene {
        WindowGroup {
            ControllerRootView(model: model)
        }
    }
}
