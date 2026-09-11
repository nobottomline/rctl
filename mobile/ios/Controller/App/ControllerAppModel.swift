import Combine
import Foundation
import RctlClient
import UIKit

@MainActor
final class ControllerAppModel: ObservableObject {
    @Published private(set) var profile: ControllerProfile?
    @Published private(set) var savedProfiles: [ControllerProfile] = []
    @Published private(set) var devices: [ControllerDevice] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isRevoking = false
    @Published var presentedError: String?
    /// Set when "Delete relay" could not get the relay's revocation acknowledgement.
    /// The view offers to delete locally anyway; nothing is removed until then.
    @Published var relayDeletionFailure: RelayDeletionFailure?

    struct RelayDeletionFailure: Equatable {
        let message: String
        /// The relay no longer recognizes this controller: an admin already revoked it.
        let alreadyRevoked: Bool
    }

    private let api: ControllerAPIClient
    private let keychain: KeychainControllerStore
    private let profiles: ControllerProfileStore
    private let allowInsecureLoopback: Bool
    private var accessToken: String?
    private var accessExpiresAt: Int64?
    private var restored = false
    private var profileRevision: UInt64 = 0
    private var refreshOperation: (id: UUID, task: Task<AccessSession, Error>)?
    private let networkPath = NetworkPathObserver()
    private var profileSyncTask: Task<Void, Never>?

    init(
        api: ControllerAPIClient = ControllerAPIClient(),
        keychain: KeychainControllerStore = KeychainControllerStore(),
        profiles: ControllerProfileStore = ControllerProfileStore(),
        allowInsecureLoopback: Bool? = nil
    ) {
        self.api = api
        self.keychain = keychain
        self.profiles = profiles
        self.allowInsecureLoopback = allowInsecureLoopback ?? Self.debugLoopbackEnabled
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        do { savedProfiles = try profiles.loadAll() }
        catch { presentedError = "Saved relay profiles could not be read. They have not been overwritten."; return }
        guard let stored = profiles.load() else { return }
        profile = stored
        await refreshDevices()
    }

    @discardableResult
    func pair(using rawPayload: String) async -> Bool {
        guard !isBusy else { return false }
        invalidateProfileRequests()
        let revision = profileRevision
        var paired = false
        isBusy = true
        defer { if profileRevision == revision { isBusy = false } }
        do {
            guard let data = rawPayload.data(using: .utf8) else {
                throw ControllerClientError.invalidPairing
            }
            let pairing = try api.decodePairing(
                from: data,
                allowInsecureLoopback: allowInsecureLoopback
            )
            // A relay-provided ID must not overwrite another saved identity or
            // reuse its refresh credential at a different origin.
            if try profiles.loadAll().contains(where: { $0.relayID == pairing.relayID }) {
                presentedError = "This relay is already saved. Select it from the Relay menu."
                return false
            }
            if let existing = try keychain.loadCredential(relayID: pairing.relayID),
               existing.origin != pairing.origin {
                throw ControllerProfileStoreError.duplicateIdentity
            }
            let key = try keychain.loadOrCreateSigningKey(relayID: pairing.relayID)
            let claim = try await api.claim(
                pairing: pairing,
                controllerName: UIDevice.current.name,
                signingKey: key,
                allowInsecureLoopback: allowInsecureLoopback
            )
            try requireCurrentProfile(revision)
            let credential = ControllerRefreshCredential(pairing: pairing, claim: claim)
            try keychain.save(credential)
            let newProfile = ControllerProfile(
                origin: pairing.origin,
                relayID: pairing.relayID,
                controller: claim.controller
            )
            try profiles.save(newProfile)
            savedProfiles = try profiles.loadAll()
            profile = newProfile
            paired = true
            accessToken = claim.tokens.accessToken
            accessExpiresAt = claim.tokens.accessExpiresAt
            devices = []
            try await loadDevices(
                session: AccessSession(profile: newProfile, token: claim.tokens.accessToken, key: key),
                revision: revision
            )
            syncClientProfile(for: newProfile)
            return true
        } catch {
            if profileRevision == revision, !(error is CancellationError), !Task.isCancelled {
                presentedError = Self.message(for: error)
            }
        }
        return profileRevision == revision && paired
    }

