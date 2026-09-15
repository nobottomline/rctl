import Foundation
import RctlClient
import RctlRealtime

/// The model values the remote screen renders, captured once per render pass.
/// Plain data so every presentation rule can be tested without UIKit or a
/// live session.
struct RemoteSessionSnapshot: Equatable {
    var state: RctlRealtimeConnectionState = .idle
    var videoAvailable = false
    var videoHealth: RctlVideoHealth = .waiting
    var media: ControllerMediaRole = .screen
    var interactionMode: RemoteInteractionMode = .view
    var canControl = false
    var reconnecting = false
    var reconnectAttempt = 0
    var errorMessage: String?
    var isLocal: Bool
}

/// Semantic color role of a piece of remote chrome; views map it to `RCColor`.
enum RemoteTone: Equatable, Sendable {
    case success
    case accent
    case danger
    case text
    case secondary
    case tertiary
}

/// Display values for the session chrome, derived from a snapshot. Mirrors the
/// SwiftUI controller's `connectionLabel`, `connectionColor`, mode chip and
/// session overlay rules.
struct RemoteSessionPresentation: Equatable {
    enum InterruptionKind: Equatable, Sendable {
        /// The session was closed (explicitly, by suspension, or by the peer).
        case sessionEnded
        /// Connected, but no fresh frames arrive; control is disabled.
        case videoPaused
        /// Failed or disconnected transport.
        case connectionInterrupted
    }

    enum Recovery: Equatable, Sendable {
        /// Bounded automatic retry in progress ("Reconnecting n/3").
        case reconnecting(label: String)
        /// Manual reconnect button.
        case reconnectButton
    }

    struct Interruption: Equatable, Sendable {
        let kind: InterruptionKind
        let title: String
        let message: String
        let recovery: Recovery
    }

    enum Overlay: Equatable, Sendable {
        case hidden
        /// Compact spinner pill while the session is preparing or waiting for video.
        case progress(label: String)
        case interruption(Interruption)
    }

    static let reconnectAttemptLimit = 3

    let connectionLabel: String
    let connectionTone: RemoteTone
    /// Video is flowing on a connected session; the status dot pulses.
    let isLive: Bool
    let modeLabel: String
    let modeTone: RemoteTone
    let media: ControllerMediaRole
    let isControlMode: Bool
    /// Control is negotiated and video is fresh; the Control segment is selectable.
    let canSelectControl: Bool
    /// Screen source, Control selected and allowed: remote input, Home and Keyboard are enabled.
    let controlsEnabled: Bool
    let overlay: Overlay
    let viewportHint: String

    init(_ snapshot: RemoteSessionSnapshot) {
        connectionLabel = Self.connectionLabel(snapshot)
        connectionTone = Self.connectionTone(snapshot)
        isLive = snapshot.state == .connected && snapshot.videoAvailable && snapshot.videoHealth == .flowing
        media = snapshot.media
        isControlMode = snapshot.interactionMode == .control
        canSelectControl = snapshot.canControl
        controlsEnabled = snapshot.media == .screen && snapshot.canControl && snapshot.interactionMode == .control
        if snapshot.media == .camera {
            modeLabel = "CAMERA"
            modeTone = .text
        } else if snapshot.interactionMode == .control {
            modeLabel = "CONTROL"
            modeTone = .accent
        } else {
            modeLabel = "VIEW ONLY"
            modeTone = .secondary
        }
        overlay = Self.overlay(snapshot, connectionLabel: connectionLabel)
        viewportHint = controlsEnabled ? "Touches control the remote device" : "Select Control to enable remote input"
    }

    /// Spoken form of the mode chip ("View only" instead of the uppercase chip text).
    var modeAccessibilityValue: String {
        switch modeLabel {
        case "CAMERA": "Camera"
        case "CONTROL": "Control"
        default: "View only"
        }
    }

    private static func connectionLabel(_ snapshot: RemoteSessionSnapshot) -> String {
        switch snapshot.state {
        case .idle: "Ready"
        case .signaling: snapshot.isLocal ? "Connecting locally" : "Authorizing"
        case .connecting: "Connecting"
        case .connected:
            if snapshot.videoHealth == .stalled {
                "Video paused"
            } else if !snapshot.videoAvailable {
                "Waiting for video"
            } else {
                snapshot.media == .camera ? "Live camera" : "Live screen"
            }
        case .disconnected: "Disconnected"
        case .failed: "Connection failed"
        case .closed: "Closed"
        }
    }

    private static func connectionTone(_ snapshot: RemoteSessionSnapshot) -> RemoteTone {
        switch snapshot.state {
        case .connected: snapshot.videoHealth == .flowing ? .success : .accent
        case .failed, .disconnected: .danger
        case .signaling, .connecting: .accent
        case .idle, .closed: .tertiary
        }
    }

