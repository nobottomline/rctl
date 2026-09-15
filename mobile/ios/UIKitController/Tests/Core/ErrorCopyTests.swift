import Foundation
import RctlClient
import XCTest
@testable import RctlUIKit

/// User-facing copy for relay, pairing and transport failures. The dialog
/// must say what happened and what to do next, never a generic "request
/// failed", and never echo payloads or credentials.
@MainActor
final class ErrorCopyTests: XCTestCase {
    private let invalidCode = "This isn't a valid pairing code. Create a new one in relay admin."
    private let unreachable = "Can't reach the relay. Check your connection and try again."
    private let timeout = "The relay didn't respond in time. Try again."

    func testUndecodablePairingPayloadIsAnInvalidCode() throws {
        let decodingError = try XCTUnwrap(decodeError(#"{"pairing_id":"demo","relay_id":"demo"}"#))
        XCTAssertEqual(ControllerAppModel.message(for: decodingError), invalidCode)
        let garbage = try XCTUnwrap(decodeError("not json at all"))
        XCTAssertEqual(ControllerAppModel.message(for: garbage), invalidCode)
        XCTAssertEqual(ControllerAppModel.message(for: ControllerClientError.invalidPairing), invalidCode)
        XCTAssertEqual(ControllerAppModel.message(for: ControllerClientError.invalidRelayOrigin), invalidCode)
    }

    func testMalformedClaimPresentsInvalidCodeWithoutTouchingTheNetwork() async {
        let model = makeIsolatedControllerAppModel()
        let paired = await model.pair(using: #"{"pairing_id":"demo","relay_id":"demo"}"#)
        XCTAssertFalse(paired)
        XCTAssertEqual(model.presentedError, invalidCode)
        XCTAssertFalse(model.isBusy)
    }

    func testConnectivityFailuresExplainTheRelayIsUnreachable() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff,
        ]
        for code in codes {
            XCTAssertEqual(ControllerAppModel.message(for: URLError(code)), unreachable, "\(code)")
        }
        // Bridged NSErrors from URLSession delegates map the same way.
        let bridged = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        XCTAssertEqual(ControllerAppModel.message(for: bridged), unreachable)
    }

    func testTimeoutsAskToRetry() {
        XCTAssertEqual(ControllerAppModel.message(for: URLError(.timedOut)), timeout)
    }

    func testTLSFailuresPointAtTheCertificate() {
        let message = ControllerAppModel.message(for: URLError(.serverCertificateUntrusted))
        XCTAssertTrue(message.contains("secure connection"), message)
    }

    func testSpecificMessagesAreKept() {
        XCTAssertEqual(ControllerAppModel.message(for: ControllerClientError.expiredPairing),
                       "The pairing code expired. Create a new one in relay admin.")
        XCTAssertEqual(ControllerAppModel.message(for: ControllerClientError.insecureRelayOrigin),
                       "Pairing requires an HTTPS relay.")
        XCTAssertEqual(ControllerAppModel.message(for: ControllerClientError.incompatibleProtocol(local: 1, remote: 2)),
                       "This controller and relay use incompatible protocol versions.")
        XCTAssertEqual(ControllerAppModel.message(for: ControllerClientError.relayIdentityMismatch),
                       "The relay identity does not match this pairing code. Create a new code on the intended relay.")
        XCTAssertEqual(ControllerAppModel.message(for: ControllerClientError.http(status: 401, code: "relay_identity_mismatch")),
                       "The relay identity does not match this pairing code. Create a new code on the intended relay.")
        XCTAssertEqual(ControllerAppModel.message(for: ControllerClientError.http(status: 503, code: "unavailable")),
                       "Relay request failed (503, unavailable).")
        XCTAssertEqual(ControllerAppModel.message(for: ControllerClientError.corruptCredential),
                       "The local controller credential is missing or damaged. Reset this profile and pair again.")
        XCTAssertEqual(ControllerAppModel.message(for: ControllerProfileStoreError.duplicateIdentity),
                       "This relay identity conflicts with a saved profile. Existing credentials were not replaced.")
        XCTAssertTrue(ControllerAppModel.message(for: ControllerClientError.unsupportedPairingVersion(2)).contains("Update the app"))
    }

    func testUnknownErrorsNeverEchoTheirDetails() {
        let secret = "crt_secret.value"
        let error = NSError(domain: "rctl.test", code: 7, userInfo: [NSLocalizedDescriptionKey: secret])
        let message = ControllerAppModel.message(for: error)
        XCTAssertFalse(message.contains(secret))
        XCTAssertEqual(message, "The request could not be completed.")
    }

    private func decodeError(_ payload: String) -> Error? {
        do {
            _ = try ControllerAPIClient().decodePairing(from: Data(payload.utf8))
            return nil
        } catch {
            return error
        }
    }
}
