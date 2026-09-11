import Foundation
import RctlRealtime
import SwiftUI
import UIKit
import XCTest
@testable import RCTL_Controller

@MainActor
final class LocalDeviceTests: XCTestCase {
    private let capabilities = #"{"component":"daemon","product":"rctl","daemon":{"version":"test"},"browser":{"version":"test"},"protocol":{"major":1,"minor":1},"features":["screen.webrtc"]}"#

    func testAccessPathSurvivesAllConnectionStates() throws {
        let address = try LocalDeviceAddress("192.168.1.2")
        let local = RemoteSessionModel(appModel: ControllerAppModel(), target: .local(address))
        let relay = RemoteSessionModel(appModel: ControllerAppModel(), deviceID: "synthetic")
        for state in [RctlRealtimeConnectionState.idle, .signaling, .connected, .disconnected, .failed, .closed] {
            local.handle(.connection(state)); relay.handle(.connection(state))
            XCTAssertEqual(local.accessPath, .lan(address))
            XCTAssertEqual(local.accessPath.label, "LAN")
            XCTAssertEqual(relay.accessPath.label, "Relay")
        }
        local.suspend(); local.disconnect()
        XCTAssertEqual(local.accessPath.endpoint, "192.168.1.2:8080")
    }

    func testDiscoveryOptInDoesNotBrowseInBackgroundOrChangeSavedStore() {
        let suite = "rctl.local.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LocalDevicesModel(defaults: defaults)
        XCTAssertFalse(model.discoveryEnabled)
        model.setDiscoveryEnabled(true)
        XCTAssertEqual(model.discoveryState, .stopped)
        XCTAssertTrue(model.nearby.isEmpty)
        XCTAssertTrue(LocalDevicesModel(defaults: defaults).discoveryEnabled)
        model.setForeground(false)
        model.setDiscoveryEnabled(false)
        XCTAssertNil(defaults.data(forKey: "rctl.controller.local-devices.v1"))
    }

    func testConfirmedAddressReplacementPreservesIdentityAndName() async throws {
        let suite = "rctl.local.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = LocalDeviceProfile(id: UUID(), name: "Saved name", address: try LocalDeviceAddress("192.168.1.2"))
        defaults.set(try JSONEncoder().encode([original]), forKey: "rctl.controller.local-devices.v1")
        let model = LocalDevicesModel(defaults: defaults, client: client())
        let change = Task { try await model.save(address: "192.168.1.3", name: original.name, editing: original.id) }
        let request = try await pendingRequest()
        XCTAssertEqual(model.devices, [original])
        request.respond(capabilities)
        let replaced = try await change.value
        XCTAssertEqual(replaced.id, original.id)
        XCTAssertEqual(replaced.name, original.name)
        XCTAssertEqual(model.devices.count, 1)
        XCTAssertEqual(replaced.address.displayAddress, "192.168.1.3:8080")
    }

