import Foundation
import Testing
@testable import RctlProtocol

@Suite("Remote state contract")
struct RemoteStateMessageTests {
    @Test("Orientation state validates")
    func validOrientation() throws {
        let data = Data(#"{"v":1,"orientation":4}"#.utf8)
        let message = try WireJSON.decode(RemoteStateMessage.self, from: data)

        #expect(message.orientation == 4)
    }

    @Test("Unknown versions and orientations fail closed", arguments: [
        #"{"v":2,"orientation":1}"#,
        #"{"v":1,"orientation":0}"#,
        #"{"v":1,"orientation":5}"#,
    ])
    func invalidState(json: String) {
        #expect(throws: WireValidationError.self) {
            try WireJSON.decode(RemoteStateMessage.self, from: Data(json.utf8))
        }
    }
}
