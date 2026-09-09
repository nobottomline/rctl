@preconcurrency import Foundation
import RctlProtocol

public final class LocalDeviceClient: Sendable {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        session = LocalNetworkSession.make(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    public func capabilities(at address: LocalDeviceAddress, camera: Bool = false) async throws -> Capabilities {
        let operation = LocalCapabilitiesRequest(session: session, address: address)
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
        let capabilities: Capabilities
        do {
            capabilities = try JSONDecoder().decode(Capabilities.self, from: data).validated()
            guard capabilities.component == "daemon" else { throw LocalConnectionError.invalidResponse }
        } catch {
            throw LocalConnectionError.invalidResponse
        }
        guard capabilities.protocolVersion.compatibility(with: .current).canConnect else {
            throw LocalConnectionError.incompatibleProtocol
        }
        guard capabilities.features.contains(camera ? "camera.live" : "screen.webrtc") else {
            throw LocalConnectionError.unsupportedMedia
        }
        return capabilities
    }
}

/// This session is never shared with relay authentication. Redirects and HTTP
/// authentication challenges cannot change the target or introduce credentials.
enum LocalNetworkSession {
    static func make(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.httpAdditionalHeaders = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config, delegate: LocalNetworkDelegate(), delegateQueue: nil)
    }
}

private final class LocalNetworkDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

private final class LocalCapabilitiesRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let limit = 64 * 1024
    private let lock = NSLock()
    private let session: URLSession
    private let address: LocalDeviceAddress
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, Error>?
    private var cancelled = false
    private var data = Data()

    init(session: URLSession, address: LocalDeviceAddress) {
        self.session = session
        self.address = address
    }

    func start(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        var request = URLRequest(url: address.capabilitiesURL)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        task.delegate = self
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let task = task
        self.task = nil
        data.removeAll()
        lock.unlock()
        task?.cancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.url == address.capabilitiesURL else {
            finish(.failure(LocalConnectionError.invalidResponse))
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 else {
            finish(.failure((300..<400).contains(http.statusCode) ? LocalConnectionError.redirect : .http(http.statusCode)))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Self.limit else {
            finish(.failure(LocalConnectionError.responseTooLarge))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        let oversized = chunk.count > Self.limit - data.count
        if !oversized { data.append(chunk) }
        lock.unlock()
        if oversized { finish(.failure(LocalConnectionError.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let result: Result<Data, Error> = error.map { .failure($0) } ?? .success(data)
        lock.unlock()
        finish(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(LocalConnectionError.redirect))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
