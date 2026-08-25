import Foundation
import Testing
@testable import RctlProtocol

@Suite("Capabilities contract")
struct CapabilitiesTests {
    @Test("Device fixture decodes and validates")
    func deviceFixture() throws {
        let capabilities = try fixture("device-v1.json")

        #expect(capabilities.component == "daemon")
        #expect(capabilities.daemon?.version == "0.3.3")
        #expect(capabilities.features.contains("screen.webrtc"))
        #expect(WireProtocolVersion.current.compatibility(with: capabilities.protocolVersion).canConnect)
    }

    @Test("Relay fixture decodes and validates")
    func relayFixture() throws {
        let capabilities = try fixture("relay-v1.json")

        #expect(capabilities.component == "relay")
        #expect(capabilities.relay?.version == "0.3.3")
        #expect(capabilities.features.contains("webrtc.signaling"))
    }

    @Test("Future minor and unknown fields remain connectable")
    func futureMinor() throws {
        let capabilities = try fixture("future-minor-v1.json")
        let compatibility = WireProtocolVersion.current.compatibility(with: capabilities.protocolVersion)

        #expect(compatibility == .minorDifference(local: WireProtocolVersion.current.minor, remote: 7))
        #expect(compatibility.canConnect)
        #expect(capabilities.features.contains("future.unknown_feature"))
    }

    @Test("A different major is fatal")
    func incompatibleMajor() {
        let compatibility = WireProtocolVersion.current.compatibility(
            with: WireProtocolVersion(major: 2, minor: 0)
        )

        #expect(compatibility == .incompatibleMajor(local: 1, remote: 2))
        #expect(!compatibility.canConnect)
    }

    @Test("Unknown capability components fail visibly")
    func unsupportedComponent() throws {
        let payload = """
        {
          "product": "rctl",
          "component": "future-component",
          "protocol": { "major": 1, "minor": 0 },
          "features": []
        }
        """
        let capabilities = try JSONDecoder().decode(Capabilities.self, from: Data(payload.utf8))

        #expect(throws: CapabilitiesValidationError.unsupportedComponent) {
            try capabilities.validated()
        }
    }

    private func fixture(_ name: String) throws -> Capabilities {
        let data = try Data(contentsOf: try fixtureURL(name))
        return try JSONDecoder().decode(Capabilities.self, from: data).validated()
    }

    private func fixtureURL(_ name: String) throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory
                .appendingPathComponent("protocol/fixtures/capabilities", isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw FixtureError.notFound(name)
    }

    private enum FixtureError: Error {
        case notFound(String)
    }
}
