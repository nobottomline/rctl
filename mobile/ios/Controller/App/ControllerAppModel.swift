import Combine
import Foundation
import RctlClient
import UIKit

@MainActor
final class ControllerAppModel: ObservableObject {
    @Published private(set) var profile: ControllerProfile?
    @Published private(set) var devices: [ControllerDevice] = []
    @Published private(set) var isBusy = false
    @Published var presentedError: String?

    private let api: ControllerAPIClient
    private let keychain: KeychainControllerStore
    private let profiles: ControllerProfileStore
    private let allowInsecureLoopback: Bool
    private var accessToken: String?
    private var accessExpiresAt: Int64?
    private var restored = false

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
            let pairing = try api.decodePairing(
                from: data,
                allowInsecureLoopback: allowInsecureLoopback
            )
            let key = try keychain.loadOrCreateSigningKey(relayID: pairing.relayID)
            let claim = try await api.claim(
                pairing: pairing,
                controllerName: UIDevice.current.name,
                signingKey: key,
                allowInsecureLoopback: allowInsecureLoopback
            )
            let credential = ControllerRefreshCredential(pairing: pairing, claim: claim)
            try keychain.save(credential)
            let newProfile = ControllerProfile(
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
            signingKey: key,
            allowInsecureLoopback: allowInsecureLoopback
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
            signingKey: signingKey,
            allowInsecureLoopback: allowInsecureLoopback
        )
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
                "The iPad is offline. Wait for it to reconnect and try again."
            case let .incompatibleDevice(reason):
                reason ?? "The iPad uses an incompatible protocol version."
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