    func selectProfile(_ relayID: String) async {
        guard !isRevoking, profile?.relayID != relayID,
              let selected = savedProfiles.first(where: { $0.relayID == relayID }) else { return }
        invalidateProfileRequests()
        accessToken = nil
        accessExpiresAt = nil
        devices = []
        profiles.select(relayID)
        profile = selected
        await refreshDevices()
    }

    func refreshDevices() async {
        guard profile != nil, !isBusy else { return }
        let revision = profileRevision
        isBusy = true
        defer { if profileRevision == revision { isBusy = false } }
        do {
            let session = try await ensureAccessSession(forceRefresh: accessToken == nil)
            do {
                try await loadDevices(session: session, revision: revision)
            } catch ControllerClientError.http(status: 401, code: _) {
                try requireCurrentProfile(revision)
                let refreshed = try await ensureAccessSession(forceRefresh: true)
                try await loadDevices(session: refreshed, revision: revision)
            }
        } catch {
            if profileRevision == revision, !(error is CancellationError), !Task.isCancelled {
                presentedError = Self.message(for: error)
            }
        }
    }

    func signalingRequest(deviceID: String, media: ControllerMediaRole, expectedProfile: ControllerProfile? = nil) async throws -> URLRequest {
        if let expectedProfile, profile != expectedProfile { throw CancellationError() }
        let revision = profileRevision
        guard let device = devices.first(where: { $0.id == deviceID }) else {
            throw SessionPreflightError.deviceUnavailable
        }
        guard device.online else {
            throw SessionPreflightError.deviceOffline
        }
        guard device.compatible else {
            throw SessionPreflightError.incompatibleDevice(device.compatibilityError)
        }
        guard device.supportsNativeControllerSessions else {
            throw SessionPreflightError.deviceUpdateRequired(device.daemonVersion)
        }
        guard device.supports(media) else {
            throw SessionPreflightError.unsupportedMedia(media)
        }
        let requiredScope: ControllerScope = media == .camera ? .camera : .screenView
        guard profile?.controller.scopes.contains(requiredScope) == true else {
            throw SessionPreflightError.missingScope(requiredScope)
        }

        let session = try await ensureAccessSession(forceRefresh: false)
        try requireCurrentProfile(revision)
        do {
            return try api.makeSignalingRequest(
                origin: session.profile.origin,
                deviceID: deviceID,
                media: media,
                accessToken: session.token,
                signingKey: session.key,
                allowInsecureLoopback: allowInsecureLoopback
            )
        } catch ControllerClientError.invalidToken {
            let refreshed = try await ensureAccessSession(forceRefresh: true)
            try requireCurrentProfile(revision)
            return try api.makeSignalingRequest(
                origin: refreshed.profile.origin,
                deviceID: deviceID,
                media: media,
                accessToken: refreshed.token,
                signingKey: refreshed.key,
                allowInsecureLoopback: allowInsecureLoopback
            )
        }
    }

    func resetProfile() {
        guard let relayID = profile?.relayID else { return }
        invalidateProfileRequests()
        do {
            _ = try profiles.loadAll() // Validate metadata before deleting any credential.
            try keychain.deleteProfile(relayID: relayID)
            try profiles.remove(relayID: relayID)
            savedProfiles = try profiles.loadAll()
            accessToken = nil
            accessExpiresAt = nil
            devices = []
            profile = profiles.load()
            if profile != nil { Task { await refreshDevices() } }
        } catch {
            presentedError = Self.message(for: error)
        }
    }

    func revokeProfile() async {
        await revokeAndForget { [weak self] error in
            self?.presentedError = Self.revocationNotConfirmedMessage
        }
    }