    func testReachabilityHasFourRequestBudgetAndStopsOnBackground() async throws {
        let suite = "rctl.local.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = try (1...12).map { index in
            LocalDeviceProfile(id: UUID(), name: "Synthetic \(index)", address: try LocalDeviceAddress("192.168.1.\(index)"))
        }
        defaults.set(try JSONEncoder().encode(saved), forKey: "rctl.controller.local-devices.v1")
        let model = LocalDevicesModel(defaults: defaults, client: client())
        model.setForeground(true)
        let probe = Task { await model.probeReachability() }
        var requests: [RequestStub] = []
        for _ in 0..<4 { requests.append(try await pendingRequest()) }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(RequestStub.requests.take("/v1/capabilities"))
        model.setForeground(false)
        for request in requests { request.respond(capabilities) }
        await probe.value
        XCTAssertNil(RequestStub.requests.take("/v1/capabilities"))
    }

    func testLocalScreensRenderWithoutRelay() async throws {
        let suite = "rctl.local.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = LocalDevicesModel(defaults: defaults)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let saved = LocalDeviceProfile(id: UUID(), name: "Saved iPad", address: try LocalDeviceAddress("192.168.1.2"))
        let found = LocalDeviceProfile(id: UUID(), name: "Kitchen iPad", address: try LocalDeviceAddress("192.168.1.30"))
        for (name, view) in [
            ("local-device-list", AnyView(DeviceListView(model: ControllerAppModel(), localDevices: local))),
            ("local-device-editor", AnyView(LocalDeviceEditor(model: local) { _ in })),
            ("local-device-save-discovered", AnyView(LocalDeviceEditor(model: local, suggested: found) { _ in })),
            ("local-device-replace-address", AnyView(LocalDeviceEditor(model: local, editing: saved, suggested: found) { _ in })),
            ("nearby-device-sheet", AnyView(NearbyDeviceSheet(profile: found, savedDevices: [saved], open: {}, save: {}, replace: { _ in }))),
            ("nearby-section-opt-in", AnyView(NearbySection(localDevices: local, select: { _ in }, replace: { _, _ in }, addByAddress: {}))),
        ] {
            let host = UIHostingController(rootView: view)
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(400))
            host.view.layoutIfNeeded()
            XCTAssertGreaterThan(host.view.bounds.width, 0)
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testCorruptLocalStoreDoesNotAdmitPublicTargets() {
        let suite = "rctl.local.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = Data(#"[{"id":"00000000-0000-0000-0000-000000000001","name":"Invalid","address":"https://example.com"}]"#.utf8)
        defaults.set(data, forKey: "rctl.controller.local-devices.v1")
        let local = LocalDevicesModel(defaults: defaults)
        XCTAssertTrue(local.devices.isEmpty)
        XCTAssertNotNil(local.errorMessage)
        XCTAssertEqual(defaults.data(forKey: "rctl.controller.local-devices.v1"), data)
    }

    func testSavesMultipleAddressesWithoutRelayAndDeduplicates() async throws {
        let suite = "rctl.local.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LocalDevicesModel(defaults: defaults, client: client())
        let first = Task { try await model.save(address: "192.168.1.2", name: "First") }
        let request1 = try await pendingRequest()
        XCTAssertNil(request1.request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request1.request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request1.request.value(forHTTPHeaderField: "X-RCTL-Signature"))
        request1.respond(capabilities)
        let device1 = try await first.value
        let second = Task { try await model.save(address: "192.168.1.3", name: "Second") }
        let request2 = try await pendingRequest()
        request2.respond(capabilities)
        let device2 = try await second.value
        XCTAssertNotEqual(device1.id, device2.id)
        XCTAssertEqual(device1.address.port, device2.address.port)
        let duplicate = Task { try await model.save(address: "http://192.168.1.2:8080/", name: "Renamed") }
        let request3 = try await pendingRequest()
        request3.respond(capabilities)
        let renamed = try await duplicate.value
        XCTAssertEqual(renamed.id, device1.id)
        XCTAssertEqual(model.devices.count, 2)
        let restored = LocalDevicesModel(defaults: defaults)
        XCTAssertEqual(restored.devices, model.devices)
        model.remove(device1)
        XCTAssertEqual(model.devices.map(\.id), [device2.id])
        XCTAssertNil(defaults.data(forKey: "rctl.controller.profile.v1"))
    }

    func testCancelledAddNeverPersists() async throws {
        let suite = "rctl.local.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LocalDevicesModel(defaults: defaults, client: client())
        let save = Task { try await model.save(address: "192.168.1.2", name: "Cancelled") }
        let request = try await pendingRequest()
        save.cancel()
        request.respond(capabilities)
        do { _ = try await save.value; XCTFail("Cancelled add succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertNil(defaults.data(forKey: "rctl.controller.local-devices.v1"))
    }

    func testBoundedCapabilitiesAndCompatibilityFailures() async throws {
        for (body, status, expected) in [
            (String(repeating: "x", count: 65537), 200, LocalConnectionError.responseTooLarge),
            (capabilities, 302, .redirect),
            (capabilities, 404, .http(404)),
            ("{}", 200, .invalidResponse),
            (capabilities.replacingOccurrences(of: "\"major\":1", with: "\"major\":9"), 200, .incompatibleProtocol),
            (capabilities.replacingOccurrences(of: "screen.webrtc", with: "other"), 200, .unsupportedMedia),
        ] {
            let client = client()
            let task = Task { try await client.capabilities(at: LocalDeviceAddress("192.168.1.2")) }
            let request = try await pendingRequest()
            request.respond(body, status: status)
            do { _ = try await task.value; XCTFail("Invalid response was accepted") }
            catch { XCTAssertEqual(error as? LocalConnectionError, expected) }
        }
    }

    func testLocalCapabilityCancellationOnViewTaskExit() async throws {
        let client = client()
        let model = RemoteSessionModel(appModel: ControllerAppModel(),
            target: .local(try LocalDeviceAddress("192.168.1.2")), localClient: client)
        let connect = Task { await model.connect() }
        let request = try await pendingRequest()
        model.suspend()
        request.respond(capabilities)
        await connect.value
        XCTAssertEqual(model.state, .closed)
        XCTAssertFalse(model.canControl)
        XCTAssertNil(model.errorMessage)
    }

    func testLiveLANVideoWhenExplicitlyConfigured() async throws {
        guard let input = ProcessInfo.processInfo.environment["RCTL_LAN_TEST_ADDRESS"], !input.isEmpty else {
            throw XCTSkip("Set RCTL_LAN_TEST_ADDRESS to qualify a real owned device; this test only views video.")
        }
        let address = try LocalDeviceAddress(input)
        _ = try await LocalDeviceClient().capabilities(at: address)
        let model = RemoteSessionModel(appModel: ControllerAppModel(), target: .local(address))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let video = RctlRemoteVideoView(frame: scene.coordinateSpace.bounds)
        controller.view = video
        window.rootViewController = controller
        window.makeKeyAndVisible()
        model.session.attachVideo(to: video)
        defer {
            model.disconnect()
            model.session.detachVideo(from: video)
            window.isHidden = true
        }
        await model.connect()
        let deadline = ContinuousClock.now + .seconds(20)
        while !model.videoAvailable, model.state != .failed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(model.state, .connected, model.errorMessage ?? "No connection")
        XCTAssertTrue(model.videoAvailable, model.errorMessage ?? "No decoded frame")
        XCTAssertEqual(model.interactionMode, .view)
        let diagnosticsDeadline = ContinuousClock.now + .seconds(6)
        while model.diagnostics.framesPerSecond == nil, ContinuousClock.now < diagnosticsDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(model.diagnostics.framesPerSecond)
        XCTAssertNotNil(model.diagnostics.bitsPerSecond)
        XCTAssertEqual(model.diagnostics.route, .direct)
        XCTAssertEqual(model.videoHealth, .flowing)
        XCTAssertNotNil(video.normalizedRemotePoint(for: CGPoint(x: video.bounds.midX, y: video.bounds.midY)))
        model.suspend()
        await model.resume()
        let reconnectDeadline = ContinuousClock.now + .seconds(20)
        while !model.videoAvailable, model.state != .failed, ContinuousClock.now < reconnectDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(model.state, .connected, model.errorMessage ?? "Reconnect failed")
        XCTAssertTrue(model.videoAvailable)
        XCTAssertEqual(model.interactionMode, .view)
    }

    private func client() -> LocalDeviceClient {
        RequestStub.requests.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RequestStub.self]
        config.httpAdditionalHeaders = ["Authorization": "must-not-leak", "Cookie": "must-not-leak"]
        return LocalDeviceClient(configuration: config)
    }

    private func pendingRequest() async throws -> RequestStub {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let request = RequestStub.requests.take("/v1/capabilities") { return request }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Local capabilities request did not start")
        throw URLError(.timedOut)
    }
}
