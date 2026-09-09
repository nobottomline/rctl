import Combine
import Foundation
import RctlRealtime

struct LocalDeviceProfile: Codable, Equatable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let address: LocalDeviceAddress
}

/// Best-effort LAN reachability shown on the Devices screen. It never gates a
/// connection attempt; opening a device always performs its own preflight.
enum LocalDeviceReachability: Equatable, Sendable {
    case unknown
    case checking
    case reachable(daemonVersion: String?)
    case unreachable
}

@MainActor
final class LocalDevicesModel: ObservableObject {
    @Published private(set) var devices: [LocalDeviceProfile] = []
    @Published private(set) var reachability: [UUID: LocalDeviceReachability] = [:]
    @Published var errorMessage: String?
    let client: LocalDeviceClient
    private let defaults: UserDefaults
    private let storageKey = "rctl.controller.local-devices.v1"
    private var revision: UInt64 = 0
    private var probe: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, client: LocalDeviceClient = LocalDeviceClient()) {
        self.defaults = defaults
        self.client = client
        if let data = defaults.data(forKey: storageKey) {
            do {
                guard data.count <= 64 * 1024 else { throw LocalDeviceStoreError.invalidSavedDevices }
                let saved = try JSONDecoder().decode([LocalDeviceProfile].self, from: data)
                guard saved.count <= 64, Set(saved.map(\.id)).count == saved.count,
                      Set(saved.map(\.address)).count == saved.count,
                      saved.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 80 }) else {
                    throw LocalDeviceStoreError.invalidSavedDevices
                }
                devices = saved
            } catch {
                errorMessage = "Saved local devices could not be read. Add their addresses again."
            }
        }
    }

    func save(address input: String, name: String, editing id: UUID? = nil) async throws -> LocalDeviceProfile {
        let address = try LocalDeviceAddress(input)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= 80 else { throw LocalDeviceStoreError.nameTooLong }
        let currentRevision = revision
        _ = try await client.capabilities(at: address)
        try Task.checkCancellation()
        guard revision == currentRevision else { throw CancellationError() }
        if let id, !devices.contains(where: { $0.id == id }) { throw CancellationError() }
        let existing = devices.first { $0.address == address }
        if let id, let existing, existing.id != id { throw LocalDeviceStoreError.duplicateAddress }
        let profile = LocalDeviceProfile(id: id ?? existing?.id ?? UUID(),
                                         name: name.isEmpty ? address.displayAddress : name, address: address)
        var updated = devices
        if let index = updated.firstIndex(where: { $0.id == profile.id }) {
            updated[index] = profile
        } else {
            guard updated.count < 64 else { throw LocalDeviceStoreError.tooManyDevices }
            updated.append(profile)
        }
        try persist(updated)
        return profile
    }

    func remove(_ profile: LocalDeviceProfile) {
        do { try persist(devices.filter { $0.id != profile.id }) }
        catch { errorMessage = error.localizedDescription }
    }

    func reachability(of profile: LocalDeviceProfile) -> LocalDeviceReachability {
        reachability[profile.id] ?? .unknown
    }

    /// Probes every saved address concurrently with the bounded capabilities
    /// request. A newer probe supersedes an in-flight one.
    func probeReachability() async {
        probe?.cancel()
        let snapshot = devices
        guard !snapshot.isEmpty else { return }
        for device in snapshot { reachability[device.id] = .checking }
        let client = client
        let task = Task { @MainActor [weak self] in
            await withTaskGroup(of: (UUID, LocalDeviceReachability).self) { group in
                for device in snapshot {
                    group.addTask {
                        do {
                            let capabilities = try await client.capabilities(at: device.address)
                            return (device.id, .reachable(daemonVersion: capabilities.daemon?.version))
                        } catch is CancellationError {
                            return (device.id, .unknown)
                        } catch {
                            return (device.id, .unreachable)
                        }
                    }
                }
                for await (id, state) in group {
                    guard !Task.isCancelled, let self, self.devices.contains(where: { $0.id == id }) else { continue }
                    self.reachability[id] = state
                }
            }
        }
        probe = task
        await task.value
    }

    func cancelReachabilityProbe() {
        probe?.cancel()
        probe = nil
    }

    private func persist(_ updated: [LocalDeviceProfile]) throws {
        defaults.set(try JSONEncoder().encode(updated), forKey: storageKey)
        revision &+= 1
        devices = updated
        let ids = Set(updated.map(\.id))
        reachability = reachability.filter { ids.contains($0.key) }
    }

    static func message(for error: Error) -> String {
        if let error = error as? LocalConnectionError { return error.localizedDescription }
        if let error = error as? LocalDeviceStoreError { return error.localizedDescription }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .cannotConnectToHost, .notConnectedToInternet, .networkConnectionLost, .cannotFindHost:
                return "Could not reach the local device. Check its address, network access, iOS Local Network permission, and whether LAN control is enabled."
            case .appTransportSecurityRequiresSecureConnection:
                return "iOS blocked this local connection. The controller's local-network configuration needs attention."
            default: break
            }
        }
        return "The local connection could not be completed."
    }
}

private enum LocalDeviceStoreError: LocalizedError {
    case invalidSavedDevices, nameTooLong, duplicateAddress, tooManyDevices

    var errorDescription: String? {
        switch self {
        case .invalidSavedDevices: "Saved local devices are invalid."
        case .nameTooLong: "Use a name of 80 characters or fewer."
        case .duplicateAddress: "Another saved device already uses this address."
        case .tooManyDevices: "Remove a saved local device before adding another. The limit is 64."
        }
    }
}
