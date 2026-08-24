import CryptoKit
import Foundation
import Security

public struct KeychainControllerStore: Sendable {
    private let keyService: String
    private let credentialService: String
    private let preferSecureEnclave: Bool

    public init(
        namespace: String = "com.greatlove.rctl.controller",
        preferSecureEnclave: Bool = true
    ) {
        keyService = namespace + ".keys"
        credentialService = namespace + ".credentials"
        self.preferSecureEnclave = preferSecureEnclave
    }

    public func loadOrCreateSigningKey(relayID: String) throws -> ControllerSigningKey {
        let account = accountName(for: relayID)
        if let stored = try read(service: keyService, account: account) {
            return try ControllerSigningKey(persistedRepresentation: stored)
        }
        let key = try ControllerSigningKey.generate(preferSecureEnclave: preferSecureEnclave)
        return try Self.resolveNewSigningKey(
            candidate: key,
            insert: { try insert(key.persistedRepresentation, service: keyService, account: account) },
            readWinner: { try read(service: keyService, account: account) }
        )
    }

    public func deleteSigningKey(relayID: String) throws {
        try delete(service: keyService, account: accountName(for: relayID))
    }

    public func save(_ credential: ControllerRefreshCredential) throws {
        let data = try JSONEncoder().encode(credential)
        try write(data, service: credentialService, account: accountName(for: credential.relayID))
    }

    public func loadCredential(relayID: String) throws -> ControllerRefreshCredential? {
        guard let data = try read(service: credentialService, account: accountName(for: relayID)) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(ControllerRefreshCredential.self, from: data)
        } catch {
            throw ControllerClientError.corruptCredential
        }
    }

    public func deleteCredential(relayID: String) throws {
        try delete(service: credentialService, account: accountName(for: relayID))
    }

    public func deleteProfile(relayID: String) throws {
        try deleteCredential(relayID: relayID)
        try deleteSigningKey(relayID: relayID)
    }

    private func accountName(for relayID: String) -> String {
        Data(SHA256.hash(data: Data(relayID.utf8))).base64URLEncodedString
    }

    static func resolveNewSigningKey(
        candidate: ControllerSigningKey,
        insert: () throws -> Bool,
        readWinner: () throws -> Data?
    ) throws -> ControllerSigningKey {
        if try insert() { return candidate }
        // Another process or scene won the atomic add. Never replace identity
        // key material; all callers must converge on the persisted winner.
        guard let stored = try readWinner() else { throw ControllerClientError.keyUnavailable }
        return try ControllerSigningKey(persistedRepresentation: stored)
    }

    private func read(service: String, account: String) throws -> Data? {
        var result: CFTypeRef?
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ControllerClientError.keychain(operation: "read", status: status)
        }
        return data
    }

    private func write(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let attributes = writeAttributes(data)
        if try insert(data, service: service, account: account) { return }
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else {
            throw ControllerClientError.keychain(operation: "update", status: status)
        }
    }

    private func insert(_ data: Data, service: String, account: String) throws -> Bool {
        let item = baseQuery(service: service, account: account)
            .merging(writeAttributes(data)) { _, new in new }
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else {
            throw ControllerClientError.keychain(operation: "insert", status: status)
        }
        return true
    }

    private func writeAttributes(_ data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: keychainAccessibility,
        ]
    }

    private func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ControllerClientError.keychain(operation: "delete", status: status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
#if os(iOS)
        query[kSecUseDataProtectionKeychain as String] = true
#endif
        return query
    }

    private var keychainAccessibility: CFString {
#if os(iOS)
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#else
        // The macOS file Keychain rejects the device-only accessibility class;
        // production iOS builds use the non-migrating class above.
        kSecAttrAccessibleAfterFirstUnlock
#endif
    }
}
