import Foundation
import Testing
@testable import RctlRealtime

@Suite("Local discovery boundary")
struct LocalDiscoveryTests {
    @Test func missingServicesAreUnavailableAndExpireWithoutResurrection() throws {
        let id = try LocalServiceIdentity(name: "rctl", type: "_rctl._tcp", domain: "local.")
        var catalog = LocalDiscoveryCatalog()
        catalog.update([id: [1]], changed: [id], now: 0)
        let oldRevision = try #require(catalog.entries[id]?.revision)
        let endpoint = try sampleEndpoint()
        catalog.complete(id, revision: oldRevision, result: .success(endpoint), now: 1)
        #expect(catalog.devices.first?.endpoint == endpoint)
        catalog.update([:], changed: [], now: 2)
        #expect(catalog.devices.first?.isPresent == false)
        #expect(catalog.devices.first?.endpoint == nil)
        #expect(catalog.ready(now: 10).isEmpty)
        catalog.complete(id, revision: oldRevision, result: .success(endpoint), now: 3)
        #expect(catalog.devices.first?.endpoint == nil)
        catalog.update([:], changed: [], now: 20)
        catalog.expire(now: 32)
        #expect(catalog.devices.isEmpty)
        catalog.update([id: [2]], changed: [id], now: 33)
        #expect(catalog.devices.first?.isPresent == true)
        #expect(catalog.ready(now: 33).count == 1)
        catalog.complete(id, revision: oldRevision, result: .success(endpoint), now: 34)
        #expect(catalog.devices.first?.endpoint == nil)
    }

    @Test func transientFailuresRetryButInvalidRecordsDoNot() throws {
        let id = try LocalServiceIdentity(name: "rctl", type: "_rctl._tcp", domain: "local.")
        var catalog = LocalDiscoveryCatalog()
        catalog.update([id: [1]], changed: [id], now: 0)
        let revision = try #require(catalog.entries[id]?.revision)
        catalog.complete(id, revision: revision, result: .failure(.timedOut), now: 1)
        #expect(catalog.ready(now: 1.9).isEmpty)
        #expect(catalog.ready(now: 2).count == 1)
        catalog.complete(id, revision: revision, result: .failure(.unavailable), now: 2)
        #expect(catalog.ready(now: 3).isEmpty)
        #expect(catalog.ready(now: 4).count == 1)
        for _ in 0..<20 { catalog.complete(id, revision: revision, result: .failure(.busy), now: 10) }
        #expect(catalog.entries[id]?.retryAt == 40)
        catalog.complete(id, revision: revision, result: .success(try sampleEndpoint()), now: 40)
        #expect(catalog.ready(now: 100).isEmpty)
        for error in [LocalDiscoveryError.malformedRecord, .unsupportedVersion, .unsupportedNetwork] {
            catalog.complete(id, revision: revision, result: .failure(error), now: 100)
            #expect(catalog.ready(now: 1000).isEmpty)
            #expect(catalog.devices.first?.canResolve == false)
        }
    }

    @Test func churnCannotGrowCatalogAndFreshServicesReplaceTombstones() throws {
        var catalog = LocalDiscoveryCatalog()
        let sources = try Dictionary(uniqueKeysWithValues: (0..<64).map {
            (try LocalServiceIdentity(name: "rctl \($0)", type: "_rctl._tcp", domain: "local."), [UInt32(1)])
        })
        catalog.update(sources, changed: Set(sources.keys), now: 0)
        #expect(catalog.devices.count == 64)
        catalog.update([:], changed: [], now: 1)
        let next = try LocalServiceIdentity(name: "new", type: "_rctl._tcp", domain: "local.")
        catalog.update([next: [2]], changed: [next], now: 2)
        #expect(catalog.devices.count == 64)
        #expect(catalog.entries[next]?.device.isPresent == true)
        catalog.expire(now: 31)
        #expect(catalog.devices.count == 1)
    }

    private func sampleEndpoint() throws -> ResolvedLocalDevice {
        let txt = Data(["txtvers=1", "pv=1.1"].flatMap { [UInt8($0.utf8.count)] + $0.utf8 })
        return ResolvedLocalDevice(address: try LocalDeviceAddress("192.168.99.2:8080"),
            record: try LocalDiscoveryRecord(data: txt), interfaceIndex: 1)
    }

    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["RCTL_DISCOVERY_TEST_NAME"] != nil))
    func explicitSelectionKeepsBrowsingAndResolvesAgain() async throws {
        let name = try #require(ProcessInfo.processInfo.environment["RCTL_DISCOVERY_TEST_NAME"])
        let identity = try LocalServiceIdentity(name: name, type: "_rctl._tcp", domain: "local.")
        let browser = LocalDeviceBrowser()
        browser.start()
        defer { browser.stop() }
        let deadline = ContinuousClock.now + .seconds(25)
        while !browser.devices.contains(where: { $0.id == identity }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let discovered = try #require(browser.devices.first { $0.id == identity })
        let resolver = LocalDeviceResolver()
        for _ in 0..<3 {
            browser.setResolutionPaused(true)
            #expect(browser.state == .searching)
            let resolved = try await resolver.resolve(identity, interfaceIndices: discovered.interfaces, userInitiated: true)
            _ = try await LocalDeviceClient().capabilities(at: resolved.address)
            browser.setResolutionPaused(false)
            try await Task.sleep(for: .seconds(6))
        }
    }

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
