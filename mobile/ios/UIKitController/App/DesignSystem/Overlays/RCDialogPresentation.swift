import UIKit

// Presentation of centered modal cards (dialogs and progress): scrim, card
// geometry, keyboard-aware centering, spring scale+fade entrance and a quick
// fade/scale exit.

/// Base controller for centered cards presented by `RCCardPresentationController`.
@MainActor
class RCCardViewController: UIViewController {
    /// Runs once when the card has left the screen for good.
    var onFinished: (() -> Void)?
    private var didFinish = false

    let cardView = RCCardView()

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .custom
        transitioningDelegate = RCCardTransitioning.shared
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        view = cardView
        cardView.onEscape = { [weak self] in self?.handleEscape() ?? false }
    }

    func applyInterfaceStyle(_ style: UIUserInterfaceStyle) {
        if style != .unspecified { overrideUserInterfaceStyle = style }
    }

    /// Card size for the space available (already excludes margins, safe area and keyboard).
    func cardSize(fitting available: CGSize) -> CGSize {
        CGSize(width: min(340, available.width), height: min(120, available.height))
    }

    /// Element VoiceOver focuses when the card appears.
    var initialAccessibilityElement: Any? { view }

    func handleScrimTap() {}

    func handleEscape() -> Bool { false }

    final func finishIfNeeded() {
        guard !didFinish else { return }
        didFinish = true
        onFinished?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Safety net for teardown paths that skip presentation callbacks (the
        // card went away with its presenter). Keep the card alive until the
        // check runs: the queue holds it weakly, so a weak capture here would
        // let it deallocate first and leave the queue blocked forever.
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                guard self.presentingViewController == nil else { return }
                self.finishIfNeeded()
            }
        }
    }
}

/// Elevated rounded card with a hairline border and a modal shadow from an explicit path.
@MainActor
final class RCCardView: RCView {
    var onEscape: (() -> Bool)?

    override func setUp() {
        accessibilityViewIsModal = true
        layer.cornerRadius = RCRadius.xxl
        layer.cornerCurve = .continuous
    }

    override func updateAppearance() {
        layer.backgroundColor = RCColor.elevated.cgColor(for: self)
        layer.borderColor = RCColor.line.cgColor(for: self)
        layer.borderWidth = RCLayout.hairline
        let shadow = RCShadow.modal
        layer.shadowColor = RCColor.shadow.cgColor(for: self)
        layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? shadow.opacityDark : shadow.opacityLight
        layer.shadowRadius = shadow.radius
        layer.shadowOffset = shadow.offset
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        RCModalSupport.setShadowPath(UIBezierPath.continuousRoundedRect(bounds, radius: RCRadius.xxl).cgPath, on: layer)
    }

    override func accessibilityPerformEscape() -> Bool {
        onEscape?() ?? false
    }
}

@MainActor
final class RCCardTransitioning: NSObject, UIViewControllerTransitioningDelegate {
    static let shared = RCCardTransitioning()

    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        RCCardPresentationController(presentedViewController: presented, presenting: presenting)
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        RCCardTransitionAnimator(isPresenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        RCCardTransitionAnimator(isPresenting: false)
    }
}

@MainActor
final class RCCardTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    static let exitDuration: TimeInterval = 0.15
    let isPresenting: Bool

    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        isPresenting ? 0 : Self.exitDuration
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = isPresenting ? .to : .from
        guard let controller = transitionContext.viewController(forKey: key)?.presentationController as? RCCardPresentationController else {
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            return
        }
        if isPresenting {
            controller.install()
            transitionContext.completeTransition(true)
            controller.animateEntrance()
        } else {
            controller.animateExit {
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            }
        }
    }
}

@MainActor
final class RCCardPresentationController: UIPresentationController {
    static let margin: CGFloat = 20

    private let dimmingView = UIView()
    private let keyboard = RCKeyboardObserver()
    private var keyboardHeight: CGFloat = 0
    private var isInstalled = false
    private var animatesEntrance = false
    private var isExiting = false
    private var entrance: UIViewPropertyAnimator?

    private var card: RCCardViewController? { presentedViewController as? RCCardViewController }

    override init(presentedViewController: UIViewController, presenting presentingViewController: UIViewController?) {
        super.init(presentedViewController: presentedViewController, presenting: presentingViewController)
        keyboard.onChange = { [weak self] change in self?.keyboardDidChange(change) }
    }

    override var shouldRemovePresentersView: Bool { false }

