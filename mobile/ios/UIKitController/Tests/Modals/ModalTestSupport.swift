import UIKit
import XCTest
@testable import RctlUIKit

/// Deterministic clock: scheduled work runs only when time is advanced.
@MainActor
final class ManualModalClock: RCModalClock {
    private(set) var now: TimeInterval = 1000
    private var scheduled: [(fireAt: TimeInterval, order: Int, work: @MainActor () -> Void)] = []
    private var counter = 0

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        counter += 1
        scheduled.append((now + max(0, delay), counter, work))
    }

    var pendingCount: Int { scheduled.count }

    func advance(by seconds: TimeInterval) {
        now += seconds
        while let next = scheduled.filter({ $0.fireAt <= now + 1e-9 }).min(by: { ($0.fireAt, $0.order) < ($1.fireAt, $1.order) }) {
            scheduled.removeAll { $0.order == next.order }
            next.work()
        }
    }
}

/// A real window in the test host's scene to present modals from.
@MainActor
final class ModalTestHost {
    let window: UIWindow
    let root = UIViewController()

    init() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        root.view.backgroundColor = .white
        window.rootViewController = root
        window.isHidden = false
        window.layoutIfNeeded()
    }

    func tearDown() async {
        await drainModals()
        if root.presentedViewController != nil {
            root.dismiss(animated: false)
            _ = await waitUntil { self.root.presentedViewController == nil }
        }
        window.isHidden = true
    }

    /// Clears the shared dialog queue so tests never leak state into each other.
    func drainModals() async {
        for _ in 0..<20 {
            guard !RCModalQueue.shared.isIdle else { return }
            if let dialog = RCModalQueue.shared.active as? RCDialogRequest, dialog.state == .visible {
                dialog.choose(dialog.cancelIndex ?? 0)
            } else if let progress = RCModalQueue.shared.active as? RCProgressRequest {
                progress.controller?.dismiss(animated: false)
            }
            _ = await waitUntil(timeout: 1) { RCModalQueue.shared.isIdle }
        }
    }
}

/// Spins the main run loop until `condition` holds or `timeout` elapses.
@MainActor
func waitUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

/// Minimal sheet content with a fixed preferred height.
@MainActor
final class FixedHeightContent: UIViewController {
    init(height: CGFloat) {
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 0, height: height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }
}