    /// The single destructive action for a saved relay: revoke this controller on
    /// the relay, then remove the profile and its keys from the phone. Local
    /// deletion waits for the relay's acknowledgement; if that never comes the
    /// view offers "Delete anyway" through `relayDeletionFailure`.
    func deleteRelay() async {
        await revokeAndForget { [weak self] error in
            guard let self else { return }
            let alreadyRevoked = Self.isAlreadyRevoked(error)
            relayDeletionFailure = RelayDeletionFailure(
                message: alreadyRevoked
                    ? "The relay no longer recognizes this controller: its access was already revoked from relay admin. The profile and keys can be removed from this phone."
                    : "The relay did not confirm the revocation. Deleting anyway removes the profile from this phone, but the controller stays listed in relay admin until you revoke it there.",
                alreadyRevoked: alreadyRevoked
            )
        }
    }

    /// Completes a delete that the relay could not acknowledge. Only reachable
    /// through the confirmation the view shows for `relayDeletionFailure`.
    func forceDeleteRelay() {
        relayDeletionFailure = nil
        resetProfile()
    }

    private func revokeAndForget(onFailure: @MainActor (Error) -> Void) async {
        guard let selected = profile, !isBusy, !isRevoking else { return }
        let revision = profileRevision
        isRevoking = true
        isBusy = true
        relayDeletionFailure = nil
        defer {
            isRevoking = false
            if profileRevision == revision { isBusy = false }
        }
        do {
            let session = try await ensureAccessSession(forceRefresh: false)
            try requireCurrentProfile(revision)
            do {
                try await api.revokeCurrentController(origin: selected.origin, accessToken: session.token,
                    signingKey: session.key, allowInsecureLoopback: allowInsecureLoopback)
            } catch ControllerClientError.http(status: 401, code: _) {
                // A stale access token is retried once; a rejected refresh
                // credential is the relay saying the controller is already gone.
                try requireCurrentProfile(revision)
                let refreshed = try await ensureAccessSession(forceRefresh: true)
                try requireCurrentProfile(revision)
                try await api.revokeCurrentController(origin: selected.origin, accessToken: refreshed.token,
                    signingKey: refreshed.key, allowInsecureLoopback: allowInsecureLoopback)
            }
            try requireCurrentProfile(revision)
            // Only a confirmed server acknowledgement permits local deletion.
            resetProfile()
        } catch {
            guard profileRevision == revision, !(error is CancellationError), !Task.isCancelled else { return }
            onFailure(error)
        }
    }

    private static let revocationNotConfirmedMessage =
        "Revocation was not confirmed. The local profile has been kept. Check relay admin or retry."

    /// A 401 from the relay means the credential itself is rejected: the
    /// controller was revoked (or deleted) on the server side already.
    static func isAlreadyRevoked(_ error: Error) -> Bool {
        if case ControllerClientError.http(status: 401, code: _) = error { return true }
        return false
    }

    // MARK: - Device profile

    /// Sends the device profile when it differs from what this relay last
    /// accepted. Runs detached from the caller so pairing and presence never
    /// wait on it; failures are silent and retried on the next launch.
    func syncClientProfile(for expectedProfile: ControllerProfile, force: Bool = false) {
        let fingerprintOnRecord = profiles.reportedClientProfile(relayID: expectedProfile.relayID)
        let current = ControllerDeviceProfile.current()
        guard force || fingerprintOnRecord != current.fingerprint else { return }
        profileSyncTask?.cancel()
        profileSyncTask = Task { [weak self] in
            guard let self else { return }
            let revision = profileRevision
            do {
                var session = try await ensureAccessSession(forceRefresh: false)
                try requireCurrentProfile(revision)
                guard profile == expectedProfile else { return }
                do {
                    try await api.updateClientProfile(origin: session.profile.origin, profile: current,
                        accessToken: session.token, signingKey: session.key, allowInsecureLoopback: allowInsecureLoopback)
                } catch ControllerClientError.http(status: 401, code: _) {
                    try requireCurrentProfile(revision)
                    session = try await ensureAccessSession(forceRefresh: true)
                    try requireCurrentProfile(revision)
                    guard profile == expectedProfile else { return }
                    try await api.updateClientProfile(origin: session.profile.origin, profile: current,
                        accessToken: session.token, signingKey: session.key, allowInsecureLoopback: allowInsecureLoopback)
                }
                try requireCurrentProfile(revision)
                profiles.setReportedClientProfile(current.fingerprint, relayID: expectedProfile.relayID)
            } catch {
                // Old relays answer 404/405; transient failures retry next launch.
            }
        }
    }

