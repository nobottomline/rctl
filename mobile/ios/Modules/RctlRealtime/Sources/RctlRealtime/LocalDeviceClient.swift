@preconcurrency import Foundation
import RctlProtocol

public final class LocalDeviceClient: Sendable {
    private let session: URLSession
    private let delegation: RequestDelegation
    // LAN-token cache keyed by display address. An empty string marks a legacy
    // daemon (verified by the bootstrap route answering exactly 404).
    private let tokenCache = LocalTokenCache()

    public convenience init(configuration: URLSessionConfiguration = .ephemeral) {
        self.init(configuration: configuration, delegation: .preferred)
    }

    init(configuration: URLSessionConfiguration, delegation: RequestDelegation) {
        session = LocalNetworkSession.make(configuration: configuration)
        self.delegation = delegation
    }

    deinit { session.invalidateAndCancel() }

    public func capabilities(at address: LocalDeviceAddress, camera: Bool = false) async throws -> Capabilities {
        // A bootstrap failure (network, 403, malformed answer) fails the
        // request closed; only a VERIFIED legacy daemon (exactly 404) proceeds
        // token-less.
        let token = try await bootstrapToken(for: address)
        let operation = LocalCapabilitiesRequest(session: session, address: address, delegation: delegation, token: token)
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
enum LocalNetworkSession {    static func make(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
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

/// Before iOS 15 this request drives a dedicated session that copies the local
/// session's isolated configuration. The request itself refuses redirects and
/// challenges, and the session is invalidated on every terminal path because it
/// retains its delegate until invalidation.
final class LocalCapabilitiesRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let limit = 64 * 1024
    private let lock = NSLock()
    private let session: URLSession
    private let address: LocalDeviceAddress
    private let delegation: RequestDelegation
    private let targetURL: URL
    private let extraHeaders: [String: String]
    private var task: URLSessionDataTask?
    private var dedicatedSession: URLSession?
    private var continuation: CheckedContinuation<Data, Error>?
    private var cancelled = false
    private var data = Data()

    init(session: URLSession, address: LocalDeviceAddress, delegation: RequestDelegation,
         token: String? = nil) {
        self.session = session
        self.address = address
        self.delegation = delegation
        self.targetURL = address.capabilitiesURL
        self.extraHeaders = token.map { ["X-Rctl-Token": $0] } ?? [:]
    }

    /// The bootstrap probe: the header-gated token delivery. A legacy daemon
    /// answers exactly 404, which the caller reads as the legacy-downgrade case.
    init(session: URLSession, address: LocalDeviceAddress, bootstrap: Bool, delegation: RequestDelegation) {
        self.session = session
        self.address = address
        self.delegation = delegation
        self.targetURL = URL(string: "http://\(address.displayAddress)/v1/bootstrap")!
        self.extraHeaders = ["X-Rctl-Bootstrap": "1"]
    }

    func start(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        var request = URLRequest(url: targetURL)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
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
        let dedicatedSession = dedicatedSession
        self.dedicatedSession = nil
        data.removeAll()
        lock.unlock()
        task?.cancel()
        dedicatedSession?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.url == targetURL else {
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

public extension LocalDeviceClient {
    /// Drop the cached decision for a device so the next attempt probes
    /// bootstrap again — used when the gateway rejects an authenticated
    /// request (token regenerated, legacy daemon upgraded in place).
    func invalidateToken(for address: LocalDeviceAddress) {
        tokenCache.remove(address.displayAddress)
    }
}

/// Per-device cache for the LAN token; an empty value marks a verified legacy
/// daemon so the bootstrap round trip happens once per device per client.
final class LocalTokenCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: String, for key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}

public extension LocalDeviceClient {
    /// The device's HTTP surface is token-gated. Fetch the LAN token from the
    /// header-gated bootstrap endpoint (a barrier no browser page can pass
    /// cross-origin) and cache it per device. The outcome is explicit: a
    /// valid token, nil only for a legacy daemon proven by an exact 404, or a
    /// thrown error for everything else — a failed bootstrap must not
    /// silently downgrade the caller to token-less access.
    func bootstrapToken(for address: LocalDeviceAddress) async throws -> String? {
        if let cached = tokenCache.value(address.displayAddress) { return cached.isEmpty ? nil : cached }
        let operation = LocalCapabilitiesRequest(session: session, address: address, bootstrap: true, delegation: delegation)
        let result: Data
        do {
            result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    operation.start(continuation)
                }
            } onCancel: {
                operation.cancel()
            }
        } catch LocalConnectionError.http(404) {
            tokenCache.set("", for: address.displayAddress)   // legacy daemon sentinel
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: result),
              let fields = object as? [String: Any],
              let token = fields["token"] as? String, Self.validTokenShape(token) else {
            throw LocalConnectionError.invalidResponse
        }
        tokenCache.set(token, for: address.displayAddress)
        return token
    }

    /// Capabilities with one automatic re-probe: a gateway rejection drops
    /// the cached credential decision and retries once, so direct callers
    /// (add device, save, reachability) recover from token rotation or a
    /// legacy-daemon upgrade without a session screen.
    public func capabilitiesAuthenticating(at address: LocalDeviceAddress, camera: Bool = false) async throws -> Capabilities {
        do {
            return try await capabilities(at: address, camera: camera)
        } catch LocalConnectionError.http(403) {
            invalidateToken(for: address)
            return try await capabilities(at: address, camera: camera)
        }
    }

    /// The device's fixed token encoding: exactly 64 lowercase hex characters.
    /// Anything else is malformed and must not enter the cache.
    private static func validTokenShape(_ token: String) -> Bool {
        guard token.count == 64 else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 97 && scalar.value <= 102) || (scalar.value >= 48 && scalar.value <= 57)
        }
    }
}