    override var frameOfPresentedViewInContainerView: CGRect {
        cardFrame()
    }

    /// Centered card frame inside the container minus safe area, keyboard and margins.
    private func cardFrame() -> CGRect {
        guard let containerView else { return .zero }
        let bounds = containerView.bounds
        let safe = containerView.safeAreaInsets
        let bottomInset = max(safe.bottom, keyboardHeight)
        let region = CGRect(x: 0, y: safe.top, width: bounds.width, height: bounds.height - safe.top - bottomInset)
            .insetBy(dx: 0, dy: Self.margin)
        let available = CGSize(width: max(0, bounds.width - Self.margin * 2), height: max(0, region.height))
        let size = card?.cardSize(fitting: available) ?? CGSize(width: min(340, available.width), height: min(160, available.height))
        let x = ((bounds.width - size.width) / 2).rounded()
        let y = (region.minY + max(0, (region.height - size.height) / 2)).rounded()
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    override func presentationTransitionWillBegin() {
        super.presentationTransitionWillBegin()
        animatesEntrance = presentedViewController.transitionCoordinator?.isAnimated ?? false
        install()
    }

    func install() {
        guard !isInstalled, let containerView else { return }
        isInstalled = true
        let style = presentedViewController.overrideUserInterfaceStyle
        if style != .unspecified { containerView.overrideUserInterfaceStyle = style }
        dimmingView.backgroundColor = RCColor.scrim
        dimmingView.isAccessibilityElement = false
        dimmingView.frame = containerView.bounds
        dimmingView.alpha = animatesEntrance ? 0 : 1
        dimmingView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(scrimTapped)))
        containerView.addSubview(dimmingView)
        let view = presentedViewController.view!
        containerView.addSubview(view)
        applyFrame(cardFrame(), to: view)
        view.layoutIfNeeded()
        if animatesEntrance {
            view.alpha = 0
            if !RCMotion.reduceMotion { view.transform = CGAffineTransform(scaleX: 0.94, y: 0.94) }
        }
    }

    func animateEntrance() {
        guard animatesEntrance, let view = presentedView else { return }
        let animator: UIViewPropertyAnimator
        if RCMotion.reduceMotion {
            animator = UIViewPropertyAnimator(duration: RCMotion.reducedDuration, curve: .easeOut) {
                view.alpha = 1
                self.dimmingView.alpha = 1
            }
        } else {
            let timing = UISpringTimingParameters(dampingRatio: RCMotion.snappy.damping)
            animator = UIViewPropertyAnimator(duration: RCMotion.snappy.response, timingParameters: timing)
            animator.addAnimations {
                view.transform = .identity
                self.dimmingView.alpha = 1
            }
            // Opacity settles faster than scale so the card reads immediately.
            animator.addAnimations({ view.alpha = 1 }, delayFactor: 0)
        }
        entrance = animator
        animator.startAnimation()
        announce()
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        super.presentationTransitionDidEnd(completed)
        if !completed {
            dimmingView.removeFromSuperview()
            card?.finishIfNeeded()
        } else if !animatesEntrance {
            dimmingView.alpha = 1
            presentedView?.alpha = 1
            announce()
        }
    }

    private func announce() {
        UIAccessibility.post(notification: .screenChanged, argument: card?.initialAccessibilityElement)
    }

    override func dismissalTransitionWillBegin() {
        super.dismissalTransitionWillBegin()
        if !(presentedViewController.transitionCoordinator?.isAnimated ?? false) {
            dimmingView.alpha = 0
        }
    }

    func animateExit(completion: @escaping @MainActor () -> Void) {
        isExiting = true
        guard let view = presentedView else { completion(); return }
        if let entrance, entrance.state == .active {
            entrance.stopAnimation(false)
            entrance.finishAnimation(at: .current)
        }
        entrance = nil
        let reduce = RCMotion.reduceMotion
        let animator = UIViewPropertyAnimator(duration: RCCardTransitionAnimator.exitDuration, curve: .easeIn) {
            view.alpha = 0
            if !reduce { view.transform = CGAffineTransform(scaleX: 0.97, y: 0.97) }
            self.dimmingView.alpha = 0
        }
        animator.addCompletion { _ in MainActor.assumeIsolated { completion() } }
        animator.startAnimation()
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        super.dismissalTransitionDidEnd(completed)
        if completed {
            dimmingView.removeFromSuperview()
            // UIKit unlinks the presentation right after this callback; handlers
            // run on the next turn so they can present again immediately.
            let card = card
            DispatchQueue.main.async {
                MainActor.assumeIsolated { card?.finishIfNeeded() }
            }
        } else {
            isExiting = false
            presentedView?.alpha = 1
            presentedView?.transform = .identity
            dimmingView.alpha = 1
        }
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        guard isInstalled, let containerView, let view = presentedView else { return }
        dimmingView.frame = containerView.bounds
        applyFrame(cardFrame(), to: view)
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        containerView?.setNeedsLayout()
    }

    /// Updates geometry without disturbing an in-flight scale transform.
    private func applyFrame(_ frame: CGRect, to view: UIView) {
        let bounds = CGRect(origin: .zero, size: frame.size)
        if view.bounds != bounds { view.bounds = bounds }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if view.center != center { view.center = center }
    }

    @objc private func scrimTapped() {
        guard !isExiting else { return }
        card?.handleScrimTap()
    }

    private func keyboardDidChange(_ change: RCKeyboardObserver.Change) {
        guard isInstalled, !isExiting, let containerView, let view = presentedView else { return }
        let overlap = RCKeyboardObserver.overlap(of: change.frameInScreen, in: containerView)
        guard abs(overlap - keyboardHeight) > 0.5 else { return }
        keyboardHeight = overlap
        let frame = cardFrame()
        guard change.duration > 0, RCModalSupport.animationsEnabled else {
            applyFrame(frame, to: view)
            return
        }
        UIView.animate(withDuration: change.duration, delay: 0, options: [change.curve, .beginFromCurrentState, .allowUserInteraction]) {
            self.applyFrame(frame, to: view)
            view.layoutIfNeeded()
        }
    }
}

