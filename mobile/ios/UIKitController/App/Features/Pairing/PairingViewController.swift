import UIKit

/// Relay pairing introduction: what to do in relay admin, then Scan QR code
/// (a further push) or Paste pairing code (claims in place). Success pops to
/// Devices through the router; claim errors are presented by the app.
///
/// Short containers (iPhone SE, landscape phones, small Stage Manager
/// windows) pin both actions in a bottom bar so they are always reachable;
/// taller ones keep them inline with the content.
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
    private let actionBar = PairingActionBar()
    /// Containers shorter than this pin the actions in `actionBar`.
    static let actionBarMaximumHeight: CGFloat = 700

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
        actionBar.isHidden = true
        view.addSubview(actionBar)

        scanButton.accessibilityIdentifier = "scan-pairing-code"
        scanButton.onTap = { [weak self] in self?.environment.router.push(.scanPairingCode) }
        pasteButton.accessibilityIdentifier = "paste-pairing-code"
        pasteButton.haptic = nil
        pasteButton.onTap = { [weak self] in self?.paste() }

        topBar.title = "Pair with relay"
        topBar.contentColumnWidth = RCLayout.maxFormWidth
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
        let subtitleWidth = PairingTextBalance.width(of: subtitleLabel, fitting: min(width, 440))
        let subtitleHeight = ceil(subtitleLabel.sizeThatFits(CGSize(width: subtitleWidth, height: .greatestFiniteMagnitude)).height)
        let stepsHeight = ceil(stepsCard.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        // Titles wrap at accessibility sizes, so heights come from the column width.
        let scanHeight = ceil(scanButton.sizeThatFits(fit).height)
        let pasteHeight = ceil(pasteButton.sizeThatFits(fit).height)
        let actionsHeight = scanHeight + RCSpace.md + pasteHeight

        // Short containers get a smaller hero and tighter rhythm, and keep the
        // actions in a pinned bar instead of below the fold.
        let isShort = bounds.height < Self.actionBarMaximumHeight
        let emblemSide = isShort ? PairingEmblemView.compactSide : PairingEmblemView.side
        let emblemGap = isShort ? RCSpace.lg : RCSpace.xxl + RCSpace.xs
        let sectionGap = isShort ? RCSpace.xl : RCSpace.xxxl
        let heroHeight = emblemSide + emblemGap + titleHeight + RCSpace.sm + subtitleHeight
        let contentHeight = heroHeight + sectionGap + stepsHeight
        let bottomPadding = max(safe.bottom, RCSpace.lg) + RCSpace.lg
        let top = barHeight + (isShort ? RCSpace.xs : RCSpace.sm)
        let available = bounds.height - top - bottomPadding
        let fits = contentHeight + sectionGap + actionsHeight <= available
        let isPhone = traitCollection.horizontalSizeClass == .compact
        setActionsPinned(isShort)

        // Regular width: center the whole block. Phones keep content at the top
        // and pin the actions to the bottom when everything fits.
        var y = top
        if !isShort, fits, !isPhone {
            y += floor((available - contentHeight - sectionGap - actionsHeight) * 0.42)
        }
        emblem.frame = CGRect(x: floor(bounds.midX - emblemSide / 2), y: y, width: emblemSide, height: emblemSide)
        y += emblemSide + emblemGap
        titleLabel.frame = CGRect(x: x, y: y, width: width, height: titleHeight)
        y += titleHeight + RCSpace.sm
        subtitleLabel.frame = CGRect(x: floor(bounds.midX - subtitleWidth / 2), y: y, width: subtitleWidth, height: subtitleHeight)
        y += subtitleHeight + sectionGap
        stepsCard.frame = CGRect(x: x, y: y, width: width, height: stepsHeight)
        y += stepsHeight

        if isShort {
            let layout = actionBar.layout(scan: scanButton, paste: pasteButton, width: bounds.width, column: column, safeBottom: safe.bottom)
            actionBar.frame = CGRect(x: 0, y: bounds.height - layout.height, width: bounds.width, height: layout.height)
            scanButton.frame = layout.scan
            pasteButton.frame = layout.paste
            // Content scrolls behind the opaque bar and can always clear it.
            let insets = UIEdgeInsets(top: 0, left: 0, bottom: layout.height, right: 0)
            if scrollView.contentInset != insets {
                scrollView.contentInset = insets
                scrollView.scrollIndicatorInsets = insets
            }
            scrollView.contentSize = CGSize(width: bounds.width, height: y + RCSpace.xl)
        } else {
            if scrollView.contentInset != .zero {
                scrollView.contentInset = .zero
                scrollView.scrollIndicatorInsets = .zero
            }
            y += sectionGap
            let actionsY: CGFloat
            let contentSizeHeight: CGFloat
            if fits, isPhone {
                actionsY = bounds.height - bottomPadding - actionsHeight
                contentSizeHeight = bounds.height
            } else {
                actionsY = y
                contentSizeHeight = y + actionsHeight + bottomPadding
            }
            scanButton.frame = CGRect(x: x, y: actionsY, width: width, height: scanHeight)
            pasteButton.frame = CGRect(x: x, y: actionsY + scanHeight + RCSpace.md, width: width, height: pasteHeight)
            scrollView.contentSize = CGSize(width: bounds.width, height: contentSizeHeight)
        }
        updateScrollChrome()
    }

    /// Moves the actions between the scroll content and the pinned bar.
    private func setActionsPinned(_ pinned: Bool) {
        let host: UIView = pinned ? actionBar : scrollView
        guard scanButton.superview !== host else { return }
        host.addSubview(scanButton)
        host.addSubview(pasteButton)
        actionBar.isHidden = !pinned
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateScrollChrome()
    }

    /// The small title fades in as the large title passes under the bar; the
    /// action bar's hairline shows only while content continues beneath it.
    private func updateScrollChrome() {
        topBar.setScrollProgress(RCLargeTitleView.collapseProgress(
            titleTop: titleLabel.frame.minY - scrollView.contentOffset.y,
            titleHeight: titleLabel.frame.height,
            barBottom: topBar.bounds.height
        ))
        guard !actionBar.isHidden else { return }
        let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.contentInset.bottom
        actionBar.showsHairline = scrollView.contentSize.height - visibleBottom > 0.5
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

/// Opaque bottom bar holding the pairing actions on short containers. A top
/// hairline separates it from content scrolled beneath.
@MainActor
private final class PairingActionBar: RCView {
    struct Layout {
        let scan: CGRect
        let paste: CGRect
        let height: CGFloat
    }

    var showsHairline = true {
        didSet {
            guard showsHairline != oldValue else { return }
            let opacity: Float = showsHairline ? 1 : 0
            withoutImplicitAnimations { hairline.opacity = opacity }
        }
    }

    private let hairline = CALayer()

    override func setUp() {
        layer.addSublayer(hairline)
    }

    override func updateAppearance() {
        withoutImplicitAnimations {
            layer.backgroundColor = RCColor.background.cgColor(for: self)
            hairline.backgroundColor = RCColor.line.cgColor(for: self)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitAnimations {
            hairline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: RCLayout.hairline)
        }
    }

    /// Side by side when both titles fit at equal widths (landscape, wide
    /// windows); stacked otherwise. Frames are in the bar's coordinates.
    func layout(scan: RCButton, paste: RCButton, width: CGFloat, column: (left: CGFloat, right: CGFloat), safeBottom: CGFloat) -> Layout {
        let columnWidth = max(0, width - column.left - column.right)
        let gap = RCSpace.md
        let top = RCSpace.md
        let bottom = safeBottom > 0 ? safeBottom : RCSpace.lg
        let halfWidth = floor((columnWidth - gap) / 2)
        // Natural single-line widths decide the arrangement; heights are
        // measured at the final width because titles wrap at accessibility sizes.
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        func height(_ button: RCButton, _ buttonWidth: CGFloat) -> CGFloat {
            ceil(button.sizeThatFits(CGSize(width: buttonWidth, height: .greatestFiniteMagnitude)).height)
        }
        if max(scan.sizeThatFits(unbounded).width, paste.sizeThatFits(unbounded).width) <= halfWidth {
            // Scan keeps the trailing (primary) position; both share the row height.
            let scanWidth = columnWidth - halfWidth - gap
            let rowHeight = max(height(scan, scanWidth), height(paste, halfWidth))
            let paste = CGRect(x: column.left, y: top, width: halfWidth, height: rowHeight)
            let scan = CGRect(x: column.left + halfWidth + gap, y: top, width: scanWidth, height: rowHeight)
            return Layout(scan: scan, paste: paste, height: ceil(top + rowHeight + bottom))
        }
        let scan = CGRect(x: column.left, y: top, width: columnWidth, height: height(scan, columnWidth))
        let paste = CGRect(x: column.left, y: scan.maxY + RCSpace.sm, width: columnWidth, height: height(paste, columnWidth))
        return Layout(scan: scan, paste: paste, height: ceil(paste.maxY + bottom))
    }
}
