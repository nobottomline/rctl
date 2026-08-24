import Combine
import Foundation
import RctlClient
import UIKit

@MainActor
final class ProbeAppModel: ObservableObject {
    @Published private(set) var profile: ProbeProfile?
    @Published private(set) var devices: [ControllerDevice] = []
    @Published private(set) var isBusy = false
    @Published var presentedError: String?

    private let api: ControllerAPIClient
    private let keychain: KeychainControllerStore
    private let profiles: ProbeProfileStore
    private var accessToken: String?
    private var accessExpiresAt: Int64?
    private var restored = false

    init(
        api: ControllerAPIClient = ControllerAPIClient(),
        keychain: KeychainControllerStore = KeychainControllerStore(),
        profiles: ProbeProfileStore = ProbeProfileStore()
    ) {
        self.api = api
        self.keychain = keychain
        self.profiles = profiles
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        guard let stored = profiles.load() else { return }
        profile = stored
        await refreshDevices()
    }

    func pair(using rawPayload: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard let data = rawPayload.data(using: .utf8) else {
                throw ControllerClientError.invalidPairing
            }
            let pairing = try api.decodePairing(from: data)
            let key = try keychain.loadOrCreateSigningKey(relayID: pairing.relayID)
            let claim = try await api.claim(
                pairing: pairing,
                controllerName: UIDevice.current.name,
                signingKey: key
            )
            let credential = ControllerRefreshCredential(pairing: pairing, claim: claim)
            try keychain.save(credential)
            let newProfile = ProbeProfile(
                origin: pairing.origin,
                relayID: pairing.relayID,
                controller: claim.controller
            )
            try profiles.save(newProfile)
            profile = newProfile
            accessToken = claim.tokens.accessToken
            accessExpiresAt = claim.tokens.accessExpiresAt
            try await loadDevices(accessToken: claim.tokens.accessToken, signingKey: key)
        } catch {
            presentedError = Self.message(for: error)
        }
    }

    func refreshDevices() async {
        guard profile != nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let session = try await ensureAccessSession(forceRefresh: accessToken == nil)
            do {
                try await loadDevices(accessToken: session.token, signingKey: session.key)
            } catch ControllerClientError.http(status: 401, code: _) {
                let refreshed = try await ensureAccessSession(forceRefresh: true)
                try await loadDevices(accessToken: refreshed.token, signingKey: refreshed.key)
            }
        } catch {
            presentedError = Self.message(for: error)
        }
    }

    func signalingRequest(deviceID: String, media: ControllerMediaRole) async throws -> URLRequest {
        let session = try await ensureAccessSession(forceRefresh: false)
        do {
            return try api.makeSignalingRequest(
                origin: session.profile.origin,
                deviceID: deviceID,
                media: media,
                accessToken: session.token,
                signingKey: session.key
            )
        } catch ControllerClientError.invalidToken {
            let refreshed = try await ensureAccessSession(forceRefresh: true)
            return try api.makeSignalingRequest(
                origin: refreshed.profile.origin,
                deviceID: deviceID,
                media: media,
                accessToken: refreshed.token,
                signingKey: refreshed.key
            )
        }
    }

    func resetProfile() {
        guard let relayID = profile?.relayID else { return }
        do {
            try keychain.deleteProfile(relayID: relayID)
            profiles.remove()
            accessToken = nil
            accessExpiresAt = nil
            devices = []
            profile = nil
        } catch {
            presentedError = Self.message(for: error)
        }
    }

    private func ensureAccessSession(forceRefresh: Bool) async throws -> AccessSession {
        guard let profile else { throw ControllerClientError.corruptCredential }
        let key = try keychain.loadOrCreateSigningKey(relayID: profile.relayID)
        let minimumLifetime = Int64(Date().timeIntervalSince1970) + 30
        if !forceRefresh, let accessToken, let accessExpiresAt, accessExpiresAt > minimumLifetime {
            return AccessSession(profile: profile, token: accessToken, key: key)
        }
        guard let credential = try keychain.loadCredential(relayID: profile.relayID) else {
            throw ControllerClientError.corruptCredential
        }
        let tokens = try await api.refresh(
            origin: profile.origin,
            refreshToken: credential.refreshToken,
            signingKey: key
        )
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

    private func loadDevices(accessToken: String, signingKey: ControllerSigningKey) async throws {
        guard let profile else { throw ControllerClientError.corruptCredential }
        devices = try await api.devices(
            origin: profile.origin,
            accessToken: accessToken,
            signingKey: signingKey
        )
    }

    private static func message(for error: Error) -> String {
        switch error {
        case ControllerClientError.expiredPairing:
            "The pairing code expired. Create a new one in relay admin."
        case ControllerClientError.incompatibleProtocol:
            "This controller and relay use incompatible protocol versions."
        case ControllerClientError.insecureRelayOrigin:
            "Pairing requires an HTTPS relay."
        case ControllerClientError.invalidPairing:
            "The pairing code is invalid."
        case let ControllerClientError.http(status, code):
            "Relay request failed (\(status), \(code))."
        case ControllerClientError.corruptCredential:
            "The local controller credential is missing or damaged. Reset this profile and pair again."
        default:
            "The request could not be completed."
        }
    }

    private struct AccessSession {
        let profile: ProbeProfile
        let token: String
        let key: ControllerSigningKey
    }
}
