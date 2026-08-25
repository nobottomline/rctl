import Foundation
import Testing
@testable import RctlRealtime

@Suite("Realtime integration", .serialized)
struct RealtimeIntegrationTests {
    @Test("Negotiates a real signaling endpoint when explicitly configured")
    @MainActor
    func configuredEndpoint() async throws {
        guard let value = ProcessInfo.processInfo.environment["RCTL_SIGNAL_URL"],
              let url = URL(string: value) else {
            return
        }

        let (events, eventContinuation) = AsyncStream<RctlRealtimeEvent>.makeStream()
        let session = RctlRealtimeSession { event in
            eventContinuation.yield(event)
        }
        defer {
            session.stop()
            eventContinuation.finish()
        }

        try session.start(with: URLRequest(url: url))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in events {
                    switch event {
                    case .connection(.connected):
                        return
                    case let .failure(error):
                        throw error
                    default:
                        break
                    }
                }
                throw RctlRealtimeError.signalingClosed
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw RctlRealtimeError.negotiationFailed("integration test timed out")
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}
