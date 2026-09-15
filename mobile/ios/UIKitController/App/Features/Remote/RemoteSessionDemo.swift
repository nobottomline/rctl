#if DEBUG
import RctlClient
import RctlRealtime
import UIKit

/// Screenshot fixtures for the remote screen (Debug builds only). Renders the
/// real chrome from a fixed snapshot with a static stand-in for video; no
/// model, session or network is created.
///
/// Launch with `--rctl-demo` or `--rctl-remote-demo=<state>` on a remote route
/// (e.g. `--rctl-route=first-local`). `--rctl-remote-demo-path=relay` shows the
/// relay route.
struct RemoteSessionDemo {
    enum State: String, CaseIterable {
        case connecting, live, control, camera, failed, reconnecting, stalled, ended, keyboard, tools
        /// Session controls with the Lock confirmation open.
        case lock
        /// The compact source menu open (phones).
        case sourceMenu = "source-menu"
        /// The relay device vanished before the screen opened.
        case missing
        /// Steps through `cycleScript` so transitions can be recorded without taps.
        case cycle
    }

    static let cycleScript: [State] = [.connecting, .live, .control, .keyboard, .control, .stalled, .failed, .reconnecting, .live, .camera, .ended]

    let state: State
    /// `--rctl-remote-demo-orientation=landscape|portrait` pins the interface orientation.
    var orientation: UIInterfaceOrientationMask?
    var snapshot: RemoteSessionSnapshot
    let accessPath: RemoteAccessPath
    var diagnostics: RctlRealtimeDiagnostics

    /// Non-nil when the launch arguments request the demo.
    @MainActor
    static func fromLaunchArguments(target: RemoteSessionTarget) -> RemoteSessionDemo? {
        let requested = DebugLaunch.argument("rctl-remote-demo")
        guard requested != nil || DebugLaunch.isDemo else { return nil }
        let state = requested.flatMap(State.init(rawValue:)) ?? .live
        var address: LocalDeviceAddress?
        if case let .local(device) = target { address = device.address }
        if DebugLaunch.argument("rctl-remote-demo-path") == "relay" { address = nil }
        var demo = RemoteSessionDemo(state: state, address: address)
        demo.orientation = switch DebugLaunch.argument("rctl-remote-demo-orientation") {
        case "landscape": .landscapeRight
        case "portrait": .portrait
        default: nil
        }
        return demo
    }

    /// `address` nil renders the relay route.
    init(state: State, address: LocalDeviceAddress?) {
        self.state = state
        accessPath = address.map(RemoteAccessPath.lan) ?? .relay(origin: "https://relay.example.net")
        let isLocal = address != nil
        let snapshot = Self.snapshot(for: state == .cycle ? .connecting : state, isLocal: isLocal)
        self.snapshot = snapshot
        var diagnostics = RctlRealtimeDiagnostics()
        if snapshot.videoAvailable {
            diagnostics.framesPerSecond = 59.8
            diagnostics.bitsPerSecond = 4_812_000
            diagnostics.packetLossPercent = 0.2
            diagnostics.roundTripMilliseconds = 18
            diagnostics.route = isLocal ? .direct : .turn
        }
        self.diagnostics = diagnostics
    }

    static func snapshot(for state: State, isLocal: Bool) -> RemoteSessionSnapshot {
        var snapshot = RemoteSessionSnapshot(isLocal: isLocal)
        func live() {
            snapshot.state = .connected
            snapshot.videoAvailable = true
            snapshot.videoHealth = .flowing
            snapshot.canControl = true
        }
        switch state {
        case .connecting, .cycle:
            snapshot.state = .signaling
        case .live, .sourceMenu:
            live()
        case .control, .keyboard, .tools, .lock:
            live()
            snapshot.interactionMode = .control
        case .camera:
            live()
            snapshot.media = .camera
            snapshot.canControl = false
        case .failed:
            snapshot.state = .failed
            snapshot.errorMessage = "Could not reach the local device. Check its address, network access, iOS Local Network permission, and whether LAN control is enabled."
        case .reconnecting:
            snapshot.state = .failed
            snapshot.reconnecting = true
            snapshot.reconnectAttempt = 2
        case .stalled:
            snapshot.state = .connected
            snapshot.videoHealth = .stalled
        case .ended, .missing:
            snapshot.state = .closed
        }
        return snapshot
    }

    mutating func show(_ state: State) {
        snapshot = Self.snapshot(for: state, isLocal: snapshot.isLocal)
    }

    // MARK: Interaction (so a reviewer can tap through states without a device)

    mutating func selectMode(_ mode: RemoteInteractionMode) {
        snapshot.interactionMode = mode == .control && snapshot.canControl ? .control : .view
    }

    mutating func selectMedia(_ media: ControllerMediaRole) {
        snapshot.media = media
        snapshot.interactionMode = .view
        snapshot.canControl = media == .screen && snapshot.videoAvailable
    }

    mutating func reconnect() {
        let address: LocalDeviceAddress? = if case let .lan(address) = accessPath { address } else { nil }
        let orientation = orientation
        self = RemoteSessionDemo(state: .live, address: address)
        self.orientation = orientation
    }

    /// A dark "remote screen" stand-in: portrait tablet proportions with a
    /// soft gradient and an app-grid hint, drawn once.
    @MainActor
    static func placeholderImage(media: ControllerMediaRole) -> UIImage {
        let size = media == .camera ? CGSize(width: 480, height: 640) : CGSize(width: 540, height: 720)
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let colors = [
                RCColor.accentSoft.resolvedColor(with: traits).cgColor,
                RCColor.elevated.resolvedColor(with: traits).cgColor,
                RCColor.backgroundDeep.resolvedColor(with: traits).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let tile = RCColor.lineStrong.resolvedColor(with: traits)
            tile.setFill()
            let columns = 4
            let side: CGFloat = 64
            let spacingX = (size.width - CGFloat(columns) * side) / CGFloat(columns + 1)
            for row in 0..<5 {
                for column in 0..<columns {
                    let rect = CGRect(x: spacingX + CGFloat(column) * (side + spacingX), y: 70 + CGFloat(row) * (side + 44), width: side, height: side)
                    UIBezierPath(roundedRect: rect, cornerRadius: 15).fill()
                }
            }
            RCColor.textQuaternary.resolvedColor(with: traits).setFill()
            UIBezierPath(roundedRect: CGRect(x: size.width / 2 - 60, y: size.height - 18, width: 120, height: 5), cornerRadius: 2.5).fill()
        }
    }
}
#endif
