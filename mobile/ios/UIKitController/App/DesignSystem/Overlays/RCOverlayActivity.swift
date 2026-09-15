import Foundation

/// Tracks whether a blocking or focus-taking overlay (dialog, progress card,
/// sheet, dropdown or context menu) is on screen, so continuous decoration
/// underneath (the ambient background) can pause instead of recompositing
/// full-screen behind it. Toasts do not count.
@MainActor
enum RCOverlayActivity {
    /// Posted on the main thread whenever `isActive` flips.
    static let didChangeNotification = Notification.Name("RCOverlayActivityDidChange")

    private static var count = 0

    static var isActive: Bool { count > 0 }

    /// Marks an overlay as visible. Call `end()` on the token exactly when it
    /// leaves the screen; extra calls are ignored.
    static func begin() -> RCOverlayToken {
        count += 1
        if count == 1 { post() }
        return RCOverlayToken()
    }

    fileprivate static func end() {
        guard count > 0 else { return }
        count -= 1
        if count == 0 { post() }
    }

    private static func post() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

@MainActor
final class RCOverlayToken {
    private var ended = false

    fileprivate init() {}

    func end() {
        guard !ended else { return }
        ended = true
        RCOverlayActivity.end()
    }
}
