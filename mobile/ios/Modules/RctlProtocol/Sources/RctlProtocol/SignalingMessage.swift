import Foundation

public struct WireICEServer: Codable, Equatable, Sendable {
    public let urls: [String]
    public let username: String?
    public let credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    private enum CodingKeys: String, CodingKey {
        case urls
        case username
        case credential
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? values.decode(String.self, forKey: .urls) {
            urls = [value]
        } else {
            urls = try values.decode([String].self, forKey: .urls)
        }
        username = try values.decodeIfPresent(String.self, forKey: .username)
        credential = try values.decodeIfPresent(String.self, forKey: .credential)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if urls.count == 1 {
            try values.encode(urls[0], forKey: .urls)
        } else {
            try values.encode(urls, forKey: .urls)
        }
        try values.encodeIfPresent(username, forKey: .username)
        try values.encodeIfPresent(credential, forKey: .credential)
    }

    fileprivate func validated() throws -> Self {
        guard (1...8).contains(urls.count),
              urls.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2_048 }) else {
            throw WireValidationError.invalidField("ice.urls")
        }
        guard username.map({ $0.utf8.count <= 256 }) ?? true else {
            throw WireValidationError.invalidField("ice.username")
        }
        guard credential.map({ $0.utf8.count <= 1_024 }) ?? true else {
            throw WireValidationError.invalidField("ice.credential")
        }
        return self
    }
}

public enum SignalingMessage: ValidatedWireMessage, Encodable {
    case ready([WireICEServer])
    case offer(sdp: String)
    case answer(sdp: String)
    case candidate(candidate: String, mid: String)

    public static let maximumJSONBytes = WireLimits.signalingJSONBytes

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    private struct SessionDescription: Codable {
        let sdp: String
    }

    private struct Candidate: Codable {
        let candidate: String
        let mid: String
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .kind) {
        case "ready":
            self = .ready(try values.decode([WireICEServer].self, forKey: .payload))
        case "offer":
            self = .offer(sdp: try values.decode(SessionDescription.self, forKey: .payload).sdp)
        case "answer":
            self = .answer(sdp: try values.decode(SessionDescription.self, forKey: .payload).sdp)
        case "candidate":
            let payload = try values.decode(Candidate.self, forKey: .payload)
            self = .candidate(candidate: payload.candidate, mid: payload.mid)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: values,
                debugDescription: "unknown signaling message kind"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch try validated() {
        case let .ready(servers):
            try values.encode("ready", forKey: .kind)
            try values.encode(servers, forKey: .payload)
        case let .offer(sdp):
            try values.encode("offer", forKey: .kind)
            try values.encode(SessionDescription(sdp: sdp), forKey: .payload)
        case let .answer(sdp):
            try values.encode("answer", forKey: .kind)
            try values.encode(SessionDescription(sdp: sdp), forKey: .payload)
        case let .candidate(candidate, mid):
            try values.encode("candidate", forKey: .kind)
            try values.encode(Candidate(candidate: candidate, mid: mid), forKey: .payload)
        }
    }

    public func validated() throws -> Self {
        switch self {
        case let .ready(servers):
            guard servers.count <= 16 else {
                throw WireValidationError.invalidField("ready.iceServers")
            }
            _ = try servers.map { try $0.validated() }
        case let .offer(sdp), let .answer(sdp):
            guard !sdp.isEmpty, sdp.utf8.count <= WireLimits.signalingJSONBytes else {
                throw WireValidationError.invalidField("sessionDescription.sdp")
            }
        case let .candidate(candidate, mid):
            guard !candidate.isEmpty, candidate.utf8.count <= 4_096 else {
                throw WireValidationError.invalidField("candidate.candidate")
            }
            guard mid.utf8.count <= 256 else {
                throw WireValidationError.invalidField("candidate.mid")
            }
        }
        return self
    }
}
