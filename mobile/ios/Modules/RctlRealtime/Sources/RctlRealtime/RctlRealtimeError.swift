import Foundation

public enum RctlRealtimeError: Error, Equatable, Sendable {
    case alreadyRunning
    case invalidSignalingResponse
    case peerConnectionUnavailable
    case negotiationFailed(String)
    case signalingFailed(String)
    case signalingClosed
    case controlChannelUnavailable
    case controlBackpressure
}

extension RctlRealtimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "The realtime session is already running."
        case .invalidSignalingResponse:
            "The relay returned an invalid signaling message."
        case .peerConnectionUnavailable:
            "WebRTC could not create a peer connection."
        case let .negotiationFailed(message):
            "WebRTC negotiation failed: \(message)"
        case let .signalingFailed(message):
            "Relay signaling failed: \(message)"
        case .signalingClosed:
            "Relay signaling closed before the session completed."
        case .controlChannelUnavailable:
            "The control DataChannel is not open."
        case .controlBackpressure:
            "The control DataChannel is congested."
        }
    }
}
