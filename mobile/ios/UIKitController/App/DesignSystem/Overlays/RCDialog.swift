import UIKit

/// Button of an `RCDialog`.
struct RCDialogAction {
    enum Style: Sendable {
        /// Emphasized confirming action.
        case primary
        /// Neutral secondary action.
        case secondary
        /// Destructive confirming action.
        case destructive
        /// Dismissing action; also triggered by tapping the backdrop when the dialog is dismissible.
        case cancel
    }

    var title: String
    var style: Style
    var handler: (@MainActor () -> Void)?

    init(_ title: String, style: Style = .primary, handler: (@MainActor () -> Void)? = nil) {
        self.title = title
        self.style = style
        self.handler = handler
    }
}

/// Centered modal dialog (shadcn `AlertDialog`): optional icon, title,
/// message, stacked or side-by-side actions. Spring scale+fade presentation.
///
/// Dialogs and progress cards share one FIFO queue: presenting while another
/// one is visible waits until it is gone, so no message is ever dropped.
/// Action handlers run after the dialog has finished dismissing. Tapping the
/// backdrop or the VoiceOver escape gesture triggers the `.cancel` action when
/// there is one and does nothing otherwise.
@MainActor
enum RCDialog {
    enum Tone: Sendable { case neutral, accent, danger }

    static func present(
        title: String,
        message: String? = nil,
        icon: RCIconGlyph? = nil,
        tone: Tone = .neutral,
        actions: [RCDialogAction],
        from presenter: UIViewController
    ) {
        let request = RCDialogRequest(
            content: RCDialogContent(title: title, message: message, icon: icon, tone: tone, actions: actions),
            presenter: presenter
        )
        RCModalQueue.shared.enqueue(request)
    }

    /// Blocking progress card (spinner, title, message). Dismiss with the returned handle.
    static func presentProgress(title: String, message: String? = nil, from presenter: UIViewController) -> RCProgressHandle {
        presentProgress(title: title, message: message, from: presenter, clock: RCSystemModalClock.shared)
    }

    /// Clock-injectable variant used by tests.
    static func presentProgress(title: String, message: String?, from presenter: UIViewController, clock: RCModalClock, minimumVisibleDuration: TimeInterval = RCProgressRequest.minimumVisibleDuration) -> RCProgressHandle {
        let request = RCProgressRequest(title: title, message: message, presenter: presenter, clock: clock, minimumVisibleDuration: minimumVisibleDuration)
        RCModalQueue.shared.enqueue(request)
        return RCProgressHandle(request: request)
    }
}

@MainActor
final class RCProgressHandle {
    private let request: RCProgressRequest?
    private weak var host: UIViewController?

    init(request: RCProgressRequest) {
        self.request = request
    }

    /// Wraps an arbitrary presented controller (legacy form).
    init(host: UIViewController) {
        request = nil
        self.host = host
    }

    /// Dismisses the progress card once it has been visible for its minimum
    /// time (450 ms), then runs `completion`. Safe to call at any time and more
    /// than once; a card still waiting in the queue is never shown.
    func dismiss(animated: Bool = true, completion: (@MainActor () -> Void)? = nil) {
        if let request {
            request.requestDismiss(animated: animated, completion: completion)
            return
        }
        guard let host, host.presentingViewController != nil else { completion?(); return }
        host.dismiss(animated: animated) { MainActor.assumeIsolated { completion?() } }
    }

    /// True until the card has been dismissed (or cancelled while queued).
    var isActive: Bool { request.map { $0.state != .finished } ?? (host?.presentingViewController != nil) }
}

// MARK: - Queue

/// A blocking card waiting for, or occupying, the single modal slot.
@MainActor
class RCQueuedModalRequest {
    enum State: Equatable { case queued, presenting, visible, dismissing, finished }

    private(set) weak var presenter: UIViewController?
    private(set) weak var window: UIWindow?
    /// Appearance captured when the request was made (used if the presenter is gone).
    let capturedStyle: UIUserInterfaceStyle
    fileprivate(set) var state: State = .queued
    private(set) weak var controller: UIViewController?

    init(presenter: UIViewController) {
        self.presenter = presenter
        window = presenter.viewIfLoaded?.window
        capturedStyle = RCModalSupport.inheritedInterfaceStyle(from: presenter)
    }

    var interfaceStyle: UIUserInterfaceStyle {
        presenter.map { RCModalSupport.inheritedInterfaceStyle(from: $0) } ?? capturedStyle
    }

    /// Builds the controller to present (called when the request reaches the slot).
    func makeController() -> UIViewController {
        fatalError("Subclasses build their controller")
    }

    /// The controller is on screen.
    func didPresent() {}

    /// Runs after the controller is gone (or the request never showed).
    func didFinish() {}

    fileprivate func attach(_ controller: UIViewController) {
        self.controller = controller
    }
}

@MainActor
final class RCModalQueue {
    static let shared = RCModalQueue()

    private(set) var pending: [RCQueuedModalRequest] = []
    private(set) var active: RCQueuedModalRequest?

    var isIdle: Bool { active == nil && pending.isEmpty }

    func enqueue(_ request: RCQueuedModalRequest) {
        pending.append(request)
        pump()
    }

