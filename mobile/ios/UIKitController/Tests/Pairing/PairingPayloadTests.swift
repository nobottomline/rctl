import XCTest
@testable import RctlUIKit

final class PairingPayloadTests: XCTestCase {
    private let valid = #"{"v":1,"origin":"https://relay.example","pairing_id":"pair_1","secret":"s","expires_at":0,"protocol_major":1,"relay_id":"r"}"#

    func testAcceptsPairingShapedJSON() {
        XCTAssertTrue(PairingPayload.looksLikePairingCode(valid))
    }

    func testAcceptsSurroundingWhitespace() {
        XCTAssertTrue(PairingPayload.looksLikePairingCode("\n  \(valid) \t\n"))
    }

    func testRejectsUnrelatedCodes() {
        XCTAssertFalse(PairingPayload.looksLikePairingCode("https://example.com/menu"))
        XCTAssertFalse(PairingPayload.looksLikePairingCode("WIFI:S:home;T:WPA;P:secret;;"))
        XCTAssertFalse(PairingPayload.looksLikePairingCode(""))
    }

    func testRequiresBothIdentifiers() {
        XCTAssertFalse(PairingPayload.looksLikePairingCode(#"{"pairing_id":"p"}"#))
        XCTAssertFalse(PairingPayload.looksLikePairingCode(#"{"relay_id":"r"}"#))
    }

    func testRequiresObjectDelimiters() {
        XCTAssertFalse(PairingPayload.looksLikePairingCode(#"pairing_id relay_id"#))
        XCTAssertFalse(PairingPayload.looksLikePairingCode(#"["pairing_id","relay_id"]"#))
        XCTAssertFalse(PairingPayload.looksLikePairingCode(#"{"pairing_id":"p","relay_id":"r""#))
    }

    func testRejectsOversizedPayloads() {
        let filler = String(repeating: "a", count: PairingPayload.maximumByteCount)
        let oversized = #"{"pairing_id":"p","relay_id":"r","pad":"\#(filler)"}"#
        XCTAssertFalse(PairingPayload.looksLikePairingCode(oversized))

        let base = #"{"pairing_id":"p","relay_id":"r","pad":""}"#
        let exact = #"{"pairing_id":"p","relay_id":"r","pad":"\#(String(repeating: "a", count: PairingPayload.maximumByteCount - base.utf8.count))"}"#
        XCTAssertEqual(exact.utf8.count, PairingPayload.maximumByteCount)
        XCTAssertTrue(PairingPayload.looksLikePairingCode(exact))
    }

    func testSizeLimitCountsBytesNotCharacters() {
        // 1500 three-byte characters = 4500 bytes, over the limit despite few characters.
        let wide = #"{"pairing_id":"p","relay_id":"r","pad":"\#(String(repeating: "€", count: 1500))"}"#
        XCTAssertFalse(PairingPayload.looksLikePairingCode(wide))
    }

    func testPastedCodeIsTrimmedAndEmptyIsNil() {
        XCTAssertEqual(PairingPayload.pastedCode(from: "  code\n"), "code")
        XCTAssertNil(PairingPayload.pastedCode(from: " \n\t "))
        XCTAssertNil(PairingPayload.pastedCode(from: nil))
    }
}