// MARK: - Dialog card

@MainActor
final class RCDialogViewController: RCCardViewController {
    static let maximumWidth: CGFloat = 340
    private static let padding = UIEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
    private static let iconSide: CGFloat = 44
    private static let buttonHeight: CGFloat = 44
    private static let buttonSpacing: CGFloat = 10

    let content: RCDialogContent
    var onChoose: ((Int) -> Void)?

    private let scrollView = UIScrollView()
    private let tile: RCIconTile?
    private let titleLabel = RCLabel(style: .headline, lines: 0)
    private let messageLabel = RCLabel(style: .subheadline, color: RCColor.textSecondary, lines: 0)
    private let separator = RCSeparator()
    private(set) var buttons: [RCButton] = []

    init(content: RCDialogContent) {
        self.content = content
        tile = content.icon.map { glyph in
            let tone: RCIconTile.Tone = switch content.tone {
            case .neutral: .neutral
            case .accent: .accent
            case .danger: .danger
            }
            return RCIconTile(glyph: glyph, tone: tone, side: Self.iconSide)
        }
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delaysContentTouches = false
        cardView.addSubview(scrollView)
        if let tile { scrollView.addSubview(tile) }
        titleLabel.text = content.title
        titleLabel.accessibilityTraits = .header
        scrollView.addSubview(titleLabel)
        messageLabel.text = content.message
        messageLabel.isHidden = content.message?.isEmpty ?? true
        scrollView.addSubview(messageLabel)
        separator.isHidden = true
        cardView.addSubview(separator)
        buttons = content.actions.enumerated().map { index, action in
            let button = RCButton(title: action.title, variant: RCDialogActionLayout.buttonVariant(for: action.style), size: .medium)
            button.onTap = { [weak self] in self?.onChoose?(index) }
            cardView.addSubview(button)
            return button
        }
    }

    override var initialAccessibilityElement: Any? { titleLabel }

    override func handleScrimTap() {
        if let cancel = content.actions.firstIndex(where: { $0.style == .cancel }) {
            onChoose?(cancel)
        }
    }

    override func handleEscape() -> Bool {
        guard let cancel = content.actions.firstIndex(where: { $0.style == .cancel }) else { return false }
        onChoose?(cancel)
        return true
    }

    // MARK: Layout

    private var buttonsFitSideBySide: Bool { sideBySideFits(innerWidth: currentInnerWidth) }
    private var currentInnerWidth: CGFloat { view.bounds.width - Self.padding.left - Self.padding.right }

