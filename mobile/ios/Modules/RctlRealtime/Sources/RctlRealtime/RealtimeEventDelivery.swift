import Foundation

/// Invalidates queued UI callbacks synchronously when the caller starts or stops
/// a session, independently of the transport queue's asynchronous cleanup.
final class RealtimeEventDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private let handler: RctlRealtimeSession.EventHandler

    init(handler: @escaping RctlRealtimeSession.EventHandler) {
        self.handler = handler
    }

    @discardableResult
    func advance(enqueue: (UInt64) -> Void = { _ in }) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        revision &+= 1
        // Revision order and transport-command order must agree even if two
        // callers start/stop concurrently. The closure only enqueues work.
        enqueue(revision)
        return revision
    }

    func isCurrent(_ value: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return revision == value
    }

    func emit(_ event: RctlRealtimeEvent, revision: UInt64) {
        DispatchQueue.main.async { [self] in
            guard isCurrent(revision) else { return }
            handler(event)
        }
    }
}
