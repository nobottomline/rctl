import Combine
import XCTest
@testable import RctlUIKit

@MainActor
final class RenderSchedulerTests: XCTestCase {
    private final class Model: ObservableObject {
        @Published var value = 0
    }

    func testCoalescesChangesIntoOneRenderPerRunLoopTurn() async {
        let model = Model()
        var renders = 0
        let scheduler = RenderScheduler { renders += 1 }
        scheduler.observe(model)
        model.value = 1
        model.value = 2
        model.value = 3
        XCTAssertEqual(renders, 0, "Rendering must wait for the next run-loop turn")
        await Task.yield()
        let rendered = expectation(description: "render")
        DispatchQueue.main.async { rendered.fulfill() }
        await fulfillment(of: [rendered], timeout: 1)
        XCTAssertEqual(renders, 1)
    }

    func testSuspendedSchedulerRendersOnceOnResume() async {
        let model = Model()
        var renders = 0
        let scheduler = RenderScheduler { renders += 1 }
        scheduler.observe(model)
        scheduler.suspend()
        model.value = 1
        model.value = 2
        let drained = expectation(description: "drain")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertEqual(renders, 0)
        scheduler.resume()
        XCTAssertEqual(renders, 1)
    }
}