    private func sideBySideFits(innerWidth: CGFloat) -> Bool {
        guard buttons.count == 2 else { return false }
        let half = (innerWidth - Self.buttonSpacing) / 2
        return buttons.allSatisfy { $0.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: Self.buttonHeight)).width <= half }
    }

    private func arrangement(innerWidth: CGFloat) -> RCDialogActionLayout.Arrangement {
        RCDialogActionLayout.arrangement(styles: content.actions.map(\.style), titlesFitSideBySide: sideBySideFits(innerWidth: innerWidth))
    }

    private func textHeight(innerWidth: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        if tile != nil { height += Self.iconSide + RCSpace.lg }
        height += titleLabel.sizeThatFits(CGSize(width: innerWidth, height: .greatestFiniteMagnitude)).height
        if !messageLabel.isHidden {
            height += 6 + messageLabel.sizeThatFits(CGSize(width: innerWidth, height: .greatestFiniteMagnitude)).height
        }
        return ceil(height)
    }

    private func buttonsHeight(for arrangement: RCDialogActionLayout.Arrangement) -> CGFloat {
        guard !buttons.isEmpty else { return 0 }
        if arrangement.axis == .horizontal { return Self.buttonHeight }
        return CGFloat(buttons.count) * Self.buttonHeight + CGFloat(buttons.count - 1) * Self.buttonSpacing
    }

    private var gapAboveButtons: CGFloat { buttons.isEmpty ? 0 : RCSpace.xxl }

    override func cardSize(fitting available: CGSize) -> CGSize {
        loadViewIfNeeded()
        let width = min(Self.maximumWidth, available.width)
        let inner = width - Self.padding.left - Self.padding.right
        let chrome = Self.padding.top + gapAboveButtons + buttonsHeight(for: arrangement(innerWidth: inner)) + Self.padding.bottom
        let natural = chrome + textHeight(innerWidth: inner)
        return CGSize(width: width, height: min(natural, available.height))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let inner = currentInnerWidth
        guard inner > 0 else { return }
        let layout = arrangement(innerWidth: inner)
        let buttonsBlock = buttonsHeight(for: layout)
        let buttonsTop = bounds.height - Self.padding.bottom - buttonsBlock
        let textTotal = textHeight(innerWidth: inner)
        let scrollTop = Self.padding.top
        let scrollHeight = max(0, buttonsTop - gapAboveButtons - scrollTop)
        // The scroll view spans the full card width so its indicator sits at the edge.
        scrollView.frame = CGRect(x: 0, y: scrollTop, width: bounds.width, height: scrollHeight)
        scrollView.contentSize = CGSize(width: bounds.width, height: textTotal)
        let overflows = textTotal > scrollHeight + 0.5
        scrollView.isScrollEnabled = overflows
        separator.isHidden = !overflows
        separator.frame = CGRect(x: 0, y: buttonsTop - gapAboveButtons / 2, width: bounds.width, height: RCLayout.hairline)

        var y: CGFloat = 0
        let x = Self.padding.left
        if let tile {
            tile.frame = CGRect(x: x, y: y, width: Self.iconSide, height: Self.iconSide)
            y += Self.iconSide + RCSpace.lg
        }
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
        titleLabel.frame = CGRect(x: x, y: y, width: inner, height: titleHeight)
        y += titleHeight
        if !messageLabel.isHidden {
            y += 6
            let messageHeight = messageLabel.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height
            messageLabel.frame = CGRect(x: x, y: y, width: inner, height: messageHeight)
        }

        switch layout.axis {
        case .horizontal:
            let width = (inner - Self.buttonSpacing) / 2
            for (slot, index) in layout.order.enumerated() {
                buttons[index].frame = CGRect(x: x + CGFloat(slot) * (width + Self.buttonSpacing), y: buttonsTop, width: width, height: Self.buttonHeight)
            }
        case .vertical:
            for (slot, index) in layout.order.enumerated() {
                buttons[index].frame = CGRect(x: x, y: buttonsTop + CGFloat(slot) * (Self.buttonHeight + Self.buttonSpacing), width: inner, height: Self.buttonHeight)
            }
        }
        // VoiceOver reads text first, then actions in visual order.
        cardView.accessibilityElements = [titleLabel] + (messageLabel.isHidden ? [] : [messageLabel]) + layout.order.map { buttons[$0] }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if scrollView.isScrollEnabled { scrollView.flashScrollIndicators() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory {
            presentationController?.containerView?.setNeedsLayout()
        }
    }

    /// Disables every action after the first choice (no double handlers).
    func lockActions() {
        buttons.forEach { $0.isUserInteractionEnabled = false }
    }
}
