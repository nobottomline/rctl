import UIKit

/// Relay pairing introduction: what to do in relay admin, then Scan QR code
/// (a further push) or Paste pairing code (claims in place). Success pops to
/// Devices through the router; claim errors are presented by the app.
@MainActor
final class PairingViewController: RCViewController, AppRoutable, UIScrollViewDelegate {
    let route: AppRoute = .pairRelay
    private let environment: AppEnvironment

    private let ambient = RCAmbientBackgroundView()
    private let scrollView = UIScrollView()
    private let topBar = RCTopBar()
    private let emblem = PairingEmblemView()
    private let titleLabel = RCLabel("Pair with your relay", style: .display, lines: 0, alignment: .center)
    private let subtitleLabel = RCLabel(
        "Link this phone to the relay that manages your devices. It takes a few seconds and is done once.",
        style: .body,
        color: RCColor.textSecondary,
        lines: 0,
        alignment: .center
    )
    private let stepsCard = RCSurfaceView(style: .card, cornerRadius: RCRadius.lg)
    private let steps = PairingStepsView()
    private let scanButton = RCButton(title: "Scan QR code", icon: .scanQrCode, variant: .accent, size: .large)
    private let pasteButton = RCButton(title: "Paste pairing code", icon: .clipboardPaste, variant: .secondary, size: .large)

    private lazy var renderer = RenderScheduler { [weak self] in self?.render() }
    /// A claim started from this screen (paste) is running.
    private var pairTask: Task<Void, Never>?
    private var progress: RCProgressHandle?
    private var isVisible = false

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(chrome: .adaptive)
    }

    override var allowsInteractivePop: Bool { pairTask == nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        ambient.intensity = 0.7
        view.addSubview(ambient)

        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)

        titleLabel.accessibilityTraits = .header
        stepsCard.contentInsets = UIEdgeInsets(top: RCSpace.xl, left: RCSpace.xl, bottom: RCSpace.xl, right: RCSpace.xl)
        stepsCard.contentView.addSubview(steps)
        steps.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        for subview in [emblem, titleLabel, subtitleLabel, stepsCard, scanButton, pasteButton] as [UIView] {
            scrollView.addSubview(subview)
        }

        scanButton.accessibilityIdentifier = "scan-pairing-code"
        scanButton.onTap = { [weak self] in self?.environment.router.push(.scanPairingCode) }
        pasteButton.accessibilityIdentifier = "paste-pairing-code"
        pasteButton.haptic = nil
        pasteButton.onTap = { [weak self] in self?.paste() }

        topBar.title = "Pair with relay"
        topBar.showsBackButton = true
        topBar.onBack = { [weak self] in self?.environment.router.pop() }
        view.addSubview(topBar)

        renderer.observe(environment.appModel.$isBusy)
        renderer.renderNow()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        // The backdrop stays still during push/pop transitions.
        ambient.isPaused = false
        emblem.playIntroIfNeeded()
        renderer.renderNow()
#if DEBUG
        runDebugActionIfNeeded()
#endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        ambient.isPaused = true
        // Leaving (e.g. the router popping to Devices after a claim) must never strand the progress card.
        dismissProgress(animated: animated)
    }

    // MARK: - Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        ambient.frame = bounds
        scrollView.frame = bounds
        let barHeight = topBar.preferredHeight(safeAreaTop: safe.top)
        topBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)

        let column = RCLayout.columnInset(width: bounds.width, safeArea: safe, maxWidth: RCLayout.maxFormWidth)
        let x = column.left
        let width = max(0, bounds.width - column.left - column.right)
        let fit = CGSize(width: width, height: .greatestFiniteMagnitude)
        let titleHeight = ceil(titleLabel.sizeThatFits(fit).height)
        let subtitleWidth = min(width, 440)
        let subtitleHeight = ceil(subtitleLabel.sizeThatFits(CGSize(width: subtitleWidth, height: .greatestFiniteMagnitude)).height)
        let stepsHeight = ceil(stepsCard.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let buttonHeight = RCButton.Size.large.height
        let actionsHeight = buttonHeight * 2 + RCSpace.md

        // Short phones get a smaller hero so the steps stay above the fold.
        let isShort = bounds.height < 700
        let emblemSide = isShort ? PairingEmblemView.compactSide : PairingEmblemView.side
        let emblemGap = isShort ? RCSpace.xl : RCSpace.xxl + RCSpace.xs
        let sectionGap = isShort ? RCSpace.xxl : RCSpace.xxxl
        let heroHeight = emblemSide + emblemGap + titleHeight + RCSpace.sm + subtitleHeight
        let contentHeight = heroHeight + sectionGap + stepsHeight
        let bottomPadding = max(safe.bottom, RCSpace.lg) + RCSpace.lg
        let top = barHeight + RCSpace.sm
        let available = bounds.height - top - bottomPadding
        let fits = contentHeight + sectionGap + actionsHeight <= available
        let isPhone = traitCollection.horizontalSizeClass == .compact

        // Regular width: center the whole block. Phones keep content at the top
        // and pin the actions to the bottom when everything fits.
        var y = top
        if fits, !isPhone {
            y += floor((available - contentHeight - sectionGap - actionsHeight) * 0.42)
        }
        emblem.frame = CGRect(x: floor(bounds.midX - emblemSide / 2), y: y, width: emblemSide, height: emblemSide)
        y += emblemSide + emblemGap
        titleLabel.frame = CGRect(x: x, y: y, width: width, height: titleHeight)
        y += titleHeight + RCSpace.sm
        subtitleLabel.frame = CGRect(x: floor(bounds.midX - subtitleWidth / 2), y: y, width: subtitleWidth, height: subtitleHeight)
        y += subtitleHeight + sectionGap
        stepsCard.frame = CGRect(x: x, y: y, width: width, height: stepsHeight)
        y += stepsHeight + sectionGap

        let actionsY: CGFloat
        let contentSizeHeight: CGFloat
        if fits, isPhone {
            actionsY = bounds.height - bottomPadding - actionsHeight
            contentSizeHeight = bounds.height
        } else {
            actionsY = y
            contentSizeHeight = y + actionsHeight + bottomPadding
        }
        scanButton.frame = CGRect(x: x, y: actionsY, width: width, height: buttonHeight)
        pasteButton.frame = CGRect(x: x, y: actionsY + buttonHeight + RCSpace.md, width: width, height: buttonHeight)
        scrollView.contentSize = CGSize(width: bounds.width, height: contentSizeHeight)
        updateTopBar()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateTopBar()
    }

    /// The small title fades in as the large title passes under the bar.
    private func updateTopBar() {
        topBar.setScrollProgress(RCLargeTitleView.collapseProgress(
            titleTop: titleLabel.frame.minY - scrollView.contentOffset.y,
            titleHeight: titleLabel.frame.height,
            barBottom: topBar.bounds.height
        ))
    }

    // MARK: - State

    private func render() {
        guard isViewLoaded else { return }
        let busy = environment.appModel.isBusy
        let pairing = pairTask != nil
        scanButton.isEnabled = !busy && !pairing
        pasteButton.isEnabled = !busy && !pairing

        let backVisible = !pairing
        if topBar.backButton.isEnabled != backVisible {
            topBar.backButton.isEnabled = backVisible
            topBar.backButton.accessibilityElementsHidden = !backVisible
            RCMotion.animate(duration: RCMotion.quickDuration) {
                self.topBar.backButton.alpha = backVisible ? 1 : 0
            }
        }

        if pairing, isVisible, progress == nil {
            progress = RCDialog.presentProgress(
                title: "Pairing with relay",
                message: "Creating your controller key and claiming the code.",
                from: self
            )
        } else if !pairing {
            dismissProgress(animated: true)
        }
    }

    private func paste() {
        guard pairTask == nil, !environment.appModel.isBusy else { return }
        guard let code = PairingClipboard.takePairingCode(presentingIn: view.window) else { return }
        RCHaptics.play(.light)
        claim(code)
    }

    private func claim(_ code: String) {
        let model = environment.appModel
        pairTask = Task { @MainActor [weak self] in
            await model.pair(using: code)
            guard let self else { return }
            // Release the card before the app's error dialog, which queues behind it.
            self.dismissProgress(animated: true)
            self.pairTask = nil
            self.renderer.setNeedsRender()
        }
        renderer.renderNow()
    }

    private func dismissProgress(animated: Bool) {
        guard let progress else { return }
        self.progress = nil
        progress.dismiss(animated: animated)
    }

#if DEBUG
    private var debugActionDone = false

    /// `--rctl-pairing-action=paste` taps Paste once after the screen appears
    /// (empty-clipboard toast); `=claim-invalid` claims a malformed code
    /// without touching the clipboard or the network (progress card, then the
    /// app's error dialog).
    private func runDebugActionIfNeeded() {
        guard !debugActionDone, let action = DebugLaunch.argument("rctl-pairing-action") else { return }
        debugActionDone = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                switch action {
                case "paste": self?.paste()
                case "claim-invalid": self?.claim(#"{"pairing_id":"demo","relay_id":"demo"}"#)
                default: break
                }
            }
        }
    }
#endif
}
