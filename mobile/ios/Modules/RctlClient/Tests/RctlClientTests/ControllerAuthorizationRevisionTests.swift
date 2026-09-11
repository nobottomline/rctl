import Foundation
import Testing
@testable import RctlClient

struct ControllerAuthorizationRevisionTests {
    @Test func oldSavedProfilesRemainReadable() throws {
        let old = try JSONDecoder().decode(PairedController.self, from: Data(#"{"id":"ctl_test","name":"Phone","platform":"ios","scopes":["screen.view"]}"#.utf8))
        #expect(try old.validated().authorizationRevision == nil)
    }

    @Test func revisionRoundTrip() throws {
        let value = PairedController(id: "ctl_test", name: "Phone", platform: "ios", scopes: [.screenView], authorizationRevision: 3)
        let data = try JSONEncoder().encode(value)
        #expect(String(decoding: data, as: UTF8.self).contains("authorization_revision"))
        #expect(try JSONDecoder().decode(PairedController.self, from: data).validated() == value)
    }

    @Test(arguments: [Int64(0), -1, 9_007_199_254_740_992])
    func invalidRevision(_ revision: Int64) {
        let value = PairedController(id: "ctl_test", name: "Phone", platform: "ios", scopes: [.screenView], authorizationRevision: revision)
        #expect(throws: ControllerClientError.self) { try value.validated() }
    }
}
