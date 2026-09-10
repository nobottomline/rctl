import Foundation
import Testing
@testable import RctlRealtime

@Suite("Local discovery boundary")
struct LocalDiscoveryTests {
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["RCTL_DISCOVERY_TEST_NAME"] != nil))
    func liveBonjourWhenExplicitlyConfigured() async throws {
        let name = try #require(ProcessInfo.processInfo.environment["RCTL_DISCOVERY_TEST_NAME"])
        let identity = try LocalServiceIdentity(name: name, type: "_rctl._tcp", domain: "local.")
        let resolver = LocalDeviceResolver()
        let resolved = try await resolver.resolve(identity, interfaceIndex: 0)
        #expect(resolved.record.compatible)
        #expect(!resolved.address.host.contains(":"))
        _ = try await LocalDeviceClient().capabilities(at: resolved.address)
        let browser = LocalDeviceBrowser()
        browser.start()
        defer { browser.stop() }
        let end = ContinuousClock.now + .seconds(20)
        while !browser.devices.contains(where: { $0.id == identity && $0.endpoint != nil }), ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(browser.devices.contains(where: { $0.id == identity && $0.endpoint != nil }))
        browser.stop()
        #expect(browser.devices.isEmpty)
        #expect(browser.state == .stopped)
    }

    @Test func contractFixtures() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("protocol/fixtures/discovery-v1.json").path) {
            let parent = root.deletingLastPathComponent()
            guard parent != root else { throw LocalDiscoveryError.unavailable }
            root = parent
        }
        struct Fixture: Decodable { let name: String; let hex: String; let valid: Bool; let major: Int?; let minor: Int? }
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/discovery-v1.json"))
        for fixture in try JSONDecoder().decode([Fixture].self, from: data) {
            let hex = Array(fixture.hex)
            let bytes = try stride(from: 0, to: hex.count, by: 2).map { index -> UInt8 in
                guard let byte = UInt8(String(hex[index..<index + 2]), radix: 16) else { throw LocalDiscoveryError.malformedRecord }
                return byte
            }
            if fixture.valid {
                let record = try LocalDiscoveryRecord(data: Data(bytes))
                #expect(record.major == fixture.major, "\(fixture.name)")
                #expect(record.minor == fixture.minor, "\(fixture.name)")
            } else {
                #expect(throws: LocalDiscoveryError.malformedRecord, "\(fixture.name)") { try LocalDiscoveryRecord(data: Data(bytes)) }
            }
        }
    }

    @Test func sizeAndVersionLimits() throws {
        func txt(_ entries: [String]) -> Data {
            Data(entries.flatMap { [UInt8($0.utf8.count)] + $0.utf8 })
        }
        #expect(throws: LocalDiscoveryError.malformedRecord) {
            try LocalDiscoveryRecord(data: Data(repeating: 1, count: 401))
        }
        let largest = txt(["txtvers=1", "pv=1.1", "x=" + String(repeating: "a", count: 253),
                           "y=" + String(repeating: "b", count: 124)])
        #expect(largest.count == 400)
        #expect(try LocalDiscoveryRecord(data: largest).major == 1)
        #expect(throws: LocalDiscoveryError.malformedRecord) {
            try LocalDiscoveryRecord(data: largest + Data([0]))
        }
        for version in ["1", "1.2.3", "1.-1", "1.01", "65536.0", "1.65536", "1. 2", "1.\u{0}", "١.١"] {
            #expect(throws: LocalDiscoveryError.malformedRecord) {
                try LocalDiscoveryRecord(data: txt(["txtvers=1", "pv=\(version)"]))
            }
        }
        #expect(try LocalDiscoveryRecord(data: txt(["txtvers=1", "pv=65535.65535"])).minor == 65535)
        #expect(throws: LocalDiscoveryError.malformedRecord) {
            try LocalDiscoveryRecord(data: txt(["txtvers=1", "pv=1.1", "x=y", "X=z"]))
        }
    }

    @Test func identityDoesNotMergeSameNamesOrAcceptOtherDomains() throws {
        let first = try LocalServiceIdentity(name: "rctl", type: "_rctl._tcp.", domain: "LOCAL.")
        #expect(first == (try LocalServiceIdentity(name: "rctl", type: "_rctl._tcp", domain: "local.")))
        #expect(first != (try LocalServiceIdentity(name: "rctl (2)", type: "_rctl._tcp", domain: "local.")))
        for name in ["", String(repeating: "a", count: 64), "rctl\nother", "rctl\0"] {
            #expect(throws: LocalDiscoveryError.malformedRecord) {
                try LocalServiceIdentity(name: name, type: "_rctl._tcp", domain: "local.")
            }
        }
        #expect(throws: LocalDiscoveryError.malformedRecord) {
            try LocalServiceIdentity(name: "rctl", type: "_https._tcp", domain: "local.")
        }
        #expect(throws: LocalDiscoveryError.malformedRecord) {
            try LocalServiceIdentity(name: "rctl", type: "_rctl._tcp", domain: "example.com.")
        }
    }

    @MainActor @Test func cancellationBeforeDNSAndEmptyInterfaces() async throws {
        let resolver = LocalDeviceResolver()
        let identity = try LocalServiceIdentity(name: "synthetic", type: "_rctl._tcp", domain: "local.")
        let task = Task { try await resolver.resolve(identity, interfaceIndex: 0) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: LocalDiscoveryError.unsupportedNetwork) {
            try await resolver.resolve(identity, interfaceIndices: [])
        }
        resolver.cancelAll()
        let browser = LocalDeviceBrowser()
        browser.stop(); browser.stop()
        #expect(browser.state == .stopped)
        #expect(browser.devices.isEmpty)
    }
}
