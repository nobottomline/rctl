import Darwin
import dnssd
import Foundation

/// DNS-only resolution. No TCP connection or HTTP request occurs here.
@MainActor
public final class LocalDeviceResolver {
    private var queries: [UUID: LocalDNSQuery] = [:]
    public init() {}

    public func resolve(_ identity: LocalServiceIdentity, interfaceIndices: [UInt32]) async throws -> ResolvedLocalDevice {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        var lastError: Error = LocalDiscoveryError.unsupportedNetwork
        for index in interfaceIndices.prefix(8) {
            try Task.checkCancellation()
            let remaining = ContinuousClock.now.duration(to: end)
            guard remaining > .zero else { throw LocalDiscoveryError.timedOut }
            do { return try await resolve(identity, interfaceIndex: index, timeout: remaining) }
            catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        throw lastError
    }

    public func resolve(_ identity: LocalServiceIdentity, interfaceIndex: UInt32, timeout: Duration = .seconds(5)) async throws -> ResolvedLocalDevice {
        try Task.checkCancellation()
        guard queries.count < 4 else { throw LocalDiscoveryError.busy }
        let id = UUID()
        let query = LocalDNSQuery(identity: identity, interfaceIndex: interfaceIndex, timeout: min(timeout, .seconds(5)))
        queries[id] = query
        defer { queries[id] = nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { query.start($0) }
        } onCancel: {
            Task { @MainActor in query.finish(.failure(CancellationError())) }
        }
    }

    public func cancelAll() {
        for query in queries.values { query.finish(.failure(CancellationError())) }
        queries.removeAll()
    }
}

@MainActor
private final class LocalDNSQuery {
    let identity: LocalServiceIdentity
    let interfaceIndex: UInt32
    let timeout: Duration
    var resolveRef: DNSServiceRef?
    var addressRef: DNSServiceRef?
    var continuation: CheckedContinuation<ResolvedLocalDevice, Error>?
    var deadline: Task<Void, Never>?
    var record: LocalDiscoveryRecord?
    var port: UInt16 = 0
    var finished = false
    var seenAddresses = 0
    var candidates: [ResolvedLocalDevice] = []

    init(identity: LocalServiceIdentity, interfaceIndex: UInt32, timeout: Duration) {
        self.identity = identity; self.interfaceIndex = interfaceIndex; self.timeout = timeout
    }

    func start(_ continuation: CheckedContinuation<ResolvedLocalDevice, Error>) {
        guard !finished else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let error = DNSServiceResolve(&resolveRef, 0, interfaceIndex, identity.name, identity.type, identity.domain,
            { _, _, interface, error, _, hostname, port, length, txt, context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    let query = Unmanaged<LocalDNSQuery>.fromOpaque(context).takeUnretainedValue()
                    query.resolved(interface: interface, error: error, hostname: hostname, port: port, length: length, txt: txt)
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        guard error == kDNSServiceErr_NoError, let resolveRef else { finish(.failure(LocalDiscoveryError.unavailable)); return }
        guard DNSServiceSetDispatchQueue(resolveRef, .main) == kDNSServiceErr_NoError else {
            finish(.failure(LocalDiscoveryError.unavailable)); return
        }
        deadline = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.finish(.failure(LocalDiscoveryError.timedOut))
        }
    }

    func resolved(interface: UInt32, error: DNSServiceErrorType, hostname: UnsafePointer<CChar>?,
                  port: UInt16, length: UInt16, txt: UnsafePointer<UInt8>?) {
        guard !finished, addressRef == nil else { return }
        guard error == kDNSServiceErr_NoError, let hostname, let txt,
              length > 0, length <= LocalDiscoveryRecord.maximumBytes,
              interfaceIndex == 0 || interface == interfaceIndex else {
            finish(.failure(LocalDiscoveryError.unavailable)); return
        }
        let host = String(cString: hostname)
        guard host.utf8.count <= 253, host.lowercased().hasSuffix(".local."), port != 0 else {
            finish(.failure(LocalDiscoveryError.unsupportedNetwork)); return
        }
        do {
            let record = try LocalDiscoveryRecord(data: Data(bytes: txt, count: Int(length)))
            guard record.compatible else { throw LocalDiscoveryError.unsupportedVersion }
            self.record = record
        } catch { finish(.failure(error)); return }
        self.port = UInt16(bigEndian: port)
        // Never use NWConnection to resolve: that would connect before target validation.
        let error = DNSServiceGetAddrInfo(&addressRef, 0, interface, DNSServiceProtocol(kDNSServiceProtocol_IPv4), host,
            { _, flags, interface, error, _, address, _, context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    let query = Unmanaged<LocalDNSQuery>.fromOpaque(context).takeUnretainedValue()
                    query.addressed(flags: flags, interface: interface, error: error, address: address)
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        guard error == kDNSServiceErr_NoError, let addressRef,
              DNSServiceSetDispatchQueue(addressRef, .main) == kDNSServiceErr_NoError else {
            finish(.failure(LocalDiscoveryError.unavailable)); return
        }
    }

    func addressed(flags: DNSServiceFlags, interface: UInt32, error: DNSServiceErrorType, address: UnsafePointer<sockaddr>?) {
        guard !finished else { return }
        guard error == kDNSServiceErr_NoError, let address, let record else {
            finish(.failure(LocalDiscoveryError.unsupportedNetwork)); return
        }
        seenAddresses += 1
        guard seenAddresses <= 8 else { finish(.failure(LocalDiscoveryError.unsupportedNetwork)); return }
        if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
           interfaceIndex == 0 || interface == interfaceIndex,
           address.pointee.sa_family == sa_family_t(AF_INET) {
            var value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &value, &text, socklen_t(text.count)) != nil,
               let target = try? LocalDeviceAddress("\(String(decoding: text.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)):\(port)") {
                candidates.append(.init(address: target, record: record, interfaceIndex: interface))
            }
        }
        if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 {
            if let candidate = candidates.sorted(by: { $0.address.displayAddress < $1.address.displayAddress }).first {
                finish(.success(candidate))
            } else { finish(.failure(LocalDiscoveryError.unsupportedNetwork)) }
        }
    }

    func finish(_ result: Result<ResolvedLocalDevice, Error>) {
        guard !finished else { return }
        finished = true
        if let resolveRef { DNSServiceRefDeallocate(resolveRef) }; resolveRef = nil
        if let addressRef { DNSServiceRefDeallocate(addressRef) }; addressRef = nil
        deadline?.cancel(); deadline = nil
        let completion = continuation; continuation = nil
        completion?.resume(with: result)
    }
}
