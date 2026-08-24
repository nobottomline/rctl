import Foundation
import RctlClient

struct ProbeProfile: Codable, Equatable, Sendable {
    let origin: String
    let relayID: String
    let controller: PairedController
}

struct ProbeProfileStore {
    private let defaults: UserDefaults
    private let key = "rctl.mediaprobe.profile.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ProbeProfile? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ProbeProfile.self, from: data)
    }

    func save(_ profile: ProbeProfile) throws {
        defaults.set(try JSONEncoder().encode(profile), forKey: key)
    }

    func remove() {
        defaults.removeObject(forKey: key)
    }
}
