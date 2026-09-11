import Foundation
import RctlClient
import RctlRealtime
import XCTest
@testable import RCTL_Controller

@MainActor
final class ControllerLifecycleTests: XCTestCase {
    func testAccessRefreshKeepsPairingAndClosesNegotiatedSession() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.close() }
        let restore = Task { await fixture.model.restore() }
        try await request("/api/controller/token/refresh").respond(fixture.tokens)
        try await request("/api/controller/devices").respond(Self.devices)
        await restore.value
        let original = try XCTUnwrap(fixture.model.profile)
        let credential = try XCTUnwrap(fixture.keychain.loadCredential(relayID: fixture.relayID))
        let remote = RemoteSessionModel(appModel: fixture.model, deviceID: "test-device")
        remote.handle(.connection(.connected))
        remote.handle(.channel(label: "control", state: .open))
        remote.handle(.videoHealth(.flowing))
        remote.setInteractionMode(.control)

        let refresh = Task { await fixture.model.refreshDevices() }
        try await request("/api/controller/me").respond(#"{"controller":{"id":"ctl_test","name":"Renamed","platform":"ios","scopes":["screen.view","camera"]}}"#)
        try await request("/api/controller/devices").respond(Self.devices)
        await refresh.value
        XCTAssertEqual(fixture.model.profile?.controller.scopes, [.screenView, .camera])
        XCTAssertEqual(fixture.profiles.load()?.controller.name, "Renamed")
        XCTAssertTrue(fixture.model.profile?.hasSameIdentity(as: original) == true)
        XCTAssertEqual(try fixture.keychain.loadCredential(relayID: fixture.relayID)?.refreshToken, credential.refreshToken)
        XCTAssertEqual(remote.state, .closed)
        XCTAssertEqual(remote.interactionMode, .view)
        XCTAssertFalse(remote.canControl)
    }

    func testOldRelayAcknowledgementDoesNotCacheUnacceptedSchema() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.close() }
        let restore = Task { await fixture.model.restore() }
        try await request("/api/controller/token/refresh").respond(fixture.tokens)
        try await request("/api/controller/devices").respond(Self.devices)
        await restore.value
        let profile = try XCTUnwrap(fixture.model.profile)
        fixture.model.syncClientProfile(for: profile)
        try await request("/api/controller/me/client").respond(#"{"ok":true}"#)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(fixture.profiles.reportedClientProfile(relayID: fixture.relayID))
        fixture.model.syncClientProfile(for: profile, force: true)
        try await request("/api/controller/me/client").respond(#"{"ok":true,"accepted_schema_version":2}"#)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNotNil(fixture.profiles.reportedClientProfile(relayID: fixture.relayID))
    }

    func testDeviceProfilePrivacyAndPrivateAddressFilter() {
        let profile = ControllerDeviceProfile.current()
        let telemetry = ControllerDeviceProfile.telemetry(network: .init())
        XCTAssertNil(profile.diskBytes)
        XCTAssertNil(telemetry.diskFreeBytes)
        XCTAssertNil(telemetry.uptimeSeconds)
        XCTAssertNotNil(profile.protocolMinor)
        for address in ["10.0.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.2"] {
            XCTAssertTrue(ControllerDeviceProfile.isPrivateIPv4(address))
        }
        for address in ["8.8.8.8", "172.32.0.1", "127.0.0.1", "::1", "192.168.1.bad.2"] {
            XCTAssertFalse(ControllerDeviceProfile.isPrivateIPv4(address))
        }
    }

    func testFreshVideoIsRequiredAndRecoveryNeverRestoresControl() {
        let model = RemoteSessionModel(appModel: ControllerAppModel(), deviceID: "test-device")
        model.handle(.connection(.connected))
        model.handle(.channel(label: "control", state: .open))
        XCTAssertFalse(model.canControl)
        model.handle(.firstVideoFrame)
        XCTAssertFalse(model.canControl)
        model.setInteractionMode(.control)
        XCTAssertEqual(model.interactionMode, .view)
        model.handle(.videoHealth(.flowing))
        model.setInteractionMode(.control)
        XCTAssertTrue(model.canControl)
        model.handle(.videoHealth(.stalled))
        XCTAssertFalse(model.canControl)
        XCTAssertEqual(model.interactionMode, .view)
        model.handle(.videoHealth(.flowing))
        XCTAssertTrue(model.canControl)
        XCTAssertEqual(model.interactionMode, .view)
        model.disconnect()
    }

    func testReconnectBudgetAndFreshRequests() async throws {
        RequestStub.requests.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestStub.self]
        let model = RemoteSessionModel(appModel: ControllerAppModel(),
            target: .local(try LocalDeviceAddress("192.168.1.2")),
            localClient: LocalDeviceClient(configuration: configuration))
        defer { model.disconnect() }
        let connect = Task { await model.connect() }
        for attempt in 0...3 {
            let pending = try await localRetryRequest()
            XCTAssertEqual(model.interactionMode, .view)
            pending.fail(URLError(.networkConnectionLost))
            if attempt == 0 { await connect.value }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.reconnectAttempt, 3)
        XCTAssertFalse(model.reconnecting)
        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(RequestStub.requests.count("/v1/capabilities"), 4)
    }

    func testSuspendCancelsPendingAutomaticReconnect() async throws {
        RequestStub.requests.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestStub.self]
        let model = RemoteSessionModel(appModel: ControllerAppModel(),
            target: .local(try LocalDeviceAddress("192.168.1.2")),
            localClient: LocalDeviceClient(configuration: configuration))
        let connect = Task { await model.connect() }
        let pending = try await localRetryRequest()
        pending.fail(URLError(.networkConnectionLost))
        await connect.value
        XCTAssertTrue(model.reconnecting)
        model.suspend()
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(model.reconnecting)
        XCTAssertEqual(model.state, .closed)
        XCTAssertEqual(RequestStub.requests.count("/v1/capabilities"), 1)
        model.disconnect()
    }

    private func localRetryRequest() async throws -> RequestStub {
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline {
            if let pending = RequestStub.requests.take("/v1/capabilities") { return pending }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("A bounded reconnect attempt did not issue a fresh request")
        throw URLError(.timedOut)
    }

    func testPreparationDoesNotRetryTrustOrAuthenticationFailures() async throws {
        for code in [URLError.Code.serverCertificateUntrusted, .userAuthenticationRequired] {
            RequestStub.requests.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RequestStub.self]
            let model = RemoteSessionModel(appModel: ControllerAppModel(),
                target: .local(try LocalDeviceAddress("192.168.1.2")),
                localClient: LocalDeviceClient(configuration: configuration))
            let connect = Task { await model.connect() }
            let pending = try await localRetryRequest()
            pending.fail(URLError(code))
            await connect.value
            XCTAssertEqual(model.state, .failed)
            XCTAssertEqual(model.reconnectAttempt, 0)
            XCTAssertFalse(model.reconnecting)
            model.disconnect()
        }
    }

    func testTerminalConnectionStatesClearControlAndVideo() {
        for state in [RctlRealtimeConnectionState.failed, .closed, .idle] {
            let model = RemoteSessionModel(appModel: ControllerAppModel(), deviceID: "test-device")
            model.handle(.connection(.connected))
            model.handle(.channel(label: "control", state: .open))
            model.handle(.videoHealth(.flowing))
            model.setInteractionMode(.control)
            XCTAssertTrue(model.canControl)

            model.handle(.connection(state))
            XCTAssertFalse(model.canControl)
            XCTAssertFalse(model.videoAvailable)
            XCTAssertTrue(model.channelStates.isEmpty)
            XCTAssertEqual(model.interactionMode, .view)
            model.setInteractionMode(.control)
            XCTAssertEqual(model.interactionMode, .view)
        }
    }

    func testTransientDisconnectRequiresExplicitControlAfterRecovery() {
        let model = RemoteSessionModel(appModel: ControllerAppModel(), deviceID: "test-device")
        model.handle(.channel(label: "control", state: .open))
        XCTAssertFalse(model.canControl)
        model.handle(.connection(.connected))
        model.handle(.videoHealth(.flowing))
        model.setInteractionMode(.control)
        model.handle(.connection(.disconnected))
        XCTAssertFalse(model.canControl)
        XCTAssertEqual(model.interactionMode, .view)
        model.handle(.connection(.connected))
        XCTAssertTrue(model.canControl)
        XCTAssertTrue(model.videoAvailable)
        XCTAssertEqual(model.interactionMode, .view)
        model.disconnect()
        XCTAssertFalse(model.canControl)
        XCTAssertEqual(model.state, .closed)
    }

    func testResetDuringRefreshDoesNotRestoreCredentialsOrError() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.close() }
        let restore = Task { await fixture.model.restore() }
        let refresh = try await request("/api/controller/token/refresh")
        fixture.model.resetProfile()
        refresh.respond(fixture.tokens)
        await restore.value
        XCTAssertNil(fixture.model.profile)
        XCTAssertNil(fixture.profiles.load())
        XCTAssertNil(try fixture.keychain.loadCredential(relayID: fixture.relayID))
        XCTAssertNil(fixture.model.presentedError)
        XCTAssertFalse(fixture.model.isBusy)
    }

    func testSuspendImmediatelyClearsInputAndVideo() {
        let model = RemoteSessionModel(appModel: ControllerAppModel(), deviceID: "test-device")
        model.handle(.connection(.connected))
        model.handle(.channel(label: "control", state: .open))
        model.handle(.videoHealth(.flowing))
        model.setInteractionMode(.control)
        model.suspend()
        XCTAssertFalse(model.canControl)
        XCTAssertFalse(model.videoAvailable)
        XCTAssertTrue(model.channelStates.isEmpty)
        XCTAssertEqual(model.interactionMode, .view)
        XCTAssertEqual(model.state, .closed)
    }

    func testResetDiscardsLateDeviceListAndKeepsNewOperationBusy() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.close() }
        let restore = Task { await fixture.model.restore() }
        let refresh = try await request("/api/controller/token/refresh")
        refresh.respond(fixture.tokens)
        let devices = try await request("/api/controller/devices")
        fixture.model.resetProfile()

        let pair = Task { await fixture.model.pair(using: fixture.pairing) }
        let claim = try await request("/api/controller/pairings/pair_test/claim")
        devices.respond(Self.devices)
        await restore.value
        XCTAssertTrue(fixture.model.devices.isEmpty)
        XCTAssertNil(fixture.model.profile)
        XCTAssertTrue(fixture.model.isBusy)
        XCTAssertNil(fixture.model.presentedError)
        claim.respond(#"{"error":"test-ended"}"#, status: 400)
        _ = await pair.value
    }

    func testConcurrentSignalingUsesOneRefresh() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.close() }
        let restore = Task { await fixture.model.restore() }
        let initialRefresh = try await request("/api/controller/token/refresh")
        initialRefresh.respond(fixture.tokenResponse(accessLifetime: 5))
        let devices = try await request("/api/controller/devices")
        devices.respond(Self.devices)
        await restore.value
        XCTAssertEqual(fixture.model.devices.count, 1)

        let first = Task { try await fixture.model.signalingRequest(deviceID: "test-device", media: .screen) }
        let second = Task { try await fixture.model.signalingRequest(deviceID: "test-device", media: .screen) }
        let refresh = try await request("/api/controller/token/refresh")
        // Both MainActor calls have entered the same suspended refresh before
        // this response; a second request would remain pending in the stub.
        await Task.yield()
        refresh.respond(fixture.tokens)
        for _ in 0..<2 {
            try await request("/api/controller/me").respond(Self.controllerInfo)
        }
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(RequestStub.requests.count("/api/controller/token/refresh"), 2)
    }

    func testProfileMigrationAndMultipleRelays() throws {
        let suite = "rctl.tests.profiles.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ControllerProfileStore(defaults: defaults)
        let controller = PairedController(id: "ctl_test", name: "Test", platform: "ios", scopes: [.screenView])
        let original = ControllerProfile(origin: "https://first.example", relayID: "first", controller: controller)
        defaults.set(try JSONEncoder().encode(original), forKey: "rctl.controller.profile.v1")
        XCTAssertEqual(try store.loadAll(), [original])
        XCTAssertEqual(store.load(), original)
        XCTAssertNil(defaults.data(forKey: "rctl.controller.profile.v1"))
        // Saved profiles are user-controlled, unlike untrusted Bonjour results.
        for index in 0..<100 {
            try store.save(ControllerProfile(origin: "https://relay\(index).example", relayID: "relay\(index)", controller: controller))
        }
        XCTAssertEqual(try store.loadAll().count, 101)
        store.select(original.relayID)
        XCTAssertEqual(store.load(), original)
        XCTAssertThrowsError(try store.save(ControllerProfile(origin: "https://other.example", relayID: "first", controller: controller)))
        XCTAssertEqual(store.load(), original)
        try store.remove(relayID: "first")
        XCTAssertEqual(try store.loadAll().count, 100)
        XCTAssertNotNil(store.load())
    }

    func testSwitchDiscardsOldRequestsAndPreservesOtherCredentials() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.close() }
        let second = try fixture.addSecondRelay()
        let restore = Task { await fixture.model.restore() }
        let oldRefresh = try await request("/api/controller/token/refresh")
        let switching = Task { await fixture.model.selectProfile(second.relayID) }
        let newRefresh = try await request("/api/controller/token/refresh")
        XCTAssertEqual(newRefresh.request.url?.host, "second.example")
        oldRefresh.respond(fixture.tokens)
        await restore.value
        XCTAssertEqual(fixture.model.profile, second)
        XCTAssertTrue(fixture.model.isBusy)
        XCTAssertTrue(fixture.model.devices.isEmpty)
        newRefresh.respond(fixture.tokens)
        let listing = try await request("/api/controller/devices")
        XCTAssertEqual(listing.request.url?.host, "second.example")
        listing.respond(Self.devices)
        await switching.value
        XCTAssertEqual(fixture.model.devices.count, 1)
        let original = try XCTUnwrap(fixture.profiles.loadAll().first { $0.relayID == fixture.relayID })
        do {
            _ = try await fixture.model.signalingRequest(deviceID: "test-device", media: .screen, expectedProfile: original)
            XCTFail("A session must not switch relays even when device IDs match")
        } catch is CancellationError { }
        XCTAssertNotNil(try fixture.keychain.loadCredential(relayID: fixture.relayID))
        fixture.model.resetProfile()
        XCTAssertEqual(fixture.model.profile?.relayID, fixture.relayID)
        XCTAssertNotNil(try fixture.keychain.loadCredential(relayID: fixture.relayID))
        XCTAssertNil(try fixture.keychain.loadCredential(relayID: second.relayID))
        // Finish the selected relay refresh started after removal.
        let remainingRefresh = try await request("/api/controller/token/refresh")
        remainingRefresh.respond(fixture.tokens)
        let remainingList = try await request("/api/controller/devices")
        remainingList.respond(Self.devices)
        await Task.yield()
    }

    func testCorruptCollectionDoesNotFallBackOrOverwrite() throws {
        let suite = "rctl.tests.corrupt.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ControllerProfileStore(defaults: defaults)
        let corrupt = Data("invalid".utf8)
        defaults.set(corrupt, forKey: "rctl.controller.profiles.v2")
        XCTAssertThrowsError(try store.loadAll())
        XCTAssertThrowsError(try store.remove(relayID: "any"))
        XCTAssertEqual(defaults.data(forKey: "rctl.controller.profiles.v2"), corrupt)
    }

    private func request(_ path: String) async throws -> RequestStub {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if path != "/api/controller/me", let info = RequestStub.requests.take("/api/controller/me") {
                info.respond(info.request.url?.host == "second.example" ? Self.secondControllerInfo : Self.controllerInfo)
            }
            if let request = RequestStub.requests.take(path) { return request }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected request was not started: \(path)")
        throw URLError(.timedOut)
    }

    func testRevokeRequiresAcknowledgementAndPreservesOtherRelays() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.close() }
        let other = try fixture.addSecondRelay()
        let restore = Task { await fixture.model.restore() }
        try await request("/api/controller/token/refresh").respond(fixture.tokens)
        try await request("/api/controller/devices").respond(Self.devices)
        await restore.value
        let original = fixture.model.profile

        let failed = Task { await fixture.model.revokeProfile() }
        let failedRequest = try await request("/api/controller/me/revoke")
        XCTAssertTrue(fixture.model.isRevoking)
        XCTAssertEqual(fixture.model.profile, original)
        XCTAssertNotNil(try fixture.keychain.loadCredential(relayID: fixture.relayID))
        XCTAssertEqual(failedRequest.request.httpMethod, "POST")
        XCTAssertNotNil(failedRequest.request.value(forHTTPHeaderField: "X-RCTL-Signature"))
        await fixture.model.selectProfile(other.relayID)
        XCTAssertEqual(fixture.model.profile, original, "Switching must not race revocation")
        failedRequest.respond(#"{"error":"unavailable"}"#, status: 503)
        await failed.value
        XCTAssertEqual(fixture.model.profile, original)
        XCTAssertNotNil(fixture.model.presentedError)
        XCTAssertFalse(fixture.model.isRevoking)

        let success = Task { await fixture.model.revokeProfile() }
        try await request("/api/controller/me/revoke").respond(#"{"ok":true}"#)
        await success.value
        XCTAssertNil(try fixture.keychain.loadCredential(relayID: fixture.relayID))
        XCTAssertNotNil(try fixture.keychain.loadCredential(relayID: other.relayID))
        XCTAssertEqual(fixture.model.profile, other)
        XCTAssertFalse(fixture.model.isRevoking)
        try await request("/api/controller/token/refresh").respond(fixture.tokens)
        try await request("/api/controller/devices").respond(Self.devices)
        await Task.yield()
    }

    func testUnconfirmedRevokeDoesNotForgetProfile() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.close() }
        let restore = Task { await fixture.model.restore() }
        try await request("/api/controller/token/refresh").respond(fixture.tokens)
        try await request("/api/controller/devices").respond(Self.devices)
        await restore.value
        // Old servers, lost acknowledgement/retry, and malformed acknowledgements
        // must not be presented as successful revocation.
        for status in [404, 401, 200] {
            let revoke = Task { await fixture.model.revokeProfile() }
            try await request("/api/controller/me/revoke").respond(#"{"ok":false}"#, status: status)
            await revoke.value
            XCTAssertNotNil(fixture.model.profile)
            XCTAssertNotNil(try fixture.keychain.loadCredential(relayID: fixture.relayID))
            XCTAssertNotNil(fixture.model.presentedError)
        }
    }

    func testPresenceCancellationAndOldServerCompatibility() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.close() }
        let restore = Task { await fixture.model.restore() }
        try await request("/api/controller/token/refresh").respond(fixture.tokens)
        try await request("/api/controller/devices").respond(Self.devices)
        await restore.value
        let profile = try XCTUnwrap(fixture.model.profile)

        let presence = Task { await fixture.model.maintainPresence(for: profile) }
        let pulse = try await request("/api/controller/presence")
        XCTAssertEqual(pulse.request.httpMethod, "POST")
        XCTAssertEqual(pulse.request.url?.host, "relay.example")
        XCTAssertNotNil(pulse.request.value(forHTTPHeaderField: "X-RCTL-Signature"))
        presence.cancel()
        await presence.value
        XCTAssertEqual(RequestStub.requests.count("/api/controller/presence"), 1)
        XCTAssertNil(fixture.model.presentedError)

        let oldServer = Task { await fixture.model.maintainPresence(for: profile) }
        try await request("/api/controller/presence").respond(#"{"error":"not_found"}"#, status: 404)
        await oldServer.value
        XCTAssertNil(fixture.model.presentedError)
        XCTAssertEqual(fixture.model.profile, profile)
    }

    func testDeleteRelayWaitsForAcknowledgementThenOffersLocalDelete() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.close() }
        let restore = Task { await fixture.model.restore() }
        try await request("/api/controller/token/refresh").respond(fixture.tokens)
        try await request("/api/controller/devices").respond(Self.devices)
        await restore.value
        let original = fixture.model.profile

        let failed = Task { await fixture.model.deleteRelay() }
        try await request("/api/controller/me/revoke").respond(#"{"error":"unavailable"}"#, status: 503)
        await failed.value
        XCTAssertEqual(fixture.model.profile, original, "No acknowledgement: nothing is deleted yet")
        XCTAssertNotNil(try fixture.keychain.loadCredential(relayID: fixture.relayID))
        XCTAssertNil(fixture.model.presentedError)
        let failure = try XCTUnwrap(fixture.model.relayDeletionFailure)
        XCTAssertFalse(failure.alreadyRevoked)

        fixture.model.forceDeleteRelay()
        XCTAssertNil(fixture.model.relayDeletionFailure)
        XCTAssertNil(fixture.model.profile)
        XCTAssertNil(try fixture.keychain.loadCredential(relayID: fixture.relayID))
    }

    func testDeleteRelayRecognizesServerSideRevocation() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.close() }
        let restore = Task { await fixture.model.restore() }
        try await request("/api/controller/token/refresh").respond(fixture.tokens)
        try await request("/api/controller/devices").respond(Self.devices)
        await restore.value

        // A stale access token is retried once through refresh; when the refresh
        // credential itself is rejected the controller was revoked from admin.
        let gone = Task { await fixture.model.deleteRelay() }
        try await request("/api/controller/me/revoke").respond(#"{"error":"controller_unauthorized"}"#, status: 401)
        try await request("/api/controller/token/refresh").respond(#"{"error":"controller_unauthorized"}"#, status: 401)
        await gone.value
        XCTAssertNotNil(fixture.model.profile, "Even a revoked controller is deleted locally only on confirmation")
        let failure = try XCTUnwrap(fixture.model.relayDeletionFailure)
        XCTAssertTrue(failure.alreadyRevoked)
        fixture.model.forceDeleteRelay()
        XCTAssertNil(fixture.model.profile)
        XCTAssertNil(try fixture.keychain.loadCredential(relayID: fixture.relayID))
    }

    func testDeleteRelayRemovesProfileAfterAcknowledgement() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.close() }
        let other = try fixture.addSecondRelay()
        let restore = Task { await fixture.model.restore() }
        try await request("/api/controller/token/refresh").respond(fixture.tokens)
        try await request("/api/controller/devices").respond(Self.devices)
        await restore.value

        let deleted = Task { await fixture.model.deleteRelay() }
        try await request("/api/controller/me/revoke").respond(#"{"ok":true}"#)
        await deleted.value
        XCTAssertNil(fixture.model.relayDeletionFailure)
        XCTAssertNil(try fixture.keychain.loadCredential(relayID: fixture.relayID))
        XCTAssertNotNil(try fixture.keychain.loadCredential(relayID: other.relayID))
        XCTAssertEqual(fixture.model.profile, other)
        try await request("/api/controller/token/refresh").respond(fixture.tokens)
        try await request("/api/controller/devices").respond(Self.devices)
        await Task.yield()
    }

    func testDeviceProfileIsReportedOncePerFingerprintAndHeartbeatCarriesTelemetry() async throws {
        let fixture = try ProfileFixture()
        defer { fixture.close() }
        let restore = Task { await fixture.model.restore() }
        try await request("/api/controller/token/refresh").respond(fixture.tokens)
        try await request("/api/controller/devices").respond(Self.devices)
        await restore.value
        let profile = try XCTUnwrap(fixture.model.profile)

        let presence = Task { await fixture.model.maintainPresence(for: profile) }
        let report = try await request("/api/controller/me/client")
        XCTAssertEqual(report.request.httpMethod, "POST")
        XCTAssertNotNil(report.request.value(forHTTPHeaderField: "X-RCTL-Signature"))
        let reported = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(report.request.bodyData)) as? [String: Any])
        let client = try XCTUnwrap(reported["client"] as? [String: Any])
        XCTAssertNotNil(client["system_version"])
        XCTAssertNotNil(client["idiom"])
        XCTAssertEqual(client["protocol_major"] as? Int, 1)
        XCTAssertEqual(client["install_channel"] as? String, "debug")
        XCTAssertTrue((client["capabilities"] as? [String] ?? []).contains("webrtc.screen"))
        XCTAssertNil(client["identifier_for_vendor"], "No tracking identifiers leave the phone")
        report.respond(#"{"ok":true,"accepted_schema_version":2}"#)

        let pulse = try await request("/api/controller/presence")
        let heartbeat = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(pulse.request.bodyData)) as? [String: Any])
        let telemetry = try XCTUnwrap(heartbeat["telemetry"] as? [String: Any])
        XCTAssertNotNil(telemetry["thermal"])
        XCTAssertTrue(telemetry["low_power"] is Bool, "booleans travel as JSON booleans")
        XCTAssertNil(telemetry["uptime_seconds"])
        XCTAssertNil(telemetry["disk_free_bytes"])
        XCTAssertNil(client["disk_bytes"])
        presence.cancel()
        await presence.value

        let deadline = ContinuousClock.now + .seconds(3)
        while fixture.profiles.reportedClientProfile(relayID: fixture.relayID) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(fixture.profiles.reportedClientProfile(relayID: fixture.relayID))

        let again = Task { await fixture.model.maintainPresence(for: profile) }
        _ = try await request("/api/controller/presence")
        again.cancel()
        await again.value
        XCTAssertEqual(RequestStub.requests.count("/api/controller/me/client"), 1, "Unchanged profile is not re-sent")
    }

    private static let devices = #"{"devices":[{"id":"test-device","name":"Test iPad","status":"approved","online":true,"features":["screen.webrtc","controller.scoped_sessions"],"compatible":true}]}"#
    private static let controllerInfo = #"{"controller":{"id":"ctl_test","name":"Test","platform":"ios","scopes":["screen.view","device.control"]}}"#
    private static let secondControllerInfo = #"{"controller":{"id":"ctl_second","name":"Second","platform":"ios","scopes":["screen.view"]}}"#
}

