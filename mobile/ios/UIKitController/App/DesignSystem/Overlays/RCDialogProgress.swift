import UIKit

/// Enforces a minimum on-screen time before a transient card may leave, so a
/// fast operation never produces a flash. Pure timing logic (unit-tested).
@MainActor
final class RCMinimumDisplayGate {
    let minimum: TimeInterval
    private let clock: RCModalClock
    private(set) var shownAt: TimeInterval?
    private var pending: (@MainActor () -> Void)?
    private var isScheduled = false
    private(set) var isReleased = false

    init(minimum: TimeInterval, clock: RCModalClock) {
        self.minimum = minimum
        self.clock = clock
    }

    /// The card became visible (first call wins).
    func markShown() {
        guard shownAt == nil else { return }
        shownAt = clock.now
        if pending != nil { schedule() }
    }

    /// Runs `work` once the card has been visible for `minimum` (waits for
    /// `markShown` if it is not visible yet). Only the first request counts.
    func requestRelease(_ work: @escaping @MainActor () -> Void) {
        guard pending == nil, !isReleased else { return }
        pending = work
        if shownAt != nil { schedule() }
    }

    private func schedule() {
        guard !isScheduled, let shownAt else { return }
        isScheduled = true
        let remaining = max(0, minimum - (clock.now - shownAt))
        clock.schedule(after: remaining) { [weak self] in self?.fire() }
    }

    private func fire() {
        guard let work = pending else { return }
        pending = nil
        isReleased = true
        work()
    }
}

@MainActor
final class RCProgressRequest: RCQueuedModalRequest {
    static let minimumVisibleDuration: TimeInterval = 0.45

    let title: String
    let message: String?
    let gate: RCMinimumDisplayGate
    private var completions: [@MainActor () -> Void] = []
    private var animatesDismissal = true
    private var dismissRequested = false

    init(title: String, message: String?, presenter: UIViewController, clock: RCModalClock, minimumVisibleDuration: TimeInterval) {
        self.title = title
        self.message = message
        gate = RCMinimumDisplayGate(minimum: minimumVisibleDuration, clock: clock)
        super.init(presenter: presenter)
    }

    override func makeController() -> UIViewController {
        let controller = RCProgressViewController(title: title, message: message)
        controller.onFinished = { [weak self] in
            guard let self else { return }
            RCModalQueue.shared.controllerDidDismiss(for: self)
        }
        controller.applyInterfaceStyle(interfaceStyle)
        return controller
    }

    override func didPresent() {
        gate.markShown()
    }

    func requestDismiss(animated: Bool, completion: (@MainActor () -> Void)?) {
        if let completion { completions.append(completion) }
        if !animated { animatesDismissal = false }
        switch state {
        case .queued:
            // Never shown: leave the queue silently.
            RCModalQueue.shared.cancel(self)
        case .finished:
            flushCompletions()
        case .presenting, .visible, .dismissing:
            guard !dismissRequested else { return }
            dismissRequested = true
            gate.requestRelease { [weak self] in self?.performDismiss() }
        }
    }

    private func performDismiss() {
        guard state == .visible || state == .presenting else { return }
        RCModalQueue.shared.markDismissing(self)
        guard let controller, let presenting = controller.presentingViewController else {
            RCModalQueue.shared.controllerDidDismiss(for: self)
            return
        }
        presenting.dismiss(animated: animatesDismissal && RCModalSupport.animationsEnabled)
    }

    override func didFinish() {
        flushCompletions()
    }

    private func flushCompletions() {
        let pending = completions
        completions.removeAll()
        pending.forEach { $0() }
    }
}

/// Blocking progress card: accent spinner beside a title and optional message.
@MainActor
final class RCProgressViewController: RCCardViewController {
    private static let padding = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 24)
    private static let spinnerSide: CGFloat = 24
    private static let gap: CGFloat = 14

    private let spinner = RCSpinner(diameter: 24, lineWidth: 2.5)
    private let titleLabel = RCLabel(style: .headline, lines: 0)
    private let messageLabel = RCLabel(style: .subheadline, color: RCColor.textSecondary, lines: 0)
    private let titleText: String
    private let messageText: String?

    init(title: String, message: String?) {
        titleText = title
        messageText = message
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        spinner.tintColor = RCColor.accent
        spinner.hidesWhenStopped = false
        spinner.startAnimating()
        cardView.addSubview(spinner)
        titleLabel.text = titleText
        cardView.addSubview(titleLabel)
        messageLabel.text = messageText
        messageLabel.isHidden = messageText?.isEmpty ?? true
        cardView.addSubview(messageLabel)
        cardView.isAccessibilityElement = true
        cardView.accessibilityLabel = [titleText, messageText].compactMap { $0 }.joined(separator: ". ")
        cardView.accessibilityTraits = [.staticText, .updatesFrequently]
        cardView.accessibilityValue = "In progress"
    }

    override func cardSize(fitting available: CGSize) -> CGSize {
        loadViewIfNeeded()
        let width = min(RCDialogViewController.maximumWidth, available.width)
        let textHeight = textHeight(width: width)
        let height = Self.padding.top + max(Self.spinnerSide, textHeight) + Self.padding.bottom
        return CGSize(width: width, height: min(ceil(height), available.height))
    }

    private func textWidth(for width: CGFloat) -> CGFloat {
        width - Self.padding.left - Self.spinnerSide - Self.gap - Self.padding.right
    }

    private func textHeight(width: CGFloat) -> CGFloat {
        let inner = textWidth(for: width)
        var height = titleLabel.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
        if !messageLabel.isHidden {
            height += 2 + messageLabel.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
        }
        return height
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let inner = textWidth(for: bounds.width)
        guard inner > 0 else { return }
        let total = textHeight(width: bounds.width)
        let top = (bounds.height - total) / 2
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
        let x = Self.padding.left + Self.spinnerSide + Self.gap
        titleLabel.frame = CGRect(x: x, y: top, width: inner, height: titleHeight)
        if !messageLabel.isHidden {
            let messageHeight = messageLabel.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
            messageLabel.frame = CGRect(x: x, y: titleLabel.frame.maxY + 2, width: inner, height: messageHeight)
        }
        // Spinner aligns with the first line of the title.
        let firstLine = RCTypography.lineHeight(.headline, compatibleWith: traitCollection)
        spinner.frame = CGRect(x: Self.padding.left, y: top + (firstLine - Self.spinnerSide) / 2, width: Self.spinnerSide, height: Self.spinnerSide)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory {
            presentationController?.containerView?.setNeedsLayout()
        }
    }
}
