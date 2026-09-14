import Foundation

/// Where a bounded request receives its URLSession delegate callbacks.
enum RequestDelegation: Sendable {
    /// Task-local delegate on the injected session (iOS 15 / macOS 12 and later).
    case taskDelegate
    /// Dedicated per-request session built from the injected session's
    /// configuration. Used before iOS 15, and by tests to exercise that path.
    case dedicatedSession

    static var preferred: RequestDelegation {
        if #available(iOS 15, macOS 12, *) { return .taskDelegate }
        return .dedicatedSession
    }
}

/// Task-local delegate preserves the injected session while bounding decoded
/// response bytes and preventing signed requests from following redirects.
/// Before iOS 15 the same delegate drives a dedicated session that reuses the
/// injected configuration and is invalidated on every terminal path, because
/// a session retains its delegate until invalidation.
final class BoundedControllerRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Response = (Data, HTTPURLResponse)
    private let lock = NSLock()
    private let session: URLSession
    private let request: URLRequest
    private let limit: Int
    private let delegation: RequestDelegation
    private let deadline: TimeInterval
    private var task: URLSessionDataTask?
    private var dedicatedSession: URLSession?
    private var continuation: CheckedContinuation<Response, Error>?
    private var cancelled = false
    private var data = Data()
    private var response: HTTPURLResponse?
    private var timeout: DispatchWorkItem?

    init(session: URLSession, request: URLRequest, limit: Int,
         delegation: RequestDelegation = .preferred, deadline: TimeInterval = 20) {
        self.session = session
        self.request = request
        self.limit = limit
        self.delegation = delegation
        self.deadline = deadline
    }

    func start(_ continuation: CheckedContinuation<Response, Error>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        var request = request
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task: URLSessionDataTask
        if #available(iOS 15, macOS 12, *), delegation == .taskDelegate {
            task = session.dataTask(with: request)
            task.delegate = self
        } else {
            let dedicated = URLSession(configuration: session.configuration, delegate: self, delegateQueue: nil)
            dedicatedSession = dedicated
            task = dedicated.dataTask(with: request)
        }
        self.task = task
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(URLError(.timedOut)))
        }
        self.timeout = timeout
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: timeout)
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Response, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let task = task
        self.task = nil
        let dedicatedSession = dedicatedSession
        self.dedicatedSession = nil
        timeout?.cancel()
        timeout = nil
        data.removeAll()
        lock.unlock()
        task?.cancel()
        dedicatedSession?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.url == request.url,
              !(300..<400).contains(http.statusCode) else {
            finish(.failure(ControllerClientError.invalidResponse))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= limit else {
            finish(.failure(ControllerClientError.responseTooLarge))
            completionHandler(.cancel)
            return
        }
        lock.lock()
        self.response = http
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        let oversized = chunk.count > limit - data.count
        if !oversized { data.append(chunk) }
        lock.unlock()
        if oversized { finish(.failure(ControllerClientError.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let result: Result<Response, Error>
        if let error { result = .failure(error) }
        else if let response { result = .success((data, response)) }
        else { result = .failure(ControllerClientError.invalidResponse) }
        lock.unlock()
        finish(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(ControllerClientError.invalidResponse))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