    private static func overlay(_ snapshot: RemoteSessionSnapshot, connectionLabel: String) -> Overlay {
        let interrupted = [.closed, .failed, .disconnected].contains(snapshot.state)
        guard interrupted || snapshot.videoHealth == .stalled else {
            return snapshot.videoAvailable ? .hidden : .progress(label: connectionLabel)
        }
        let kind: InterruptionKind = snapshot.state == .closed
            ? .sessionEnded
            : (snapshot.videoHealth == .stalled ? .videoPaused : .connectionInterrupted)
        let title = switch kind {
        case .sessionEnded: "Session ended"
        case .videoPaused: "Video paused"
        case .connectionInterrupted: "Connection interrupted"
        }
        // Stalled video explains itself first; a closed session keeps a
        // model-provided reason (e.g. changed controller access) visible.
        let message: String
        if snapshot.videoHealth == .stalled {
            message = "No fresh frames. Control is disabled."
        } else if snapshot.state == .closed {
            message = snapshot.errorMessage ?? "Reconnect to start a new session."
        } else {
            message = snapshot.errorMessage ?? "The device connection was interrupted."
        }
        let recovery: Recovery = snapshot.reconnecting
            ? .reconnecting(label: "Reconnecting \(snapshot.reconnectAttempt)/\(reconnectAttemptLimit)")
            : .reconnectButton
        return .interruption(Interruption(kind: kind, title: title, message: message, recovery: recovery))
    }
}

/// Read-only facts about the session's route. Deliberately factual: LAN is a
/// trusted network, not an authenticated pairing, and Relay is a route.
struct RemoteAccessPathPresentation: Equatable {
    let isLocal: Bool
    /// Badge text ("LAN" / "Relay").
    let badgeText: String
    let accessibilityLabel: String
    let pathDescription: String
    let endpoint: String
    let trust: String
    let trustTone: RemoteTone

    init(_ path: RemoteAccessPath) {
        switch path {
        case let .lan(address):
            isLocal = true
            endpoint = address.displayAddress
        case let .relay(origin):
            isLocal = false
            if let origin, let host = URLComponents(string: origin)?.host {
                endpoint = host
            } else {
                endpoint = origin ?? "Unavailable"
            }
        }
        badgeText = path.label
        accessibilityLabel = isLocal ? "Connection path: local network" : "Connection path: relay"
        pathDescription = isLocal ? "Local network" : "Relay"
        trust = isLocal ? "Trusted network · not paired" : "Authenticated controller"
        trustTone = isLocal ? .accent : .success
    }
}

/// Formatted live transport metrics. Unknown values stay "Unavailable", never zero.
struct RemoteDiagnosticsPresentation: Equatable {
    struct Metric: Equatable {
        let title: String
        let value: String
    }

    static let unavailable = "Unavailable"

    let framesPerSecond: Metric
    let bitrate: Metric
    let packetLoss: Metric
    let roundTrip: Metric
    let route: Metric

    var metrics: [Metric] { [framesPerSecond, bitrate, packetLoss, roundTrip, route] }

    init(_ diagnostics: RctlRealtimeDiagnostics, locale: Locale = .current) {
        let whole = Self.formatter(fractionDigits: 0, locale: locale)
        let tenths = Self.formatter(fractionDigits: 1, locale: locale)
        func format(_ value: Double?, _ formatter: NumberFormatter, suffix: String) -> String {
            guard let value, value.isFinite, let text = formatter.string(from: NSNumber(value: value)) else {
                return Self.unavailable
            }
            return text + suffix
        }
        framesPerSecond = Metric(title: "Decoded FPS", value: format(diagnostics.framesPerSecond, tenths, suffix: ""))
        bitrate = Metric(title: "Video bitrate", value: format(diagnostics.bitsPerSecond.map { $0 / 1000 }, whole, suffix: " kbps"))
        packetLoss = Metric(title: "Packet loss", value: format(diagnostics.packetLossPercent, tenths, suffix: "%"))
        roundTrip = Metric(title: "RTT", value: format(diagnostics.roundTripMilliseconds, whole, suffix: " ms"))
        route = Metric(title: "Media route", value: diagnostics.route.rawValue)
    }

    private static func formatter(fractionDigits: Int, locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.roundingMode = .halfEven
        return formatter
    }
}

/// State of the Session Controls sheet.
struct RemoteToolsPresentation: Equatable {
    let diagnostics: RemoteDiagnosticsPresentation
    /// Hardware actions and Lock require Control on the screen source.
    let actionsEnabled: Bool
}
