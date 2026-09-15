import Foundation

/// Local checks on pairing codes before anything reaches the relay. The relay
/// and `ControllerAPIClient.decodePairing` remain the authority; these checks
/// only keep unrelated input from starting a claim.
enum PairingPayload {
    /// Largest scanned payload still considered a pairing code.
    static let maximumByteCount = 4096

    /// Cheap shape check so arbitrary QR codes (menus, URLs, Wi-Fi) never
    /// trigger a relay round trip.
    static func looksLikePairingCode(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.utf8.count <= maximumByteCount
            && trimmed.hasPrefix("{") && trimmed.hasSuffix("}")
            && trimmed.contains("pairing_id") && trimmed.contains("relay_id")
    }

    /// Clipboard text trimmed for a claim; nil when there is nothing to pair with.
    /// Pasted text is not shape-checked: the model explains malformed codes.
    static func pastedCode(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