    /// Owned by the root view's foreground task, including while a session is open.
    /// No background keepalive or presence for unselected saved relays.
    func maintainPresence(for expectedProfile: ControllerProfile) async {
        syncClientProfile(for: expectedProfile)
        while !Task.isCancelled, profile == expectedProfile {
            if isBusy {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                continue
            }
            do {
                try await sendPresence(for: expectedProfile)
            } catch is CancellationError { return }
            catch ControllerClientError.http(status: 404, code: _) { return }
            catch ControllerClientError.http(status: 405, code: _) { return }
            catch ControllerClientError.http(status: 401, code: _) { return }
            catch { /* Transient failures let the server lease expire. */ }
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
        }
    }

    func sendPresence(for expectedProfile: ControllerProfile) async throws {
        guard profile == expectedProfile, !isRevoking else { throw CancellationError() }
        let revision = profileRevision
        var session = try await ensureAccessSession(forceRefresh: false)
        try requireCurrentProfile(revision)
        guard !isRevoking else { throw CancellationError() }
        let telemetry = ControllerDeviceProfile.telemetry(network: networkPath.current)
        do {
            try await api.heartbeat(origin: session.profile.origin, telemetry: telemetry, accessToken: session.token,
                signingKey: session.key, allowInsecureLoopback: allowInsecureLoopback)
        } catch ControllerClientError.http(status: 401, code: _) {
            try requireCurrentProfile(revision)
            guard !isRevoking else { throw CancellationError() }
            session = try await ensureAccessSession(forceRefresh: true)
            try requireCurrentProfile(revision)
            guard !isRevoking else { throw CancellationError() }
            try await api.heartbeat(origin: session.profile.origin, telemetry: telemetry, accessToken: session.token,
                signingKey: session.key, allowInsecureLoopback: allowInsecureLoopback)
        }
        try requireCurrentProfile(revision)
    }

    private func ensureAccessSession(forceRefresh: Bool) async throws -> AccessSession {
        try Task.checkCancellation()
        guard let profile else { throw ControllerClientError.corruptCredential }
        let revision = profileRevision
        let key = try keychain.loadOrCreateSigningKey(relayID: profile.relayID)
        let minimumLifetime = Int64(Date().timeIntervalSince1970) + 30
        if !forceRefresh, let accessToken, let accessExpiresAt, accessExpiresAt > minimumLifetime {
            return AccessSession(profile: profile, token: accessToken, key: key)
        }
        if refreshOperation == nil {
            guard let credential = try keychain.loadCredential(relayID: profile.relayID) else {
                throw ControllerClientError.corruptCredential
            }
            guard credential.origin == profile.origin,
                  credential.controller.id == profile.controller.id else {
                throw ControllerClientError.corruptCredential
            }
            let task = Task { @MainActor in
                let tokens = try await api.refresh(
                    origin: profile.origin,
                    refreshToken: credential.refreshToken,
                    signingKey: key,
                    allowInsecureLoopback: allowInsecureLoopback
                )
                try requireCurrentProfile(revision)
                let renewed = ControllerRefreshCredential(
                    origin: profile.origin,
                    relayID: profile.relayID,
                    controller: profile.controller,
                    refreshToken: tokens.refreshToken,
                    refreshExpiresAt: tokens.refreshExpiresAt
                )
                try keychain.save(renewed)
                accessToken = tokens.accessToken
                accessExpiresAt = tokens.accessExpiresAt
                return AccessSession(profile: profile, token: tokens.accessToken, key: key)
            }
            refreshOperation = (UUID(), task)
        }
        guard let operation = refreshOperation else { throw CancellationError() }
        defer {
            if refreshOperation?.id == operation.id { refreshOperation = nil }
        }
        let session = try await operation.task.value
        try requireCurrentProfile(revision)
        return session
    }

