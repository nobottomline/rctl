import CryptoKit
import Foundation
import Testing
@testable import RctlClient

@Suite("Controller pairing")
struct ControllerPairingTests {
    @Test("QR payload validates its trust boundary")
    func pairingValidation() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data("""
        {
          "v": 1,
          "origin": "https://relay.example",
          "pairing_id": "pair_abcdefghijklmnopqrstuvwxyz",
          "secret": "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
          "expires_at": 1700000300,
          "protocol_major": 1,
          "relay_id": "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"
        }
        """.utf8)
        let client = ControllerAPIClient()
        let pairing = try client.decodePairing(from: data, now: now)

        #expect(pairing.origin == "https://relay.example")
        #expect(pairing.protocolMajor == 1)
        #expect(throws: ControllerClientError.expiredPairing) {
            try client.decodePairing(from: data, now: now.addingTimeInterval(301))
        }
    }

    @Test("Production pairing refuses HTTP and origin confusion")
    func originValidation() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let client = ControllerAPIClient()
        let insecure = pairingJSON(origin: "http://127.0.0.1:8080", expiresAt: 1_700_000_300)

        #expect(throws: ControllerClientError.insecureRelayOrigin) {
            try client.decodePairing(from: insecure, now: now)
        }
        #expect(try client.decodePairing(
            from: insecure,
            now: now,
            allowInsecureLoopback: true
        ).origin == "http://127.0.0.1:8080")
        #expect(throws: ControllerClientError.invalidRelayOrigin) {
            try client.decodePairing(
                from: pairingJSON(origin: "https://user@relay.example/path?secret=x", expiresAt: 1_700_000_300),
                now: now
            )
        }
        #expect(throws: ControllerClientError.invalidPairing) {
            try client.decodePairing(
                from: pairingJSON(
                    origin: "https://relay.example",
                    pairingID: "pair_../admin",
                    expiresAt: 1_700_000_300
                ),
                now: now
            )
        }
    }

    @Test("Software P-256 key exports Go-compatible SPKI")
    func spkiEncoding() throws {
        var scalar = Data(repeating: 0, count: 32)
        scalar[31] = 1
        let key = try ControllerSigningKey(softwareRawRepresentation: scalar)
        let expected = try Data(hex: """
        3059301306072a8648ce3d020106082a8648ce3d030107034200
        046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296
        4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5
        """)

        #expect(key.publicKeySPKIDER == expected)
        #expect(key.publicKeyFingerprint == Data(SHA256.hash(data: expected)).base64URLEncodedString)

        let message = Data("rctl pairing proof".utf8)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: key.signature(for: message))
        let publicKey = try P256.Signing.PublicKey(x963Representation: expected.suffix(65))
        #expect(publicKey.isValidSignature(signature, for: SHA256.hash(data: message)))
    }

    private func pairingJSON(
        origin: String,
        pairingID: String = "pair_abcdefghijklmnopqrstuvwxyz",
        expiresAt: Int64
    ) -> Data {
        Data("""
        {
          "v": 1,
          "origin": "\(origin)",
          "pairing_id": "\(pairingID)",
          "secret": "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
          "expires_at": \(expiresAt),
          "protocol_major": 1,
          "relay_id": "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"
        }
        """.utf8)
    }
}

private extension Data {
    init(hex: String) throws {
        let compact = hex.filter { !$0.isWhitespace }
        guard compact.count.isMultiple(of: 2) else { throw HexError.invalid }
        var bytes = [UInt8]()
        bytes.reserveCapacity(compact.count / 2)
        var index = compact.startIndex
        while index < compact.endIndex {
            let end = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<end], radix: 16) else { throw HexError.invalid }
            bytes.append(byte)
            index = end
        }
        self.init(bytes)
    }

    enum HexError: Error { case invalid }
}