    /// Removes a request that has not reached the slot yet; returns false if it already did.
    @discardableResult
    func cancel(_ request: RCQueuedModalRequest) -> Bool {
        guard request.state == .queued, let index = pending.firstIndex(where: { $0 === request }) else { return false }
        pending.remove(at: index)
        request.state = .finished
        request.didFinish()
        return true
    }

    /// Controller lifecycle: the presented card finished dismissing.
    func controllerDidDismiss(for request: RCQueuedModalRequest) {
        guard request.state != .finished else { return }
        request.state = .finished
        if active === request { active = nil }
        request.didFinish()
        pump()
    }

    func markDismissing(_ request: RCQueuedModalRequest) {
        if request.state == .visible || request.state == .presenting { request.state = .dismissing }
    }

    private func pump() {
        guard active == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        active = request
        request.state = .presenting
        let controller = request.makeController()
        request.attach(controller)
        RCModalSupport.present(
            controller,
            from: request.presenter,
            window: request.window,
            animated: RCModalSupport.animationsEnabled,
            isCancelled: { request.state == .finished }
        ) { [weak self] presented in
            guard let self else { return }
            if presented {
                if request.state == .presenting {
                    request.state = .visible
                    request.didPresent()
                } else if request.state == .finished, controller.presentingViewController != nil {
                    // Finished while UIKit was still presenting: take it down again.
                    controller.dismiss(animated: false)
                }
            } else {
                self.controllerDidDismiss(for: request)
            }
        }
    }
}

// MARK: - Dialog request

struct RCDialogContent {
    var title: String
    var message: String?
    var icon: RCIconGlyph?
    var tone: RCDialog.Tone
    var actions: [RCDialogAction]
}

@MainActor
final class RCDialogRequest: RCQueuedModalRequest {
    let content: RCDialogContent
    private(set) var chosenIndex: Int?

    init(content: RCDialogContent, presenter: UIViewController) {
        self.content = content
        super.init(presenter: presenter)
    }

    override func makeController() -> UIViewController {
        let controller = RCDialogViewController(content: content)
        controller.onChoose = { [weak self] index in self?.choose(index) }
        controller.onFinished = { [weak self] in
            guard let self else { return }
            RCModalQueue.shared.controllerDidDismiss(for: self)
        }
        controller.applyInterfaceStyle(interfaceStyle)
        return controller
    }

    override func didPresent() {
        if content.tone == .danger { RCHaptics.play(.warning) }
    }

    /// Records the action and dismisses; the handler runs after dismissal.
    /// Returns false when an action was already chosen or the dialog is not visible.
    @discardableResult
    func choose(_ index: Int) -> Bool {
        guard chosenIndex == nil, content.actions.indices.contains(index), state == .visible || state == .presenting else { return false }
        chosenIndex = index
        (controller as? RCDialogViewController)?.lockActions()
        RCModalQueue.shared.markDismissing(self)
        guard let controller, controller.presentingViewController != nil else {
            RCModalQueue.shared.controllerDidDismiss(for: self)
            return true
        }
        controller.dismiss(animated: RCModalSupport.animationsEnabled)
        return true
    }

    /// Index of the `.cancel` action, if any.
    var cancelIndex: Int? {
        content.actions.firstIndex { $0.style == .cancel }
    }

    override func didFinish() {
        guard let chosenIndex else { return }
        content.actions[chosenIndex].handler?()
    }
}

// MARK: - Action layout

/// Pure decision for how dialog actions are arranged (unit-tested).
enum RCDialogActionLayout {
    enum Axis: Equatable, Sendable { case horizontal, vertical }

    struct Arrangement: Equatable, Sendable {
        var axis: Axis
        /// Indices into the original actions, leading→trailing or top→bottom.
        var order: [Int]
    }

    /// Two actions sit side by side when both titles fit in half the width
    /// (dismissing/secondary leading, confirming trailing). Otherwise actions
    /// stack full width with confirming actions first and cancel last.
    static func arrangement(styles: [RCDialogAction.Style], titlesFitSideBySide: Bool) -> Arrangement {
        let indices = Array(styles.indices)
        guard styles.count > 1 else { return Arrangement(axis: .vertical, order: indices) }
        func rank(_ style: RCDialogAction.Style) -> Int {
            switch style {
            case .primary, .destructive: 0
            case .secondary: 1
            case .cancel: 2
            }
        }
        if styles.count == 2, titlesFitSideBySide {
            let order = indices.sorted { lhs, rhs in
                rank(styles[lhs]) == rank(styles[rhs]) ? lhs < rhs : rank(styles[lhs]) > rank(styles[rhs])
            }
            return Arrangement(axis: .horizontal, order: order)
        }
        let order = indices.sorted { lhs, rhs in
            rank(styles[lhs]) == rank(styles[rhs]) ? lhs < rhs : rank(styles[lhs]) < rank(styles[rhs])
        }
        return Arrangement(axis: .vertical, order: order)
    }

    static func buttonVariant(for style: RCDialogAction.Style) -> RCButton.Variant {
        switch style {
        case .primary: .primary
        case .secondary, .cancel: .secondary
        case .destructive: .destructive
        }
    }
}
