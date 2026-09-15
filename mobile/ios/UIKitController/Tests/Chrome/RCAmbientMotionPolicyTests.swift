import XCTest
@testable import RctlUIKit

final class RCAmbientMotionPolicyTests: XCTestCase {
    private typealias Policy = RCAmbientMotionPolicy

    /// On screen, active and untouched by anything that stops motion.
    private let visible = Policy.Inputs(
        isInWindow: true, isSceneActive: true, isPaused: false, isOverlayActive: false,
        isIdle: false, isLowPowerMode: false, thermalState: .nominal, reduceMotion: false
    )

    private func state(_ change: (inout Policy.Inputs) -> Void) -> Policy.State {
        var inputs = visible
        change(&inputs)
        return Policy.state(for: inputs)
    }

    func testRunsOnlyWhenVisibleActiveAndUnobstructed() {
        XCTAssertEqual(Policy.state(for: visible), .running)
        XCTAssertEqual(state { $0.thermalState = .fair }, .running, "fair thermal state still animates")
    }

    func testTemporaryConditionsFreezeLayerTime() {
        XCTAssertEqual(state { $0.isInWindow = false }, .frozen)
        XCTAssertEqual(state { $0.isSceneActive = false }, .frozen)
        XCTAssertEqual(state { $0.isPaused = true }, .frozen)
        XCTAssertEqual(state { $0.isOverlayActive = true }, .frozen)
        XCTAssertEqual(state { $0.isIdle = true }, .frozen)
        XCTAssertEqual(state { $0.isOverlayActive = true; $0.isIdle = true; $0.isPaused = true }, .frozen)
    }

    func testEnergyAndAccessibilityConditionsShowTheStillComposition() {
        XCTAssertEqual(state { $0.reduceMotion = true }, .still)
        XCTAssertEqual(state { $0.isLowPowerMode = true }, .still)
        XCTAssertEqual(state { $0.thermalState = .serious }, .still)
        XCTAssertEqual(state { $0.thermalState = .critical }, .still)
    }

    func testStillWinsOverEveryFreezeCondition() {
        let freezes: [(inout Policy.Inputs) -> Void] = [
            { $0.isInWindow = false }, { $0.isSceneActive = false }, { $0.isPaused = true },
            { $0.isOverlayActive = true }, { $0.isIdle = true },
        ]
        let stills: [(inout Policy.Inputs) -> Void] = [
            { $0.reduceMotion = true }, { $0.isLowPowerMode = true }, { $0.thermalState = .serious },
        ]
        for freeze in freezes {
            for still in stills {
                XCTAssertEqual(state { freeze(&$0); still(&$0) }, .still)
            }
        }
    }

    func testEveryCombinationIsDecided() {
        // Exhaustive over the boolean inputs and all thermal states.
        let thermalStates: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        for mask in 0..<(1 << 7) {
            for thermal in thermalStates {
                let bit = { (index: Int) in mask & (1 << index) != 0 }
                let inputs = Policy.Inputs(
                    isInWindow: bit(0), isSceneActive: bit(1), isPaused: bit(2), isOverlayActive: bit(3),
                    isIdle: bit(4), isLowPowerMode: bit(5), thermalState: thermal, reduceMotion: bit(6)
                )
                let expected: Policy.State
                if bit(6) || bit(5) || thermal == .serious || thermal == .critical {
                    expected = .still
                } else if bit(0), bit(1), !bit(2), !bit(3), !bit(4) {
                    expected = .running
                } else {
                    expected = .frozen
                }
                XCTAssertEqual(Policy.state(for: inputs), expected, "\(inputs)")
            }
        }
    }
}
