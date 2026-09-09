import Foundation
import RctlClient
import RctlRealtime
import XCTest
@testable import RCTL_Controller

@MainActor
final class ControllerLifecycleTests: XCTestCase {
    func testTerminalConnectionStatesClearControlAndVideo() {
        for state in [RctlRealtimeConnectionState.failed, .closed, .idle] {
            let model = RemoteSessionModel(appModel: ControllerAppModel(), deviceID: "test-device")
            model.handle(.connection(.connected))
            model.handle(.channel(label: "control", state: .open))
            model.handle(.firstVideoFrame)
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
        model.handle(.firstVideoFrame)
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
        model.handle(.firstVideoFrame)
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
        await pair.value
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
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(RequestStub.requests.count("/api/controller/token/refresh"), 2)
    }

    private func request(_ path: String) async throws -> RequestStub {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if let request = RequestStub.requests.take(path) { return request }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected request was not started: \(path)")
        throw URLError(.timedOut)
    }

    private static let devices = #"{"devices":[{"id":"test-device","name":"Test iPad","status":"approved","online":true,"features":["screen.webrtc","controller.scoped_sessions"],"compatible":true}]}"#
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
        defaults.removePersistentDomain(forName: suite)
    }
}

private final class RequestStub: URLProtocol, @unchecked Sendable {
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

private final class StubRequests: @unchecked Sendable {
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