@MainActor
private final class ProfileFixture {
    let relayID = String(repeating: "r", count: 32)
    let keychain: KeychainControllerStore
    let profiles: ControllerProfileStore
    let model: ControllerAppModel
    private let defaults: UserDefaults
    private let suite: String
    private let session: URLSession

    init() throws {
        RequestStub.requests.reset()
        suite = "rctl.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        profiles = ControllerProfileStore(defaults: defaults)
        keychain = KeychainControllerStore(namespace: suite, preferSecureEnclave: false)
        let controller = PairedController(id: "ctl_test", name: "Test", platform: "ios", scopes: [.screenView, .deviceControl])
        try profiles.save(ControllerProfile(origin: "https://relay.example", relayID: relayID, controller: controller))
        _ = try keychain.loadOrCreateSigningKey(relayID: relayID)
        try keychain.save(ControllerRefreshCredential(
            origin: "https://relay.example", relayID: relayID, controller: controller,
            refreshToken: "crt_test.fixture", refreshExpiresAt: Int64(Date().timeIntervalSince1970) + 3600
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestStub.self]
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
        model = ControllerAppModel(api: ControllerAPIClient(session: session), keychain: keychain, profiles: profiles)
    }

    var tokens: String { tokenResponse(accessLifetime: 300) }

    func addSecondRelay() throws -> ControllerProfile {
        let controller = PairedController(id: "ctl_second", name: "Second", platform: "ios", scopes: [.screenView])
        let profile = ControllerProfile(origin: "https://second.example", relayID: "second", controller: controller)
        try profiles.save(profile)
        profiles.select(relayID)
        _ = try keychain.loadOrCreateSigningKey(relayID: profile.relayID)
        try keychain.save(ControllerRefreshCredential(origin: profile.origin, relayID: profile.relayID,
            controller: controller, refreshToken: "crt_second.fixture", refreshExpiresAt: Int64(Date().timeIntervalSince1970) + 3600))
        return profile
    }

    func tokenResponse(accessLifetime: Int64) -> String {
        let now = Int64(Date().timeIntervalSince1970)
        return """
        {"tokens":{"access_token":"cat_test.fixture","access_expires_at":\(now + accessLifetime),"refresh_token":"crt_test.fixture","refresh_expires_at":\(now + 3600)}}
        """
    }

    var pairing: String {
        """
        {"v":1,"origin":"https://relay.example","pairing_id":"pair_test","secret":"\(String(repeating: "s", count: 32))","expires_at":\(Int64(Date().timeIntervalSince1970) + 300),"protocol_major":1,"relay_id":"\(relayID)"}
        """
    }

    func close() {
        session.invalidateAndCancel()
        try? keychain.deleteProfile(relayID: relayID)
        try? keychain.deleteProfile(relayID: "second")
        defaults.removePersistentDomain(forName: suite)
    }
}

final class RequestStub: URLProtocol, @unchecked Sendable {
    static let requests = StubRequests()
    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.requests.append(self) }
    override func stopLoading() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        client?.urlProtocol(self, didFailWithError: error)
    }

    func respond(_ body: String, status: Int = 200) {
        lock.lock()
        guard !stopped, let url = request.url else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class StubRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [RequestStub] = []
    private var counts: [String: Int] = [:]

    func append(_ value: RequestStub) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(value)
        counts[value.request.url!.path, default: 0] += 1
    }

    func take(_ path: String) -> RequestStub? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = pending.firstIndex(where: { $0.request.url?.path == path }) else { return nil }
        return pending.remove(at: index)
    }

    func count(_ path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[path, default: 0]
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
        counts.removeAll()
    }
}

extension URLRequest {
    /// URLProtocol receives upload bodies as a stream; drain it for assertions.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
