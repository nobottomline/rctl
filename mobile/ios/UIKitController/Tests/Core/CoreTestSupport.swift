import Foundation
import RctlClient
import XCTest
@testable import RctlUIKit

// Shared doubles for the domain-model regression tests. Every relay and LAN
// request is held by `CoreRequestStub` on a per-test URLSession; nothing is
// registered globally, so the hosted app's own sessions are never affected.
// Names carry a `Core` prefix so other test areas can define their own stubs.

/// Holds a request until the test responds or fails it.
final class CoreRequestStub: URLProtocol, @unchecked Sendable {
    static let requests = CoreStubRequests()
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

final class CoreStubRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CoreRequestStub] = []
    private var counts: [String: Int] = [:]

    func append(_ value: CoreRequestStub) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(value)
        counts[value.request.url!.path, default: 0] += 1
    }

    func take(_ path: String) -> CoreRequestStub? {
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

    /// Requests started on any path since the last reset.
    var totalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return counts.values.reduce(0, +)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
        counts.removeAll()
    }
}

/// Fails every request immediately, so a model that is not expected to use
/// the network can never reach a real relay.
final class CoreOfflineURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

/// iOS 13-compatible replacement for the originals' `ContinuousClock` deadlines.
struct CoreTestDeadline {
    private let end: TimeInterval

    init(seconds: TimeInterval) {
        end = ProcessInfo.processInfo.systemUptime + seconds
    }

    var hasTimeRemaining: Bool { ProcessInfo.processInfo.systemUptime < end }
}

extension XCTestCase {
    /// A `ControllerAppModel` with a private UserDefaults suite, Keychain
    /// namespace and an offline URLSession. It replaces the originals'
    /// `ControllerAppModel()`, whose defaults would share the hosted app's
    /// standard defaults, real Keychain namespace and shared URLSession.
    @MainActor
    func makeIsolatedControllerAppModel() -> ControllerAppModel {
        let suite = "rctl.tests.isolated.\(UUID().uuidString)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoreOfflineURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let keychain = KeychainControllerStore(namespace: suite, preferSecureEnclave: false)
        addTeardownBlock {
            session.invalidateAndCancel()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        return ControllerAppModel(
            api: ControllerAPIClient(session: session),
            keychain: keychain,
            profiles: ControllerProfileStore(defaults: UserDefaults(suiteName: suite)!),
            allowInsecureLoopback: false
        )
    }
}
