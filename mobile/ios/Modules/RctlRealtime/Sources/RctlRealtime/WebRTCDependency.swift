import Foundation
import LiveKitWebRTC

public enum RctlWebRTCDependency: Sendable {
    public static let packageVersion = "144.7559.14"
    public static let packageRevision = "06e2a8a840079ace0dac5d4f2901a12a1d6b9157"
    public static let artifactSHA256 = "4b0a4be4564aa05168a02f262bbbc4d6d9a552aaa1c102229ed5adf1c480b81a"
    public static let buildCommit = "247e0618bd2e1410f21da84d376ac170a2a0b507"
}

public struct RctlVideoCodec: Hashable, Sendable {
    public let name: String
    public let parameters: [String: String]

    public init(name: String, parameters: [String: String]) {
        self.name = name
        self.parameters = parameters
    }
}

/// Owns the vendor WebRTC factory and keeps its prefixed Objective-C API out of
/// the rest of the application.
public final class RctlPeerConnectionFactory: @unchecked Sendable {
    private let encoderFactory: LKRTCDefaultVideoEncoderFactory
    private let decoderFactory: LKRTCDefaultVideoDecoderFactory
    private let factory: LKRTCPeerConnectionFactory

    public init() {
        let encoderFactory = LKRTCDefaultVideoEncoderFactory()
        let decoderFactory = LKRTCDefaultVideoDecoderFactory()

        self.encoderFactory = encoderFactory
        self.decoderFactory = decoderFactory
        factory = LKRTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
    }

    public var supportedVideoCodecs: [RctlVideoCodec] {
        encoderFactory.supportedCodecs().map {
            RctlVideoCodec(name: $0.name, parameters: $0.parameters)
        }
    }

    public var canDecodeH264: Bool {
        decoderFactory.supportedCodecs().contains {
            $0.name.caseInsensitiveCompare("H264") == .orderedSame
        }
    }

    public var canReceiveVideo: Bool {
        !factory.rtpReceiverCapabilities(forKind: kLKRTCMediaStreamTrackKindVideo).codecs.isEmpty
    }

    func makePeerConnection(
        iceServers: [LKRTCIceServer] = [],
        delegate: LKRTCPeerConnectionDelegate
    ) throws -> LKRTCPeerConnection {
        let configuration = LKRTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceServers = iceServers
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        guard let peerConnection = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: delegate
        ) else {
            throw RctlRealtimeError.peerConnectionUnavailable
        }
        return peerConnection
    }
}
