import Foundation
import Testing
@testable import RctlClient

@Suite("Controller client profile")
struct ControllerClientProfileTests {
    @Test("Profile encodes relay keys, omits nils and stays within bounds")
    func encoding() throws {
        var profile = ControllerClientProfile()
        profile.model = "iPhone15,2"
        profile.modelName = "iPhone 14 Pro"
        profile.deviceName = "  " + String(repeating: "n", count: 120) + "\n"
        profile.cpuCount = 6
        profile.memoryBytes = -1
        let json = try JSONSerialization.jsonObject(with: profile.canonicalJSON()) as? [String: Any]
        let object = try #require(json)
        #expect(object["model"] as? String == "iPhone15,2")
        #expect(object["model_name"] as? String == "iPhone 14 Pro")
        #expect((object["device_name"] as? String)?.count == 80)
        #expect(object["cpu_count"] as? Int == 6)
        #expect(object["memory_bytes"] == nil, "negative numbers are dropped, not sent")
        #expect(object["system_version"] == nil, "nil fields are omitted")
        #expect(Set(object.keys) == ["model", "model_name", "device_name", "cpu_count"])
    }

    @Test("Fingerprint changes only when the bounded profile changes")
    func fingerprint() {
        var first = ControllerClientProfile()
        first.appVersion = "1.2.0"
        var same = first
        same.deviceName = "   "
        #expect(first.fingerprint == same.fingerprint)
        var changed = first
        changed.appVersion = "1.3.0"
        #expect(first.fingerprint != changed.fingerprint)
        #expect(!first.fingerprint.isEmpty)
    }

    @Test("Profile and telemetry requests are signed over their JSON bodies")
    func requests() throws {
        var scalar = Data(repeating: 0, count: 32)
        scalar[31] = 7
        let key = try ControllerSigningKey(softwareRawRepresentation: scalar)
        var profile = ControllerClientProfile()
        profile.model = "iPad14,1"
        let client = ControllerAPIClient()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let profileBody = try encoder.encode(["client": profile])
        let request = try client.makeControllerActionRequest(
            path: "/api/controller/me/client", origin: "https://relay.example",
            body: profileBody, accessToken: "cat_example.secret", signingKey: key)
        #expect(request.url?.absoluteString == "https://relay.example/api/controller/me/client")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == profileBody)
        #expect(String(decoding: try #require(request.httpBody), as: UTF8.self) == #"{"client":{"model":"iPad14,1"}}"#)
        #expect(request.value(forHTTPHeaderField: "X-RCTL-Signature") != nil)

        let telemetry = ControllerTelemetry(batteryLevel: 81, batteryState: "charging", lowPower: false, network: "wifi")
        let telemetryBody = try encoder.encode(["telemetry": telemetry])
        #expect(String(decoding: telemetryBody, as: UTF8.self) == #"{"telemetry":{"battery_level":81,"battery_state":"charging","low_power":false,"network":"wifi"}}"#)

        let empty = try client.makeControllerActionRequest(
            path: "/api/controller/presence", origin: "https://relay.example",
            body: Data(), accessToken: "cat_example.secret", signingKey: key)
        #expect(empty.value(forHTTPHeaderField: "Content-Type") == nil)
    }
}
