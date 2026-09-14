import Foundation
import RctlClient

struct ControllerProfile: Codable, Equatable, Identifiable, Sendable {
    let origin: String
    let relayID: String
    let controller: PairedController
    var id: String { relayID }

    func hasSameIdentity(as other: ControllerProfile) -> Bool {
        relayID == other.relayID && origin == other.origin && controller.id == other.controller.id
    }
}

struct ControllerProfileStore {
    private let defaults: UserDefaults
    private let key = "rctl.controller.profile.v1"
    private let collectionKey = "rctl.controller.profiles.v2"
    private let selectionKey = "rctl.controller.selected-relay.v2"
    private let clientProfilePrefix = "rctl.controller.client-profile.v2."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ControllerProfile? {
        guard let profiles = try? loadAll() else { return nil }
        let selected = defaults.string(forKey: selectionKey)
        return profiles.first { $0.relayID == selected } ?? profiles.first
    }

    func loadAll() throws -> [ControllerProfile] {
        if let data = defaults.data(forKey: collectionKey) {
            let profiles = try JSONDecoder().decode([ControllerProfile].self, from: data)
            guard Set(profiles.map(\.relayID)).count == profiles.count else {
                throw ControllerProfileStoreError.duplicateIdentity
            }
            return profiles
        }
        guard let legacy = defaults.data(forKey: key) else { return [] }
        let profile = try JSONDecoder().decode(ControllerProfile.self, from: legacy)
        try persist([profile])
        select(profile.relayID)
        return [profile]
    }

    func save(_ profile: ControllerProfile) throws {
        var profiles = try loadAll()
        if let index = profiles.firstIndex(where: { $0.relayID == profile.relayID }) {
            guard profiles[index].origin == profile.origin else {
                throw ControllerProfileStoreError.duplicateIdentity
            }
            profiles[index] = profile
        } else { profiles.append(profile) }
        try persist(profiles)
        select(profile.relayID)
    }

    func select(_ relayID: String) {
        defaults.set(relayID, forKey: selectionKey)
    }

    func remove(relayID: String) throws {
        let remaining = try loadAll().filter { $0.relayID != relayID }
        try persist(remaining)
        if defaults.string(forKey: selectionKey) == relayID {
            defaults.set(remaining.first?.relayID, forKey: selectionKey)
        }
        defaults.removeObject(forKey: clientProfilePrefix + relayID)
    }

    /// Fingerprint of the device profile this relay last accepted, so the app
    /// re-sends only after an OS or app update, never on a schedule.
    func reportedClientProfile(relayID: String) -> String? {
        defaults.string(forKey: clientProfilePrefix + relayID)
    }

    func setReportedClientProfile(_ fingerprint: String, relayID: String) {
        defaults.set(fingerprint, forKey: clientProfilePrefix + relayID)
    }

    private func persist(_ profiles: [ControllerProfile]) throws {
        defaults.set(try JSONEncoder().encode(profiles), forKey: collectionKey)
        defaults.removeObject(forKey: key)
    }
}

enum ControllerProfileStoreError: Error {
    case duplicateIdentity
}
