public enum RctlRealtimeConnectionState: String, Equatable, Sendable {
    case idle
    case signaling
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

public enum RctlRealtimeChannelState: String, Equatable, Sendable {
    case connecting
    case open
    case closing
    case closed
}

public enum RctlRealtimeEvent: Equatable, Sendable {
    case connection(RctlRealtimeConnectionState)
    case firstVideoFrame
    case orientation(Int)
    case channel(label: String, state: RctlRealtimeChannelState)
    case failure(RctlRealtimeError)
}
