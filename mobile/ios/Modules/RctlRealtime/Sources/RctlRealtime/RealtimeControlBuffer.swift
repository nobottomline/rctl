import Foundation
import RctlProtocol

public struct ScheduledControlMessage: Sendable {
    public let message: ControlMessage
    public let delay: TimeInterval
    public init(_ message: ControlMessage, after delay: TimeInterval) {
        self.message = message
        self.delay = delay
    }
}

/// Admission is synchronous, before hopping to the transport queue. One timer
/// drains this bounded buffer; typing never creates one timer per character.
final class RealtimeControlBuffer: @unchecked Sendable {
    struct Entry: Sendable {
        let message: ControlMessage
        let data: Data
        let deadline: TimeInterval
        let keyboard: Bool
        let generation: UInt64
        let keyboardGeneration: UInt64
    }
    static let maximumDelay: TimeInterval = 11
    static let maximumCount = 1024
    static let maximumBytes = 64 * 1024
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var bytes = 0
    private var generation: UInt64 = 0
    private var keyboardGeneration: UInt64 = 0
    private var open = false
    private var scheduledDrain: UInt64?

    func scheduleDrain() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard scheduledDrain == nil else { return nil }
        scheduledDrain = generation
        return generation
    }

    func beginDrain(_ revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == revision, scheduledDrain == revision else { return false }
        scheduledDrain = nil
        return true
    }

    func reset(open: Bool? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let open { self.open = open }
        generation &+= 1
        scheduledDrain = nil
        entries.removeAll()
        bytes = 0
    }

    func cancelKeyboard() {
        lock.lock()
        defer { lock.unlock() }
        keyboardGeneration &+= 1
        entries.removeAll { $0.keyboard }
        bytes = entries.reduce(0) { $0 + $1.data.count }
    }

    func append(_ message: ControlMessage, delay: TimeInterval, keyboard: Bool,
                now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        append([ScheduledControlMessage(message, after: delay)], keyboard: keyboard, now: now)
    }

    func append(_ messages: [ScheduledControlMessage], keyboard: Bool,
                now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard !messages.isEmpty, messages.count <= Self.maximumCount else { return false }
        var encoded: [(ScheduledControlMessage, Data)] = []
        var total = 0
        for value in messages {
            guard value.delay.isFinite, (0...Self.maximumDelay).contains(value.delay),
                  let data = try? WireJSON.encode(value.message), data.count <= Self.maximumBytes - total else { return false }
            encoded.append((value, data))
            total += data.count
        }
        lock.lock()
        defer { lock.unlock() }
        guard open, messages.count <= Self.maximumCount - entries.count,
              total <= Self.maximumBytes - bytes else { return false }
        for (value, data) in encoded {
            let entry = Entry(message: value.message, data: data, deadline: now + value.delay,
                          keyboard: keyboard, generation: generation, keyboardGeneration: keyboardGeneration)
            // Equal deadlines preserve key-down/key-up and modifier ordering.
            let index = entries.firstIndex { $0.deadline > entry.deadline } ?? entries.endIndex
            entries.insert(entry, at: index)
        }
        bytes += total
        return true
    }

    func takeDue(now: TimeInterval, revision: UInt64? = nil) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        if let revision, revision != generation { return [] }
        let count = entries.prefix { $0.deadline <= now }.count
        let due = Array(entries.prefix(count))
        entries.removeFirst(count)
        bytes -= due.reduce(0) { $0 + $1.data.count }
        return due
    }

    func isCurrent(_ entry: Entry) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return open && entry.generation == generation &&
            (!entry.keyboard || entry.keyboardGeneration == keyboardGeneration)
    }

    func isCurrent(_ revision: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return open && generation == revision
    }

    var nextDeadline: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first?.deadline
    }
}

struct PressedControlState {
    private struct Key: Hashable { let page: Int; let usage: Int }
    private var touches: [Int: ControlMessage] = [:]
    private var keys: Set<Key> = []

    mutating func sent(_ message: ControlMessage) {
        switch message {
        case let .touch(phase, finger, x, y):
            if phase == 2 { touches.removeValue(forKey: finger) }
            else { touches[finger] = .touch(phase: 2, finger: finger, x: x, y: y) }
        case let .key(page, usage, down):
            let key = Key(page: page, usage: usage)
            if down { keys.insert(key) } else { keys.remove(key) }
        case .keyTap: break
        }
    }

    mutating func releases(keyboardOnly: Bool = false) -> [ControlMessage] {
        var output: [ControlMessage] = []
        if !keyboardOnly {
            output = touches.sorted { $0.key < $1.key }.map(\.value)
            touches.removeAll()
        }
        let releasedKeys = keys.filter { !keyboardOnly || $0.page == HIDKeyboard.page }
        output += releasedKeys.sorted { ($0.page, $0.usage) < ($1.page, $1.usage) }
            .map { .key(page: $0.page, usage: $0.usage, down: false) }
        keys.subtract(releasedKeys)
        return output
    }
}
