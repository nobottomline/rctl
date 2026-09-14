import Foundation
import Network
import Testing
@testable import RctlClient

/// The macOS test host supports task delegates, so the pre-iOS 15 dedicated
/// session path runs only when a test selects it explicitly.
let requestDelegations: [RequestDelegation] = [.taskDelegate, .dedicatedSession]

@Suite("Bounded controller HTTP", .serialized)
struct BoundedControllerRequestTests {
    @Test(arguments: ["declared", "chunked", "error-body", "untyped"], requestDelegations)
    func stopsOversizedResponsesBeforeCompletion(_ scenario: String, _ delegation: RequestDelegation) async throws {
        let (session, operation) = makeRequest(scenario, delegation: delegation)
        defer { session.invalidateAndCancel() }
        await #expect(throws: ControllerClientError.responseTooLarge) {
            _ = try await run(operation)
        }
    }

    @Test(arguments: requestDelegations)
    func acceptsExactBoundaryAndPreservesStatus(_ delegation: RequestDelegation) async throws {
        let (session, operation) = makeRequest("exact", delegation: delegation)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await run(operation)
        #expect(data.count == 1024)
        #expect(response.statusCode == 200)
    }

    @Test(arguments: requestDelegations)
    func cancellationBeforeStartIsAcknowledged(_ delegation: RequestDelegation) async {
        let (session, operation) = makeRequest("silent", delegation: delegation)
        defer { session.invalidateAndCancel() }
        operation.cancel()
        await #expect(throws: CancellationError.self) { _ = try await run(operation) }
    }

    @Test(arguments: requestDelegations)
    func cancellationWhileReadingIsAcknowledged(_ delegation: RequestDelegation) async throws {
        let (session, operation) = makeRequest("silent", delegation: delegation)
        defer { session.invalidateAndCancel() }
        let task = Task { try await run(operation) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test(arguments: requestDelegations)
    func deadlineEndsStalledTransfer(_ delegation: RequestDelegation) async {
        let (session, operation) = makeRequest("silent", delegation: delegation, deadline: 0.2)
        defer { session.invalidateAndCancel() }
        let error = await #expect(throws: URLError.self) { _ = try await run(operation) }
        #expect(error?.code == .timedOut)
    }

    @Test(arguments: requestDelegations)
    func redirectStatusIsNotDecodedAsSuccess(_ delegation: RequestDelegation) async {
        let (session, operation) = makeRequest("redirect", delegation: delegation)
        defer { session.invalidateAndCancel() }
        await #expect(throws: ControllerClientError.invalidResponse) { _ = try await run(operation) }
    }

    /// A dedicated session retains its delegate until invalidated, so a request
    /// that outlives its terminal path would leak the session and its delegate.
    @Test(arguments: TerminalPath.allCases, requestDelegations)
    func releasesRequestAfterEveryTerminalPath(_ path: TerminalPath, _ delegation: RequestDelegation) async throws {
        let (session, reference) = try await finish(path, delegation: delegation)
        defer { session.invalidateAndCancel() }
        let deadline = Date().addingTimeInterval(5)
        while reference.value != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reference.value == nil)
    }

    @Test(arguments: [false, true], requestDelegations)
    func realSocketRejectsHeadersBeforeBodyCompletion(redirect: Bool, delegation: RequestDelegation) async throws {
        let status = redirect ? "302 Found\r\nLocation: https://example.invalid/not-followed" : "200 OK"
        let server = try HeaderOnlyServer(
            head: "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: 10485760\r\n\r\n{")
        defer { server.stop() }
        let (operation, session) = try await realSocketRequest(server, delegation: delegation)
        defer { session.invalidateAndCancel() }
        await #expect(throws: redirect ? ControllerClientError.invalidResponse : .responseTooLarge) {
            _ = try await run(operation)
        }
    }

    /// HTTP authentication must not add credentials to a signed request.
    @Test(arguments: requestDelegations)
    func realSocketCancelsHTTPAuthenticationChallenge(_ delegation: RequestDelegation) async throws {
        let server = try HeaderOnlyServer(
            head: "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"rctl\"\r\nContent-Length: 0\r\n\r\n")
        defer { server.stop() }
        let (operation, session) = try await realSocketRequest(server, delegation: delegation)
        defer { session.invalidateAndCancel() }
        let error = await #expect(throws: URLError.self) { _ = try await run(operation) }
        #expect(error?.code == .cancelled)
    }

    private func realSocketRequest(_ server: HeaderOnlyServer, delegation: RequestDelegation) async throws
        -> (BoundedControllerRequest, URLSession) {
        let url = try await server.start()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.setValue("synthetic-test-signature", forHTTPHeaderField: "X-RCTL-Signature")
        let operation = BoundedControllerRequest(session: session, request: request, limit: 1024, delegation: delegation)
        return (operation, session)
    }

    enum TerminalPath: CaseIterable, Sendable {
        case success, failure, timeout, cancelBeforeStart, cancelAfterStart
    }

    private func finish(_ path: TerminalPath, delegation: RequestDelegation) async throws
        -> (URLSession, WeakReference<BoundedControllerRequest>) {
        let scenario = switch path {
        case .success: "exact"
        case .failure: "declared"
        case .timeout, .cancelBeforeStart, .cancelAfterStart: "silent"
        }
        let (session, operation) = makeRequest(scenario, delegation: delegation, deadline: 0.2)
        let reference = WeakReference(operation)
        switch path {
        case .success:
            _ = try await run(operation)
        case .failure:
            await #expect(throws: ControllerClientError.responseTooLarge) { _ = try await run(operation) }
        case .timeout:
            let error = await #expect(throws: URLError.self) { _ = try await run(operation) }
            #expect(error?.code == .timedOut)
        case .cancelBeforeStart:
            operation.cancel()
            await #expect(throws: CancellationError.self) { _ = try await run(operation) }
        case .cancelAfterStart:
            let task = Task { try await run(operation) }
            try await Task.sleep(for: .milliseconds(20))
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
        return (session, reference)
    }

    private func run(_ operation: BoundedControllerRequest) async throws -> BoundedControllerRequest.Response {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: { operation.cancel() }
    }

    private func makeRequest(_ scenario: String, delegation: RequestDelegation,
                             deadline: TimeInterval = 20) -> (URLSession, BoundedControllerRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedResponseStub.self]
        let session = URLSession(configuration: configuration)
        let request = URLRequest(url: URL(string: "https://relay.example/\(scenario)")!)
        return (session, BoundedControllerRequest(session: session, request: request, limit: 1024,
                                                  delegation: delegation, deadline: deadline))
    }
}

final class WeakReference<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}

/// Real HTTP avoids relying only on URLProtocol's delivery/buffering behavior.
/// Only the given response head is sent and the socket remains open.
private final class HeaderOnlyServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "rctl.tests.http-headers")
    private let listener: NWListener
    private let head: String
    private var connections: [NWConnection] = []

    init(head: String) throws {
        self.head = head
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")!)
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connections.append(connection)
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [head] _, _, _, error in
                    guard error == nil else { return }
                    connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}

private final class BoundedResponseStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        let scenario = url.lastPathComponent
        if scenario == "silent" { return }
        var headers = ["Content-Type": "application/json"]
        if scenario == "untyped" { headers.removeAll() }
        if scenario == "declared" { headers["Content-Length"] = "1025" }
        let status = scenario == "redirect" ? 302 : scenario == "error-body" ? 503 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if scenario == "declared" || scenario == "redirect" {
            // Keep the transfer unfinished: rejection must not depend on EOF.
            client?.urlProtocol(self, didLoad: Data([0]))
            return
        }
        client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 1024))
        if scenario != "exact" {
            client?.urlProtocol(self, didLoad: Data([2]))
            // Deliberately never finish: crossing the bound must cancel now.
            return
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
