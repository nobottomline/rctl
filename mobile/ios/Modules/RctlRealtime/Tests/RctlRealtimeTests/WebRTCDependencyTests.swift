import Testing
@testable import RctlRealtime

@Suite("Pinned WebRTC dependency")
struct WebRTCDependencyTests {
    @Test("Dependency provenance remains pinned")
    func dependencyProvenance() {
        #expect(RctlWebRTCDependency.packageVersion == "144.7559.14")
        #expect(RctlWebRTCDependency.packageRevision.count == 40)
        #expect(RctlWebRTCDependency.artifactSHA256.count == 64)
        #expect(RctlWebRTCDependency.buildCommit.count == 40)
    }

    @Test("Runtime provides an H264 receive path")
    func h264ReceivePath() {
        let factory = RctlPeerConnectionFactory()

        #expect(factory.canDecodeH264)
        #expect(factory.canReceiveVideo)
        #expect(factory.supportedVideoCodecs.contains { codec in
            codec.name.caseInsensitiveCompare("H264") == .orderedSame
        })
    }
}
