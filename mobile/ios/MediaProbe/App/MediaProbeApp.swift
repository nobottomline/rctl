import SwiftUI

@main
struct MediaProbeApp: App {
    @StateObject private var model = ProbeAppModel()

    var body: some Scene {
        WindowGroup {
            ProbeRootView(model: model)
        }
    }
}
