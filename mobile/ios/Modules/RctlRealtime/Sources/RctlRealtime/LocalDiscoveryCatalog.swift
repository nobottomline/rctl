import Foundation

/// Bounded presentation and retry state. Missing services are never connectable
/// from a cached endpoint; an explicit selection must resolve DNS again.
struct LocalDiscoveryCatalog {
    struct Entry {
        var device: DiscoveredLocalDevice
        var revision: UInt64
        var missingSince: TimeInterval?
        var retryAt: TimeInterval?
        var failures = 0
    }

    private(set) var entries: [LocalServiceIdentity: Entry] = [:]
    private var revision: UInt64 = 0
    static let retention: TimeInterval = 30
    static let capacity = 64

    var devices: [DiscoveredLocalDevice] {
        entries.values.map(\.device).sorted { $0.id.name < $1.id.name }
    }

    mutating func update(_ sources: [LocalServiceIdentity: [UInt32]], changed: Set<LocalServiceIdentity>, now: TimeInterval) {
        for id in Array(entries.keys) where sources[id] == nil {
            guard entries[id]?.missingSince == nil else { continue }
            revision &+= 1
            entries[id]?.revision = revision
            entries[id]?.missingSince = now
            entries[id]?.retryAt = nil
            entries[id]?.device.isPresent = false
            entries[id]?.device.endpoint = nil
            entries[id]?.device.error = .unavailable
        }
        expire(now: now)
        for (id, interfaces) in sources.prefix(Self.capacity) {
            if let entry = entries[id], entry.missingSince == nil, !changed.contains(id) { continue }
            if entries[id] == nil, entries.count >= Self.capacity {
                guard let oldest = entries.filter({ $0.value.missingSince != nil })
                    .min(by: { $0.value.missingSince! < $1.value.missingSince! })?.key else { continue }
                entries[oldest] = nil
            }
            revision &+= 1
            entries[id] = Entry(device: .init(id: id, interfaces: Array(interfaces.prefix(8)), endpoint: nil, error: nil), revision: revision)
        }
    }

    mutating func expire(now: TimeInterval) {
        for (id, entry) in entries {
            if let since = entry.missingSince, now - since >= Self.retention { entries[id] = nil }
        }
    }

    func ready(now: TimeInterval) -> [Entry] {
        entries.values.filter {
            $0.missingSince == nil && $0.device.endpoint == nil &&
            ($0.device.error == nil || ($0.retryAt.map { $0 <= now } ?? false))
        }.sorted { $0.device.id.name < $1.device.id.name }
    }

    mutating func complete(_ id: LocalServiceIdentity, revision: UInt64,
                           result: Result<ResolvedLocalDevice, LocalDiscoveryError>, now: TimeInterval) {
        guard var entry = entries[id], entry.revision == revision, entry.missingSince == nil else { return }
        switch result {
        case .success(let endpoint):
            entry.device.endpoint = endpoint
            entry.device.error = nil
            entry.retryAt = nil
            entry.failures = 0
        case .failure(let error):
            entry.device.endpoint = nil
            entry.device.error = error
            switch error {
            case .unavailable, .timedOut, .busy:
                entry.retryAt = now + min(30, Double(1 << min(entry.failures, 5)))
                entry.failures = min(entry.failures + 1, 5)
            case .unsupportedNetwork, .unsupportedVersion, .malformedRecord:
                entry.retryAt = nil
            }
        }
        entries[id] = entry
    }
}
