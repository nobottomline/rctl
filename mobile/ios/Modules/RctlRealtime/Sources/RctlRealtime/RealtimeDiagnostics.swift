import Foundation
@preconcurrency import LiveKitWebRTC

public enum RctlVideoHealth: String, Sendable {
    case waiting, flowing, stalled
}

public enum RctlMediaRoute: String, Sendable {
    case unknown = "Unknown"
    case direct = "Direct"
    case turn = "TURN"
}

public struct RctlRealtimeDiagnostics: Equatable, Sendable {
    public var framesPerSecond: Double?
    public var bitsPerSecond: Double?
    public var packetLossPercent: Double?
    public var roundTripMilliseconds: Double?
    public var route: RctlMediaRoute = .unknown
    public init() {}
}

struct VideoFreshness {
    static let staleAfter: TimeInterval = 3
    private(set) var lastFrame: TimeInterval?

    mutating func frame(at time: TimeInterval) {
        if time.isFinite, time >= (lastFrame ?? 0) { lastFrame = time }
    }

    func health(at now: TimeInterval) -> RctlVideoHealth {
        guard let lastFrame else { return .waiting }
        return (0..<Self.staleAfter).contains(now - lastFrame) ? .flowing : .stalled
    }
}

struct VideoStatisticsSample: Sendable {
    var source: String?
    var timestamp: TimeInterval
    var frames: Double?
    var bytes: Double?
    var received: Double?
    var lost: Double?
    var rtt: Double?
    var route: RctlMediaRoute = .unknown

    init(report: LKRTCStatisticsReport) {
        let all = report.statistics
        let video = all.values.first {
            $0.type == "inbound-rtp" &&
                (($0.values["kind"] as? String ?? $0.values["mediaType"] as? String) == "video")
        }
        source = video?.id
        timestamp = (video?.timestamp_us ?? report.timestamp_us) / 1_000_000
        let values = video?.values ?? [:]
        frames = Self.number(values["framesDecoded"])
        bytes = Self.number(values["bytesReceived"])
        received = Self.number(values["packetsReceived"])
        lost = Self.number(values["packetsLost"])
        // Follow the selected transport, never an arbitrary succeeded pair.
        let transport = (values["transportId"] as? String).flatMap { all[$0] }
            ?? all.values.first { $0.type == "transport" }
        let pair = (transport?.values["selectedCandidatePairId"] as? String).flatMap { all[$0] }
        rtt = Self.number(pair?.values["currentRoundTripTime"])
        let local = (pair?.values["localCandidateId"] as? String).flatMap { all[$0] }
        let remote = (pair?.values["remoteCandidateId"] as? String).flatMap { all[$0] }
        let types = [local?.values["candidateType"] as? String, remote?.values["candidateType"] as? String]
        if types.contains("relay") { route = .turn }
        else if types.allSatisfy({ $0 != nil }), pair != nil { route = .direct }
    }

    init(source: String?, timestamp: TimeInterval, frames: Double?, bytes: Double?,
         received: Double?, lost: Double?, rtt: Double? = nil, route: RctlMediaRoute = .unknown) {
        self.source = source; self.timestamp = timestamp; self.frames = frames
        self.bytes = bytes; self.received = received; self.lost = lost
        self.rtt = rtt; self.route = route
    }

    private static func number(_ value: Any?) -> Double? {
        let value = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return value?.isFinite == true ? value : nil
    }
}

struct VideoStatisticsAccumulator {
    private var previous: VideoStatisticsSample?

    mutating func update(_ sample: VideoStatisticsSample) -> RctlRealtimeDiagnostics {
        defer { previous = sample }
        var result = RctlRealtimeDiagnostics()
        result.route = sample.route
        result.roundTripMilliseconds = sample.rtt.flatMap { $0 >= 0 ? $0 * 1000 : nil }
        guard let previous, let source = sample.source, source == previous.source,
              sample.timestamp > previous.timestamp else { return result }
        let elapsed = sample.timestamp - previous.timestamp
        func delta(_ current: Double?, _ old: Double?) -> Double? {
            guard let current, let old, current >= old else { return nil }
            return current - old
        }
        result.framesPerSecond = delta(sample.frames, previous.frames).map { $0 / elapsed }
        result.bitsPerSecond = delta(sample.bytes, previous.bytes).map { $0 * 8 / elapsed }
        if let received = delta(sample.received, previous.received),
           let currentLost = sample.lost, let oldLost = previous.lost {
            // Late packets can reduce the cumulative lost counter.
            let lost = max(0, currentLost - oldLost)
            if received + lost > 0 { result.packetLossPercent = lost / (received + lost) * 100 }
        }
        return result
    }
}
