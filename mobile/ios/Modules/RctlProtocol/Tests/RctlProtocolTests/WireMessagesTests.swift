import Foundation
import Testing
@testable import RctlProtocol

@Suite("Wire message contracts")
struct WireMessagesTests {
    @Test("Control fixtures validate and preserve future fields")
    func controlFixtures() throws {
        let touch = try decode(ControlMessage.self, "control/touch.json")
        let future = try decode(ControlMessage.self, "control/future-field.json")
        let keyTap = try decode(ControlMessage.self, "control/key-tap.json")

        #expect(touch == .touch(phase: 1, finger: 2, x: 0.125, y: 0.875))
        #expect(future == .touch(phase: 1, finger: 2, x: 0.25, y: 0.75))
        #expect(keyTap == .keyTap(page: 7, usage: 40))
        #expect(throws: (any Error).self) {
            try decode(ControlMessage.self, "control/invalid-touch-range.json")
        }
        #expect(throws: (any Error).self) {
            try decode(ControlMessage.self, "control/invalid-kind.json")
        }
    }

    @Test("Signaling fixtures reject unknown kinds and nullable mids")
    func signalingFixtures() throws {
        let ready = try decode(SignalingMessage.self, "signaling/ready.json")
        let offer = try decode(SignalingMessage.self, "signaling/offer.json")
        let answer = try decode(SignalingMessage.self, "signaling/answer.json")
        let candidate = try decode(SignalingMessage.self, "signaling/candidate.json")

        guard case let .ready(servers) = ready else {
            Issue.record("expected ready")
            return
        }
        #expect(servers.count == 2)
        #expect(servers[0].urls == ["stun:stun.example.test:3478"])
        guard case let .offer(sdp) = offer else {
            Issue.record("expected offer")
            return
        }
        #expect(sdp.hasPrefix("v=0"))
        guard case let .answer(answerSDP) = answer else {
            Issue.record("expected answer")
            return
        }
        #expect(answerSDP.contains("rctl-answer"))
        guard case let .candidate(value, mid) = candidate else {
            Issue.record("expected candidate")
            return
        }
        #expect(!value.isEmpty)
        #expect(mid == "0")

        #expect(throws: (any Error).self) {
            try decode(SignalingMessage.self, "signaling/invalid-kind.json")
        }
        #expect(throws: (any Error).self) {
            try decode(SignalingMessage.self, "signaling/candidate-null-mid.json")
        }
    }

    @Test("File fixtures cover both transfer directions")
    func fileFixtures() throws {
        #expect(try decode(FileControlMessage.self, "files/get.json") ==
            .get(path: "/var/mobile/Media/example.jpg"))
        #expect(try decode(FileControlMessage.self, "files/future-field.json") ==
            .get(path: "/var/mobile/Media/example.mov"))
        #expect(try decode(FileControlMessage.self, "files/put.json") ==
            .put(path: "/var/mobile/Documents/example.bin", size: 65_536))
        #expect(try decode(FileControlMessage.self, "files/get-meta.json") ==
            .getMeta(name: "example.jpg", size: 123_456))
        #expect(try decode(FileControlMessage.self, "files/get-eof.json") ==
            .getEOF(cancelled: false))
        #expect(try decode(FileControlMessage.self, "files/put-eof.json") == .putEOF)
        #expect(try decode(FileControlMessage.self, "files/cancel.json") == .cancel)
        #expect(try decode(FileControlMessage.self, "files/put-ok.json") ==
            .putOK(bytes: 65_536))
        #expect(try decode(FileControlMessage.self, "files/error.json") ==
            .remoteError(message: "transfer cancelled"))
        #expect(throws: (any Error).self) {
            try decode(FileControlMessage.self, "files/invalid-empty-path.json")
        }
    }

    @Test("Encoding enforces semantic and byte limits")
    func encodingLimits() throws {
        let encoded = try WireJSON.encode(
            ControlMessage.key(page: 7, usage: 40, down: true)
        )
        #expect(try WireJSON.decode(ControlMessage.self, from: encoded) ==
            .key(page: 7, usage: 40, down: true))
        let tap = try WireJSON.encode(ControlMessage.keyTap(page: 7, usage: 40))
        #expect(try WireJSON.decode(ControlMessage.self, from: tap) ==
            .keyTap(page: 7, usage: 40))

        #expect(throws: WireValidationError.invalidField("touch.coordinates")) {
            try WireJSON.encode(ControlMessage.touch(phase: 0, finger: 0, x: .infinity, y: 0))
        }
        let oversized = Data(repeating: 0x20, count: WireLimits.controlJSONBytes + 1)
        #expect(throws: WireValidationError.messageTooLarge(
            actual: oversized.count,
            maximum: WireLimits.controlJSONBytes
        )) {
            try WireJSON.decode(ControlMessage.self, from: oversized)
        }
    }

    @Test("ASCII text maps to the device HID contract")
    func hidKeyboardMapping() throws {
        #expect(try HIDKeyboard.strokes(for: "aA1! \n") == [
            HIDKeyStroke(usage: 0x04),
            HIDKeyStroke(usage: 0x04, requiresShift: true),
            HIDKeyStroke(usage: 0x1e),
            HIDKeyStroke(usage: 0x1e, requiresShift: true),
            HIDKeyStroke(usage: 0x2c),
            HIDKeyStroke(usage: 0x28),
        ])
        #expect(throws: HIDKeyboardMappingError.unsupportedCharacter("Ж")) {
            try HIDKeyboard.strokes(for: "hello Ж")
        }
        #expect(throws: HIDKeyboardMappingError.tooLong(maximumCharacters: 4)) {
            try HIDKeyboard.strokes(for: "12345", maximumCharacters: 4)
        }
    }

    private func decode<Message: ValidatedWireMessage>(
        _ type: Message.Type,
        _ path: String
    ) throws -> Message {
        try WireJSON.decode(type, from: Data(contentsOf: try fixtureURL(path)))
    }

    private func fixtureURL(_ path: String) throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory
                .appendingPathComponent("protocol/fixtures", isDirectory: true)
                .appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw FixtureError.notFound(path)
    }

    private enum FixtureError: Error {
        case notFound(String)
    }
}
