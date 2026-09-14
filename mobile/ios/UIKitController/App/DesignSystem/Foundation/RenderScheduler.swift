import Combine
import UIKit

/// Coalesces model change notifications into at most one `render()` per main
/// run-loop turn. `ObservableObject.objectWillChange` fires *before* a value
/// is stored and often several times per mutation; rendering on the next turn
/// reads the settled state once.
///
/// Usage in a view controller:
/// ```swift
/// private lazy var renderer = RenderScheduler { [weak self] in self?.render() }
/// override func viewDidLoad() {
///     renderer.observe(environment.appModel)
///     renderer.observe(environment.localDevices.$devices)
///     renderer.renderNow()
/// }
/// ```
@MainActor
final class RenderScheduler {
    private let render: @MainActor () -> Void
    private var cancellables: Set<AnyCancellable> = []
    private var scheduled = false
    /// While suspended (e.g. the screen is off-screen), changes are remembered
    /// and rendered once on `resume()`.
    private(set) var isSuspended = false
    private var pendingWhileSuspended = false

    init(_ render: @escaping @MainActor () -> Void) {
        self.render = render
    }

    func observe<Object: ObservableObject>(_ object: Object) where Object.ObjectWillChangePublisher == ObservableObjectPublisher {
        object.objectWillChange
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.setNeedsRender() }
            }
            .store(in: &cancellables)
    }

    func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
        publisher
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.setNeedsRender() }
            }
            .store(in: &cancellables)
    }

    func setNeedsRender() {
        if isSuspended {
            pendingWhileSuspended = true
            return
        }
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.scheduled else { return }
                self.scheduled = false
                guard !self.isSuspended else {
                    self.pendingWhileSuspended = true
                    return
                }
                self.render()
            }
        }
    }

    func renderNow() {
        scheduled = false
        render()
    }

    func suspend() {
        isSuspended = true
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        if pendingWhileSuspended {
            pendingWhileSuspended = false
            renderNow()
        }
    }

    func cancelAll() {
        cancellables.removeAll()
        scheduled = false
    }
}
