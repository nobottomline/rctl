import Foundation
import Network
import Testing
@testable import RctlClient

@Suite("Bounded controller HTTP", .serialized)
struct BoundedControllerRequestTests {
    @Test(arguments: ["declared", "chunked", "error-body", "untyped"])
    func stopsOversizedResponsesBeforeCompletion(_ scenario: String) async throws {
        let (session, operation) = makeRequest(scenario)
        defer { session.invalidateAndCancel() }
        await #expect(throws: ControllerClientError.responseTooLarge) {
            _ = try await run(operation)
        }
    }

    @Test func acceptsExactBoundaryAndPreservesStatus() async throws {
        let (session, operation) = makeRequest("exact")
        defer { session.invalidateAndCancel() }
        let (data, response) = try await run(operation)
        #expect(data.count == 1024)
        #expect(response.statusCode == 200)
    }

    @Test func cancellationBeforeStartIsAcknowledged() async {
        let (session, operation) = makeRequest("silent")
        defer { session.invalidateAndCancel() }
        operation.cancel()
        await #expect(throws: CancellationError.self) { _ = try await run(operation) }
    }

    @Test func cancellationWhileReadingIsAcknowledged() async throws {
        let (session, operation) = makeRequest("silent")
        defer { session.invalidateAndCancel() }
        let task = Task { try await run(operation) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func redirectStatusIsNotDecodedAsSuccess() async {
        let (session, operation) = makeRequest("redirect")
        defer { session.invalidateAndCancel() }
        await #expect(throws: ControllerClientError.invalidResponse) { _ = try await run(operation) }
    }

    @Test(arguments: [false, true])
    func realSocketRejectsHeadersBeforeBodyCompletion(redirect: Bool) async throws {
        let server = try HeaderOnlyServer(redirect: redirect)
        defer { server.stop() }
        let url = try await server.start()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("synthetic-test-signature", forHTTPHeaderField: "X-RCTL-Signature")
        let operation = BoundedControllerRequest(session: session, request: request, limit: 1024)
        await #expect(throws: redirect ? ControllerClientError.invalidResponse : .responseTooLarge) {
            _ = try await run(operation)
        }
    }

    private func run(_ operation: BoundedControllerRequest) async throws -> BoundedControllerRequest.Response {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: { operation.cancel() }
    }

    private func makeRequest(_ scenario: String) -> (URLSession, BoundedControllerRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedResponseStub.self]
        let session = URLSession(configuration: configuration)
        let request = URLRequest(url: URL(string: "https://relay.example/\(scenario)")!)
        return (session, BoundedControllerRequest(session: session, request: request, limit: 1024))
    }
}

/// Real HTTP avoids relying only on URLProtocol's delivery/buffering behavior.
/// Only one body byte is sent and the socket remains open.
private final class HeaderOnlyServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "rctl.tests.http-headers")
    private let listener: NWListener
    private let redirect: Bool
    private var connections: [NWConnection] = []

    init(redirect: Bool) throws {
        self.redirect = redirect
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
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [redirect] _, _, _, error in
                    guard error == nil else { return }
                    let status = redirect ? "302 Found\r\nLocation: https://example.invalid/not-followed" : "200 OK"
                    let headers = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: 10485760\r\n\r\n{"
                    connection.send(content: Data(headers.utf8), completion: .contentProcessed { _ in })
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
