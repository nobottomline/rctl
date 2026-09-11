import Foundation
import RctlProtocol
import Testing
@testable import RctlRealtime

@Suite("Realtime reliability boundaries")
struct RealtimeReliabilityTests {
    @Test func freshnessUsesFrameTimeNotDelayedCallbackTime() {
        var freshness = VideoFreshness()
        #expect(freshness.health(at: 10) == .waiting)
        freshness.frame(at: 10)
        #expect(freshness.health(at: 12.99) == .flowing)
        #expect(freshness.health(at: 13) == .stalled)
        freshness.frame(at: 9)
        #expect(freshness.health(at: 13) == .stalled)
        freshness.frame(at: 13)
        #expect(freshness.health(at: 13) == .flowing)
    }

    @Test func statisticsUseDeltasAndResetAcrossStreams() {
        var accumulator = VideoStatisticsAccumulator()
        let first = VideoStatisticsSample(source: "v1", timestamp: 10, frames: 100,
            bytes: 1000, received: 10, lost: 0, rtt: 0.02, route: .turn)
        let initial = accumulator.update(first)
        #expect(initial.framesPerSecond == nil)
        #expect(initial.roundTripMilliseconds == 20)
        let next = VideoStatisticsSample(source: "v1", timestamp: 12, frames: 160,
            bytes: 5000, received: 28, lost: 2, rtt: 0.03, route: .direct)
        let result = accumulator.update(next)
        #expect(result.framesPerSecond == 30)
        #expect(result.bitsPerSecond == 16000)
        #expect(result.packetLossPercent == 10)
        #expect(result.route == .direct)
        var replacement = next
        replacement.source = "v2"
        replacement.timestamp = 13
        #expect(accumulator.update(replacement).framesPerSecond == nil)
        replacement.timestamp = 14
        replacement.frames = 0
        #expect(accumulator.update(replacement).framesPerSecond == nil)
    }

    @Test func bufferBoundsAndAtomicBatchAdmission() {
        let buffer = RealtimeControlBuffer()
        let key = ControlMessage.keyTap(page: 7, usage: 4)
        #expect(!buffer.append(key, delay: 0, keyboard: true))
        buffer.reset(open: true)
        #expect(!buffer.append(key, delay: .infinity, keyboard: true))
        #expect(!buffer.append(key, delay: 12, keyboard: true))
        for _ in 0..<RealtimeControlBuffer.maximumCount - 1 {
            #expect(buffer.append(key, delay: 1, keyboard: true, now: 10))
        }
        #expect(!buffer.append([ScheduledControlMessage(key, after: 1),
                                ScheduledControlMessage(key, after: 1)], keyboard: true, now: 10))
        #expect(buffer.takeDue(now: 10).isEmpty)
        #expect(buffer.takeDue(now: 11).count == RealtimeControlBuffer.maximumCount - 1)
        #expect(buffer.nextDeadline == nil)
    }

    @Test func cancellationInvalidatesAlreadyDrainedCommands() throws {
        let buffer = RealtimeControlBuffer()
        buffer.reset(open: true)
        #expect(buffer.append(.keyTap(page: 7, usage: 4), delay: 0, keyboard: true, now: 10))
        let entry = try #require(buffer.takeDue(now: 10).first)
        #expect(buffer.isCurrent(entry))
        buffer.cancelKeyboard()
        #expect(!buffer.isCurrent(entry))
        #expect(buffer.append(.touch(phase: 0, finger: 1, x: 0.5, y: 0.5), delay: 0, keyboard: false, now: 10))
        let touch = try #require(buffer.takeDue(now: 10).first)
        buffer.reset(open: false)
        buffer.reset(open: true)
        #expect(!buffer.isCurrent(touch))
    }

    @Test func producersCoalesceDrainWorkAndRejectOldDrainsAfterReset() throws {
        let buffer = RealtimeControlBuffer()
        let old = try #require(buffer.scheduleDrain())
        for _ in 0..<2048 { #expect(buffer.scheduleDrain() == nil) }
        buffer.reset(open: true)
        #expect(buffer.append(.keyTap(page: 7, usage: 4), delay: 0, keyboard: true, now: 10))
        let current = try #require(buffer.scheduleDrain())
        #expect(!buffer.isCurrent(old))
        #expect(buffer.isCurrent(current))
        #expect(!buffer.beginDrain(old))
        #expect(buffer.takeDue(now: 10, revision: old).isEmpty)
        #expect(buffer.scheduleDrain() == nil)
        #expect(buffer.beginDrain(current))
        #expect(buffer.takeDue(now: 10, revision: current).count == 1)
        #expect(buffer.scheduleDrain() != nil)
    }

    @Test func releaseOnlyActuallySentInputsAndUseLatestCoordinates() throws {
        var state = PressedControlState()
        state.sent(.touch(phase: 0, finger: 2, x: 0.1, y: 0.2))
        state.sent(.touch(phase: 1, finger: 2, x: 0.7, y: 0.8))
        state.sent(.key(page: 7, usage: 225, down: true))
        state.sent(.keyTap(page: 7, usage: 4))
        let keys = state.releases(keyboardOnly: true)
        #expect(keys.count == 1)
        guard case let .key(page, usage, down) = keys[0] else { Issue.record("Expected a key release"); return }
        #expect(page == 7 && usage == 225 && !down)
        let touches = state.releases()
        #expect(touches.count == 1)
        guard case let .touch(phase, finger, x, y) = touches[0] else { Issue.record("Expected a touch release"); return }
        #expect(phase == 2 && finger == 2 && x == 0.7 && y == 0.8)
        #expect(state.releases().isEmpty)
    }
}