    private func loadDevices(session: AccessSession, revision: UInt64) async throws {
        try requireCurrentProfile(revision)
        let loaded = try await api.devices(
            origin: session.profile.origin,
            accessToken: session.token,
            signingKey: session.key,
            allowInsecureLoopback: allowInsecureLoopback
        )
        try requireCurrentProfile(revision)
        devices = loaded
    }

    private func requireCurrentProfile(_ revision: UInt64) throws {
        try Task.checkCancellation()
        guard profileRevision == revision else { throw CancellationError() }
    }

    private func invalidateProfileRequests() {
        profileRevision &+= 1
        refreshOperation?.task.cancel()
        refreshOperation = nil
        profileSyncTask?.cancel()
        profileSyncTask = nil
        relayDeletionFailure = nil
        isBusy = false
        presentedError = nil
    }

    private static var debugLoopbackEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["RCTL_CONTROLLER_ALLOW_INSECURE_LOOPBACK"] == "1" ||
            ProcessInfo.processInfo.arguments.contains("--rctl-allow-insecure-loopback")
#else
        false
#endif
    }

    static func message(for error: Error) -> String {
        switch error {
        case ControllerProfileStoreError.duplicateIdentity:
            "This relay identity conflicts with a saved profile. Existing credentials were not replaced."
        case let error as SessionPreflightError:
            error.localizedDescription
        case ControllerClientError.expiredPairing:
            "The pairing code expired. Create a new one in relay admin."
        case ControllerClientError.incompatibleProtocol:
            "This controller and relay use incompatible protocol versions."
        case ControllerClientError.insecureRelayOrigin:
            "Pairing requires an HTTPS relay."
        case ControllerClientError.invalidPairing:
            "The pairing code is invalid."
        case ControllerClientError.relayIdentityMismatch,
             ControllerClientError.http(status: 401, code: "relay_identity_mismatch"):
            "The relay identity does not match this pairing code. Create a new code on the intended relay."
        case let ControllerClientError.http(status, code):
            "Relay request failed (\(status), \(code))."
        case ControllerClientError.corruptCredential:
            "The local controller credential is missing or damaged. Reset this profile and pair again."
        default:
            "The request could not be completed."
        }
    }

    private enum SessionPreflightError: LocalizedError {
        case deviceUnavailable
        case deviceOffline
        case incompatibleDevice(String?)
        case deviceUpdateRequired(String?)
        case unsupportedMedia(ControllerMediaRole)
        case missingScope(ControllerScope)

        var errorDescription: String? {
            switch self {
            case .deviceUnavailable:
                "This device is no longer available. Refresh the device list."
            case .deviceOffline:
                "The device is offline. Wait for it to reconnect and try again."
            case let .incompatibleDevice(reason):
                reason ?? "The device uses an incompatible protocol version."
            case let .deviceUpdateRequired(version):
                if let version {
                    "Update rctld \(version) before using the native controller. Browser control remains available."
                } else {
                    "Update rctld before using the native controller. Browser control remains available."
                }
            case let .unsupportedMedia(media):
                switch media {
                case .screen:
                    "This rctld build does not support native screen streaming."
                case .camera:
                    "This rctld build does not support native camera streaming."
                }
            case let .missingScope(scope):
                "This controller does not have the \(scope.rawValue) permission. Pair it again with the required access."
            }
        }
    }

    private struct AccessSession {
        let profile: ControllerProfile
        let token: String
        let key: ControllerSigningKey
    }
}
