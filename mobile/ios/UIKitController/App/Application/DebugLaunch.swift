import RctlRealtime
import UIKit

/// Debug-only launch arguments for screenshots and review. Release builds
/// ignore all of them.
///
/// - `--rctl-route=pair|scan|local|edit|save|replace|first-local|remote|gallery` opens a screen.
/// - `--rctl-push=local|pair` performs a real animated push 1.5 s after launch.
/// - `--rctl-appearance=system|warm|console` overrides the appearance setting for this launch.
/// - `--rctl-scanner-demo` replays scripted detections in the scanner (read by the scanner).
/// - `--rctl-demo` renders screens from synthetic fixtures where a screen supports it
///   (read by the screens; never touches stored data or the network).
@MainActor
enum DebugLaunch {
    static func argument(_ name: String) -> String? {
#if DEBUG
        let prefix = "--\(name)="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
#else
        return nil
#endif
    }

    static func flag(_ name: String) -> Bool {
#if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--\(name)")
#else
        return false
#endif
    }

    /// Synthetic data mode for screenshots (`--rctl-demo`).
    static var isDemo: Bool { flag("rctl-demo") }

    static func apply(to environment: AppEnvironment) {
#if DEBUG
        if let value = argument("rctl-appearance"), let appearance = RCAppearance(rawValue: value) {
            environment.appearance.set(appearance)
        }
        if let route = argument("rctl-route"), let routes = routes(for: route, environment: environment) {
            environment.router.setStack(routes, animated: false)
        }
        if let push = argument("rctl-push") {
            let route: AppRoute? = switch push {
            case "local": .localDevice(editing: nil)
            case "pair": .pairRelay
            default: nil
            }
            if let route {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    MainActor.assumeIsolated {
                        if let window = environment.router.navigationController?.view.window {
                            let marker = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 14))
                            marker.backgroundColor = .black
                            marker.isUserInteractionEnabled = false
                            window.addSubview(marker)
                        }
                        environment.router.push(route)
                    }
                }
            }
        }
#endif
    }

#if DEBUG
    private static func routes(for value: String, environment: AppEnvironment) -> [AppRoute]? {
        let suggested = try? LocalDeviceAddress("192.168.1.30:8080")
        switch value {
        case "pair": return [.pairRelay]
        case "scan": return [.pairRelay, .scanPairingCode]
        case "local": return [.localDevice(editing: nil)]
        case "edit":
            let saved = environment.localDevices.devices.first
                ?? (try? LocalDeviceAddress("192.168.1.2:8080")).map { LocalDeviceProfile(id: UUID(), name: "Studio", address: $0) }
            return saved.map { [.localDevice(editing: $0)] }
        case "gallery": return [.gallery]
        case "first-local", "remote":
            // Remote demo states render without a connection, so a synthetic
            // device is enough when nothing is saved.
            let demo = isDemo || argument("rctl-remote-demo") != nil
            let device = environment.localDevices.devices.first
                ?? (demo ? (try? LocalDeviceAddress("192.168.1.20:8080")).map { LocalDeviceProfile(id: UUID(), name: "Living room iPad", address: $0) } : nil)
            return device.map { [.localControl($0)] }
        case "save":
            guard let suggested else { return nil }
            return [.discoveredDevice(LocalDeviceProfile(id: UUID(), name: "Kitchen iPad", address: suggested), replacing: nil)]
        case "replace":
            guard let suggested else { return nil }
            let saved = environment.localDevices.devices.first
                ?? (try? LocalDeviceAddress("192.168.1.2:8080")).map { LocalDeviceProfile(id: UUID(), name: "Studio", address: $0) }
            guard let saved else { return nil }
            return [.discoveredDevice(LocalDeviceProfile(id: UUID(), name: "Kitchen iPad", address: suggested), replacing: saved)]
        default: return nil
        }
    }
#endif
}
