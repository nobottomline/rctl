import Foundation
import Testing
@testable import RctlClient

@Suite("Controller Keychain storage", .serialized)
struct KeychainControllerStoreTests {
    @Test("Key and refresh credential survive a store round trip")
    func roundTrip() throws {
        let namespace = "com.greatlove.rctl.tests.\(UUID().uuidString)"
        let relayID = "relay-test-\(UUID().uuidString)"
        let store = KeychainControllerStore(namespace: namespace, preferSecureEnclave: false)
        defer { try? store.deleteProfile(relayID: relayID) }

        let firstKey = try store.loadOrCreateSigningKey(relayID: relayID)
        let secondKey = try store.loadOrCreateSigningKey(relayID: relayID)
        #expect(firstKey.publicKeyFingerprint == secondKey.publicKeyFingerprint)

        let credential = ControllerRefreshCredential(
            origin: "https://relay.example",
            relayID: relayID,
            controller: PairedController(
                id: "ctl_example",
                name: "Owner phone",
                platform: "ios",
                scopes: [.screenView, .deviceControl]
            ),
            refreshToken: "crt_example.secret",
            refreshExpiresAt: 1_800_000_000
        )
        try store.save(credential)
        #expect(try store.loadCredential(relayID: relayID) == credential)

        try store.deleteProfile(relayID: relayID)
        #expect(try store.loadCredential(relayID: relayID) == nil)
        let replacementKey = try store.loadOrCreateSigningKey(relayID: relayID)
        #expect(replacementKey.publicKeyFingerprint != firstKey.publicKeyFingerprint)
    }

    @Test("A duplicate atomic add adopts the winning identity")
    func duplicateAdd() throws {
        var firstScalar = Data(repeating: 0, count: 32)
        firstScalar[31] = 1
        var winningScalar = Data(repeating: 0, count: 32)
        winningScalar[31] = 2
        let candidate = try ControllerSigningKey(softwareRawRepresentation: firstScalar)
        let winner = try ControllerSigningKey(softwareRawRepresentation: winningScalar)

        let resolved = try KeychainControllerStore.resolveNewSigningKey(
            candidate: candidate,
            insert: { false },
            readWinner: { winner.persistedRepresentation }
        )

        #expect(resolved.publicKeyFingerprint == winner.publicKeyFingerprint)
        #expect(resolved.publicKeyFingerprint != candidate.publicKeyFingerprint)
    }
}
