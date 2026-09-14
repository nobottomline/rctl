import Foundation

extension Task where Success == Never, Failure == Never {
    /// iOS 13-compatible replacement for `Task.sleep(for:)`. Throws
    /// `CancellationError` when the surrounding task is cancelled.
    static func sleep(seconds: TimeInterval) async throws {
        let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
