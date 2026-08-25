import Foundation
import RctlClient

struct ControllerProfile: Codable, Equatable, Sendable {
    let origin: String
    let relayID: String
    let controller: PairedController
}

struct ControllerProfileStore {
    private let defaults: UserDefaults
    private let key = "rctl.controller.profile.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ControllerProfile? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ControllerProfile.self, from: data)
    }

    func save(_ profile: ControllerProfile) throws {
        defaults.set(try JSONEncoder().encode(profile), forKey: key)
    }

    func remove() {
        defaults.removeObject(forKey: key)
    }
}
