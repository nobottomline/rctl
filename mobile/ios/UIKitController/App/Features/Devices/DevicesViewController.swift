import Combine
import RctlRealtime
import UIKit

/// Root screen: saved local devices, opt-in nearby discovery, and the selected
/// relay's devices.
///
/// Display values come from `DevicesViewState` (pure, unit-tested). Rendering
/// is coalesced by `RenderScheduler` and diffs into long-lived views: rows are
/// keyed by device ID or service identity, sections persist across the
/// first-run and populated layouts, and every change after the first frame
/// animates with `RCMotion.standard`.
///
/// Lifecycle mirrors the SwiftUI screen: discovery and reachability probes run
/// only while this screen is visible and the scene is active; a push pauses
/// them (and the ambient backdrop) as it starts.
@MainActor
final class DevicesViewController: RCViewController, UIScrollViewDelegate {
    private let environment: AppEnvironment
    private var appModel: ControllerAppModel { environment.appModel }
    private var localDevices: LocalDevicesModel { environment.localDevices }
#if DEBUG
    private var demo = DevicesDemoFixture.current
    private var isDemo: Bool { demo != nil }
#else
    private let isDemo = false
#endif

    // MARK: Views

    private let ambient = RCAmbientBackgroundView()
    private let scrollView = DevicesScrollView()
    private let topBar = RCTopBar()
    private lazy var pullToRefresh = RCRefreshControl(scrollView: scrollView) { [weak self] in
        await self?.refreshEverything()
    }
    private let brand = DevicesBrandView()
    private let refreshButton = RCIconButton(icon: .refreshCw, variant: .plain, accessibilityLabel: "Refresh devices")
    private let addButton = RCIconButton(icon: .plus, variant: .primary, accessibilityLabel: "Add device")
    private let moreButton = RCIconButton(icon: .ellipsis, variant: .plain, accessibilityLabel: "More options")

    private let largeTitle = RCLargeTitleView(title: "Devices")
    private let summaryView = DevicesSummaryView()
    private let localSection = DevicesSectionView(title: "Local network")
    private let nearbySection = DevicesSectionView(title: "Nearby")
    private let connectSection = DevicesSectionView(title: "Connect")
    private let relaySection = DevicesSectionView(title: "Relay")
    private let footerLabel = RCLabel(style: .caption, color: RCColor.textQuaternary, lines: 0, alignment: .center)

    private let nearbyAccessory = DevicesAccessoryStack()
    private let nearbySpinner = RCSpinner(diameter: 14, lineWidth: 1.75)
    private let searchAgainButton = RCIconButton(icon: .refreshCw, variant: .ghost, diameter: 32, iconSize: 16, accessibilityLabel: "Search again")
    private let stopSearchButton = RCIconButton(icon: .x, variant: .ghost, diameter: 32, iconSize: 16, accessibilityLabel: "Stop searching")
    private let relayOptionsButton = RCIconButton(icon: .ellipsis, variant: .plain, diameter: 32, iconSize: 16, accessibilityLabel: "Relay options")

    private lazy var addLocalRow = makeActionRow(
        title: "Add local device", detail: "Private IP address, optional port", glyph: .wifi,
        tone: .dashed, trailing: .plus, identifier: "add-local-device"
    ) { [weak self] in self?.push(.localDevice(editing: nil)) }
    private lazy var findNearbyRow = makeActionRow(
        title: "Find devices on this network", detail: "Nothing connects until you choose one", glyph: .radar,
        tone: .accent, trailing: .chevron, identifier: "find-nearby-devices"
    ) { [weak self] in self?.enableDiscovery() }
    private lazy var connectPairRow = makeActionRow(
        title: "Pair with relay", detail: "Control from anywhere, set up once", glyph: .qrCode,
        tone: .dashed, trailing: .chevron, identifier: "pair-relay"
    ) { [weak self] in self?.push(.pairRelay) }
    private lazy var connectAddressRow = makeActionRow(
        title: "Add by address", detail: "Private IP address, optional port", glyph: .wifi,
        tone: .dashed, trailing: .chevron, identifier: "add-local-device"
    ) { [weak self] in self?.push(.localDevice(editing: nil)) }
    private lazy var relayPairRow = makeActionRow(
        title: "Pair with relay", detail: "Scan a one-time code from relay admin", glyph: .qrCode,
        tone: .dashed, trailing: .plus, identifier: "pair-relay"
    ) { [weak self] in self?.push(.pairRelay) }
    private let nearbyNoticeRow = DevicesStatusRowView()
    private let relayPlaceholderRow = DevicesStatusRowView()

    /// Device rows by `DevicesRowState.id`, reused across renders.
    private var deviceRows: [String: RCListRow] = [:]
#if DEBUG
    /// Long-press menus by row ID, for the screenshot hook only (interactions retain themselves).
    private var contextMenus: [String: RCContextMenuInteraction] = [:]
#endif

    // MARK: State

    private lazy var renderer = RenderScheduler { [weak self] in self?.render() }
    private var state: DevicesViewState?
    private var snapshot = DevicesSnapshot()
    private var homeVisible = false
    private var appliedForeground: Bool?
    private var shownBlocks: [ObjectIdentifier] = []
    private var checkingNearby: LocalServiceIdentity?
    private var nearbyTask: (id: UUID, task: Task<Void, Never>)?
    private var probeTask: Task<Void, Never>?
    /// Navigation chosen in the nearby sheet, performed once it has dismissed.
    private var nearbyFollowUp: AppRoute?
    private var presentingDeletionFailure = false
    private var cancellables: Set<AnyCancellable> = []
#if DEBUG
    private var appliedDebugLaunch = false
#endif

    private static let sectionSpacing: CGFloat = 26
    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private static let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(chrome: .adaptive)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildHierarchy()
        renderer.observe(appModel)
        renderer.observe(localDevices)
        renderer.observe(environment.appearance)
        renderer.observe(environment.lifecycle)
        observeModels()
        renderer.renderNow()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        renderer.resume()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        homeVisible = true
        updateForeground()
        presentDeletionFailureIfNeeded()
#if DEBUG
        applyDebugLaunchOnce()
#endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // A push is starting: stop discovery, probes and the backdrop now,
        // not after the transition, so both screens are never live together.
        homeVisible = false
        updateForeground()
        cancelNearbySelection()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        renderer.suspend()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory {
            view.setNeedsLayout()
        }
    }

    private func observeModels() {
        environment.lifecycle.$isActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateForeground() } }
            .store(in: &cancellables)
        // `.task(id: devices)` in the SwiftUI screen: re-probe whenever the saved list changes.
        localDevices.$devices
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.startReachabilityProbe() } }
            .store(in: &cancellables)
        appModel.$relayDeletionFailure
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.presentDeletionFailureIfNeeded() } }
            .store(in: &cancellables)
    }

    /// Discovery, probes and the ambient backdrop run only while the screen
    /// is visible and the scene is active.
    private func updateForeground() {
        let foreground = homeVisible && environment.lifecycle.isActive
        ambient.isPaused = !foreground
        guard foreground != appliedForeground else { return }
        appliedForeground = foreground
        guard !isDemo else { return }
        localDevices.setForeground(foreground)
        if foreground {
            startReachabilityProbe()
        } else {
            probeTask?.cancel()
            probeTask = nil
            cancelNearbySelection()
        }
    }

    private func startReachabilityProbe() {
        probeTask?.cancel()
        probeTask = nil
        guard !isDemo, homeVisible, environment.lifecycle.isActive else { return }
        let localDevices = localDevices
        probeTask = Task { await localDevices.probeReachability() }
    }

    // MARK: - Hierarchy

    private func buildHierarchy() {
        view.addSubview(ambient)

        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        view.addSubview(scrollView)
        _ = pullToRefresh // Inserts itself into the scroll view.

        footerLabel.text = "rctl controller \(Self.appVersion)"
        [largeTitle, summaryView, localSection, nearbySection, connectSection, relaySection, footerLabel].forEach(scrollView.addSubview)
        [localSection, nearbySection, connectSection, relaySection].forEach { $0.alpha = 0 }

        topBar.title = "Devices"
        topBar.leadingViews = [brand]
        refreshButton.onTap = { [weak self] in
            guard let self else { return }
            Task { await self.refreshEverything() }
        }
        addButton.accessibilityIdentifier = "add-device-menu"
        RCMenu.attach(to: addButton, alignment: .trailing) { [weak self] in self?.addMenu() ?? [] }
        RCMenu.attach(to: moreButton, alignment: .trailing) { [weak self] in self?.moreMenu() ?? [] }
        view.addSubview(topBar)

        nearbySpinner.hidesWhenStopped = true
        nearbySpinner.isAccessibilityElement = true
        nearbySpinner.accessibilityLabel = "Searching"
        searchAgainButton.onTap = { [weak self] in self?.restartDiscovery() }
        stopSearchButton.accessibilityIdentifier = "stop-discovery"
        stopSearchButton.onTap = { [weak self] in self?.disableDiscovery() }
        nearbyAccessory.arrangedViews = [nearbySpinner, searchAgainButton, stopSearchButton]
        RCMenu.attach(to: relayOptionsButton, alignment: .trailing) { [weak self] in self?.relayMenu() ?? [] }

        for section in [localSection, nearbySection, connectSection, relaySection] {
            // Called inside the group's spring when animated, so the page reflows with the card.
            section.group.onHeightChange = { [weak self] _ in self?.groupHeightChanged() }
        }
        connectSection.footnote.style = .footnote
        connectSection.footnote.color = RCColor.textQuaternary
        relaySection.footnote.color = RCColor.textQuaternary
        relaySection.footnote.truncatesMiddle = true
    }

    private func groupHeightChanged() {
        view.setNeedsLayout()
        if UIView.inheritedAnimationDuration > 0 { view.layoutIfNeeded() }
    }

    private func makeActionRow(
        title: String, detail: String, glyph: RCIconGlyph, tone: RCIconTile.Tone,
        trailing: RCListRow.Trailing, identifier: String, action: @escaping @MainActor () -> Void
    ) -> RCListRow {
        let row = RCListRow(content: RCListRow.Content(title: title, detail: detail, glyph: glyph, tileTone: tone, trailing: trailing))
        row.accessibilityIdentifier = identifier
        row.onTap = action
        return row
    }

    private func deviceRow(for rowState: DevicesRowState, animated: Bool) -> RCListRow {
        let status = rowState.status
        let content = RCListRow.Content(
            title: rowState.title,
            detail: rowState.detail,
            detailIsMonospaced: rowState.detailIsMonospaced,
            glyph: .tabletSmartphone,
            tileTone: status.tone == .success ? .accent : .neutral,
            trailing: .badgeAndChevron(text: status.text, tone: Self.badgeTone(status.tone), busy: status.busy),
            appearsEnabled: rowState.isEnabled
        )
        let row: RCListRow
        if let existing = deviceRows[rowState.id] {
            row = existing
            if row.content != content { row.configure(content, animated: animated) }
        } else {
            row = RCListRow(content: content)
            deviceRows[rowState.id] = row
            wire(row, for: rowState)
        }
        row.accessibilityHintText = rowState.accessibilityHint
        return row
    }

    private func wire(_ row: RCListRow, for rowState: DevicesRowState) {
        let menu: RCContextMenuInteraction?
        switch rowState.kind {
        case let .local(id):
            row.onTap = { [weak self] in self?.openLocalDevice(id) }
            menu = RCContextMenuInteraction { [weak self] in self?.localDeviceMenu(id) }
        case let .nearby(identity):
            // Haptics depend on the outcome (tap vs. warning), so the row stays silent.
            row.haptic = nil
            row.onTap = { [weak self] in self?.selectNearbyRow(identity) }
            menu = RCContextMenuInteraction { [weak self] in self?.nearbyDeviceMenu(identity) }
        case let .relay(id):
            row.haptic = nil
            row.onTap = { [weak self] in self?.openRelayDevice(id) }
            menu = nil
        }
        if let menu {
            menu.attach(to: row)
#if DEBUG
            contextMenus[rowState.id] = menu
#endif
        }
    }

    private static func badgeTone(_ tone: DevicesTone) -> RCStatusBadge.Tone {
        switch tone {
        case .neutral: .neutral
        case .success: .success
        case .attention: .attention
        case .danger: .danger
        }
    }

    // MARK: - Render

    private func makeSnapshot() -> DevicesSnapshot {
#if DEBUG
        if let demo { return demo.snapshot }
#endif
        var snapshot = DevicesSnapshot()
        snapshot.localDevices = localDevices.devices
        snapshot.reachability = localDevices.reachability
        snapshot.discoveryEnabled = localDevices.discoveryEnabled
        snapshot.discoveryState = localDevices.discoveryState
        snapshot.discoverySearchSettled = localDevices.discoverySearchSettled
        snapshot.nearby = localDevices.nearby.map(DevicesSnapshot.NearbyDevice.init)
        snapshot.selectingNearby = localDevices.selectingNearby
        snapshot.checkingNearby = checkingNearby
        if let profile = appModel.profile {
            snapshot.relay = DevicesSnapshot.Relay(
                selected: profile,
                saved: appModel.savedProfiles,
                devices: appModel.devices.map(DevicesSnapshot.RelayDevice.init)
            )
        }
        snapshot.isBusy = appModel.isBusy
        return snapshot
    }

    private func render() {
        let snapshot = makeSnapshot()
        self.snapshot = snapshot
        let next = DevicesViewState(snapshot)
        guard next != state else { return }
        // No animation for the first frame or while off-screen (e.g. rendering
        // pending changes as a pop begins).
        let animated = state != nil && homeVisible && view.window != nil
        state = next
        apply(next, animated: animated)
    }

    private func apply(_ state: DevicesViewState, animated: Bool) {
        applyTopBar(state)
        summaryView.configure(text: state.summary.text, showsDot: state.summary.showsOnlineIndicator, animated: animated)
        applyLocal(state.local, animated: animated)
        applyNearby(state.nearby, animated: animated)
        applyRelay(state.relay, animated: animated)
        if connectSection.group.items.isEmpty {
            connectSection.setRows([.init(id: "connect-pair", view: connectPairRow), .init(id: "connect-address", view: connectAddressRow)], animated: false)
            connectSection.setFootnote("Local network works without an account. Relay needs a one-time pairing from relay admin.", animated: false)
        }
        pruneDeviceRows(keeping: Set(state.local.rows.map(\.id) + state.nearby.rows.map(\.id) + relayRowIDs(state.relay)))
        updateSectionVisibility(for: state.layout, animated: animated)
        guard isViewLoaded, view.bounds.width > 0 else { return }
        if animated {
            RCMotion.animate(RCMotion.standard, animations: { [weak self] in self?.layoutContent() })
        } else {
            layoutContent()
        }
    }

    private func applyTopBar(_ state: DevicesViewState) {
        let trailing: [UIView] = state.showsRefresh ? [refreshButton, addButton, moreButton] : [addButton, moreButton]
        if !topBar.trailingViews.elementsEqual(trailing, by: ===) {
            topBar.trailingViews = trailing
        }
        refreshButton.isSpinning = state.isBusy
        refreshButton.isEnabled = !state.isBusy
        refreshButton.accessibilityValue = state.isBusy ? "Refreshing" : nil
    }

    private func applyLocal(_ local: DevicesViewState.LocalSection, animated: Bool) {
        localSection.header.subtitle = local.subtitle
        let rows = local.rows.map { RCListGroupView.Item(id: $0.id, view: deviceRow(for: $0, animated: animated)) }
        localSection.setRows(rows + [.init(id: "add-local", view: addLocalRow)], animated: animated)
    }

    private func applyNearby(_ nearby: DevicesViewState.NearbySection, animated: Bool) {
        let header = nearbySection.header
        header.subtitle = nearby.subtitle
        let accessory: UIView? = nearby.isEnabled ? nearbyAccessory : nil
        if header.accessoryView !== accessory { header.accessoryView = accessory }
        if nearby.showsSpinner { nearbySpinner.startAnimating() } else { nearbySpinner.stopAnimating() }
        searchAgainButton.isEnabled = nearby.canSearchAgain
        nearbyAccessory.setNeedsLayout()
        header.setNeedsLayout()

        guard nearby.isEnabled else {
            nearbySection.setRows([.init(id: "find-nearby", view: findNearbyRow)], animated: animated)
            nearbySection.setFootnote(nil, animated: animated)
            return
        }
        var items = nearby.rows.map { RCListGroupView.Item(id: $0.id, view: deviceRow(for: $0, animated: animated)) }
        if let notice = nearby.notice {
            configureNearbyNotice(notice, animated: animated && nearbySection.group.items.contains { $0.id == "nearby-notice" })
            items.append(.init(id: "nearby-notice", view: nearbyNoticeRow))
        }
        nearbySection.setRows(items, animated: animated)
        nearbySection.setFootnote("Found devices are not verified. Use LAN control only on a network you trust.", glyph: .shieldAlert, animated: animated)
    }

    private func configureNearbyNotice(_ notice: DevicesViewState.NearbyNotice, animated: Bool) {
        let configure = { [weak self] in
            guard let self else { return }
            switch notice {
            case .permissionDenied:
                nearbyNoticeRow.configure(
                    glyph: .shieldAlert, busy: false,
                    title: "Local Network access is off",
                    message: "Allow it in Settings to find devices. Adding by address needs the same permission.",
                    actions: [
                        .init("Open Settings", prominent: true) { [weak self] in self?.openSettings() },
                        .init("Add by address") { [weak self] in self?.push(.localDevice(editing: nil)) },
                    ]
                )
            case .unavailable:
                nearbyNoticeRow.configure(
                    glyph: .wifiOff, busy: false,
                    title: "Discovery is unavailable",
                    message: "Bonjour is not working on this network right now. Try again, or add the device by address.",
                    actions: [
                        .init("Try again", prominent: true) { [weak self] in self?.restartDiscovery() },
                        .init("Add by address") { [weak self] in self?.push(.localDevice(editing: nil)) },
                    ]
                )
            case .searching:
                nearbyNoticeRow.configure(
                    glyph: nil, busy: true,
                    title: "Looking for rctl devices",
                    message: "On the network this phone is connected to"
                )
            case .empty:
                nearbyNoticeRow.configure(
                    glyph: .search, busy: false,
                    title: "No devices found",
                    message: "Make sure the device is on this network with LAN control on. Devices set to Relay only do not advertise.",
                    actions: [.init("Add by address", prominent: true) { [weak self] in self?.push(.localDevice(editing: nil)) }]
                )
            }
        }
        if animated {
            UIView.transition(with: nearbyNoticeRow, duration: RCMotion.quickDuration, options: [.transitionCrossDissolve, .allowUserInteraction], animations: configure)
        } else {
            configure()
        }
    }

    private func applyRelay(_ relay: DevicesViewState.RelaySection, animated: Bool) {
        let header = relaySection.header
        switch relay {
        case .unpaired:
            header.subtitle = nil
            if header.accessoryView != nil { header.accessoryView = nil }
            relaySection.setRows([.init(id: "relay-pair", view: relayPairRow)], animated: animated)
            relaySection.setFootnote(nil, animated: animated)
        case let .paired(paired):
            header.subtitle = paired.subtitle
            if header.accessoryView !== relayOptionsButton { header.accessoryView = relayOptionsButton }
            if paired.placeholder == .loading {
                // Skeleton rows shaped like device rows; real rows crossfade in.
                if !relaySection.group.isShowingPlaceholder {
                    relaySection.group.showPlaceholder(rows: 2, animated: animated)
                }
                relaySection.group.accessibilityLabel = "Loading devices. Talking to the relay."
            } else {
                var items = paired.rows.map { RCListGroupView.Item(id: $0.id, view: deviceRow(for: $0, animated: animated)) }
                if paired.placeholder == .empty {
                    relayPlaceholderRow.configure(glyph: .server, busy: false, title: "No approved devices",
                                                  message: "Approve devices for this controller in relay admin, then refresh.")
                    items.append(.init(id: "relay-placeholder", view: relayPlaceholderRow))
                }
                relaySection.setRows(items, animated: animated)
            }
            relaySection.setFootnote(paired.footer, glyph: .keyRound, animated: animated)
        }
        header.setNeedsLayout()
    }

    private func relayRowIDs(_ relay: DevicesViewState.RelaySection) -> [String] {
        if case let .paired(paired) = relay { return paired.rows.map(\.id) }
        return []
    }

    private func pruneDeviceRows(keeping ids: Set<String>) {
        for id in deviceRows.keys where !ids.contains(id) {
            deviceRows[id] = nil
#if DEBUG
            contextMenus[id] = nil
#endif
        }
    }

    // MARK: - Layout

    private func sections(for layout: DevicesViewState.Layout) -> [DevicesSectionView] {
        layout == .firstRun ? [nearbySection, connectSection] : [localSection, nearbySection, relaySection]
    }

    /// Switching between the first-run and populated compositions: leaving
    /// sections clear quickly, entering ones fade in a beat later at their final
    /// place, so the two never read as overlapping content. Runs outside the
    /// layout spring on purpose.
    private func updateSectionVisibility(for layout: DevicesViewState.Layout, animated: Bool) {
        let visible = sections(for: layout)
        for block in [localSection, nearbySection, connectSection, relaySection] {
            let shows = visible.contains(block)
            block.isUserInteractionEnabled = shows
            block.accessibilityElementsHidden = !shows
            let target: CGFloat = shows ? 1 : 0
            guard block.alpha != target else { continue }
            if animated {
                RCMotion.animate(duration: shows ? 0.26 : 0.12, delay: shows ? 0.1 : 0) { block.alpha = target }
            } else {
                block.alpha = target
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        ambient.frame = bounds
        scrollView.frame = bounds
        topBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: topBar.preferredHeight(safeAreaTop: view.safeAreaInsets.top))
        scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: topBar.frame.height, left: 0, bottom: view.safeAreaInsets.bottom, right: 0)
        if pullToRefresh.topOffset != topBar.frame.height { pullToRefresh.topOffset = topBar.frame.height }
        layoutContent()
    }

    /// Frame layout of the scroll content. Runs inside an animation block
    /// for state changes, so every frame (sections, groups, rows) springs.
    private func layoutContent() {
        guard let state else { return }
        let bounds = view.bounds
        let safe = view.safeAreaInsets
        let inset = RCLayout.columnInset(width: bounds.width, safeArea: safe)
        let width = max(0, bounds.width - inset.left - inset.right)
        let fit = CGSize(width: width, height: .greatestFiniteMagnitude)

        var y = topBar.preferredHeight(safeAreaTop: safe.top) + RCSpace.xs
        let titleHeight = largeTitle.sizeThatFits(fit).height
        largeTitle.frame = CGRect(x: inset.left, y: y, width: width, height: titleHeight)
        y = largeTitle.frame.maxY + RCLargeTitleView.subtitleSpacing
        let summaryHeight = summaryView.sizeThatFits(fit).height
        summaryView.frame = CGRect(x: inset.left, y: y, width: width, height: summaryHeight)
        y = summaryView.frame.maxY + RCSpace.xxl + RCSpace.xs

        let blocks = sections(for: state.layout)
        let previouslyShown = shownBlocks
        for block in blocks {
            let frame = CGRect(x: inset.left, y: y, width: width, height: block.sizeThatFits(fit).height)
            if previouslyShown.contains(ObjectIdentifier(block)) {
                block.frame = frame
                block.layoutIfNeeded()
            } else {
                // Entering sections take their place without moving; their
                // fade is driven by `updateSectionVisibility`.
                UIView.performWithoutAnimation {
                    block.frame = frame
                    block.layoutIfNeeded()
                }
            }
            y = frame.maxY + Self.sectionSpacing
        }
        shownBlocks = blocks.map(ObjectIdentifier.init)

        y += RCSpace.xs
        let footerHeight = footerLabel.sizeThatFits(fit).height
        footerLabel.frame = CGRect(x: inset.left, y: y, width: width, height: footerHeight)
        y = footerLabel.frame.maxY

        let contentHeight = ceil(y + safe.bottom + RCSpace.xxxl)
        if scrollView.contentSize != CGSize(width: bounds.width, height: contentHeight) {
            scrollView.contentSize = CGSize(width: bounds.width, height: contentHeight)
        }
        updateTopBarProgress()
    }

    // MARK: - Scrolling

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateTopBarProgress()
        pullToRefresh.scrollViewDidScroll()
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        pullToRefresh.scrollViewWillEndDragging()
    }

    /// The small title and solid bar arrive as the large title slides under the bar.
    private func updateTopBarProgress() {
        topBar.setScrollProgress(largeTitle.collapseProgress(in: scrollView, topBarHeight: topBar.bounds.height))
    }

    // MARK: - Actions

    private func push(_ route: AppRoute) {
        environment.router.push(route)
    }

    private func refreshEverything() async {
#if DEBUG
        if isDemo {
            try? await Task.sleep(nanoseconds: 900_000_000)
            return
        }
#endif
        let appModel = appModel
        let localDevices = localDevices
        localDevices.restartDiscovery()
        async let relay: Void = appModel.refreshDevices()
        async let local: Void = localDevices.probeReachability()
        _ = await (relay, local)
    }

    private func enableDiscovery() {
        guard !isDemo else { return }
        localDevices.setDiscoveryEnabled(true)
    }

    private func disableDiscovery() {
        guard !isDemo else { return }
        cancelNearbySelection()
        localDevices.setDiscoveryEnabled(false)
    }

    private func restartDiscovery() {
        guard !isDemo else { return }
        localDevices.restartDiscovery()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func presentUnavailable(_ message: String) {
        RCDialog.present(
            title: "Device unavailable",
            message: message,
            icon: .circleAlert,
            tone: .neutral,
            actions: [RCDialogAction("OK", style: .primary)],
            from: self
        )
    }

    // MARK: Local devices

    private func localDevice(_ id: UUID) -> LocalDeviceProfile? {
        (isDemo ? snapshot.localDevices : localDevices.devices).first { $0.id == id }
    }

    private func openLocalDevice(_ id: UUID) {
        guard !isDemo, let device = localDevice(id) else { return }
        push(.localControl(device))
    }

    private func localDeviceMenu(_ id: UUID) -> [RCMenuSection]? {
        guard let device = localDevice(id) else { return nil }
        return [RCMenuSection(title: device.name, items: [
            RCMenuItem("Edit", icon: .pencil) { [weak self] in
                guard let self, let device = self.localDevice(id) else { return }
                self.push(.localDevice(editing: device))
            },
            RCMenuItem("Remove", icon: .trash2, role: .destructive) { [weak self] in self?.confirmRemoval(of: id) },
        ])]
    }

    private func confirmRemoval(of id: UUID) {
        guard let device = localDevice(id) else { return }
        RCDialog.present(
            title: "Remove saved local device?",
            message: "Only the saved address is removed. The device is not changed.",
            icon: .trash2,
            tone: .danger,
            actions: [
                RCDialogAction("Cancel", style: .cancel),
                RCDialogAction("Remove", style: .destructive) { [weak self] in
                    guard let self, !self.isDemo else { return }
                    self.localDevices.remove(device)
                },
            ],
            from: self
        )
    }

    // MARK: Nearby

    private func selectNearbyRow(_ identity: LocalServiceIdentity) {
        guard let row = snapshot.nearby.first(where: { $0.id == identity }), !snapshot.selectingNearby, nearbyTask == nil else { return }
        guard row.canResolve else {
            // Explain the specific reason instead of attempting a resolve that cannot succeed.
            RCHaptics.play(.warning)
            presentUnavailable(LocalDevicesModel.message(for: row.error ?? LocalDiscoveryError.unavailable))
            return
        }
        RCHaptics.play(.light)
        guard !isDemo, let device = localDevices.nearby.first(where: { $0.id == identity }) else { return }
        selectNearby(device, replacing: nil)
    }

    private func nearbyDeviceMenu(_ identity: LocalServiceIdentity) -> [RCMenuSection]? {
        guard let row = state?.nearby.rows.first(where: { $0.kind == .nearby(identity) }), row.offersAddressReplacement else { return nil }
        let saved = isDemo ? snapshot.localDevices : localDevices.devices
        guard !saved.isEmpty else { return nil }
        let choices = saved.map { profile in
            RCMenuItem("\(profile.name) · \(profile.address.displayAddress)") { [weak self] in
                self?.replaceAddress(of: profile.id, with: identity)
            }
        }
        return [RCMenuSection(items: [
            RCMenuItem("Use address for a saved device", icon: .arrowLeftRight, children: [RCMenuSection(items: choices)]),
        ])]
    }

    private func replaceAddress(of savedID: UUID, with identity: LocalServiceIdentity) {
        guard !isDemo, nearbyTask == nil,
              let device = localDevices.nearby.first(where: { $0.id == identity }),
              let saved = localDevices.devices.first(where: { $0.id == savedID }) else { return }
        selectNearby(device, replacing: saved)
    }

    /// Re-resolves and preflights the chosen service, then routes: a replacement
    /// goes to the editor; an address already saved opens that device; anything
    /// else asks what to do in the decision sheet.
    private func selectNearby(_ device: DiscoveredLocalDevice, replacing saved: LocalDeviceProfile?) {
        guard nearbyTask == nil else { return }
        checkingNearby = device.id
        renderer.setNeedsRender()
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.nearbyTask?.id == token {
                    self.nearbyTask = nil
                    self.checkingNearby = nil
                    self.renderer.setNeedsRender()
                }
            }
            do {
                let profile = try await self.localDevices.prepareNearby(device)
                try Task.checkCancellation()
                if let saved {
                    self.push(.discoveredDevice(profile, replacing: saved))
                } else if let existing = self.localDevices.devices.first(where: { $0.address == profile.address }) {
                    RCHaptics.play(.light)
                    self.push(.localControl(existing))
                } else {
                    self.presentNearbySheet(for: profile, savedDevices: self.localDevices.devices)
                }
            } catch {
                if !Task.isCancelled {
                    RCHaptics.play(.warning)
                    self.presentUnavailable(LocalDevicesModel.message(for: error))
                }
            }
        }
        nearbyTask = (token, task)
    }

    private func cancelNearbySelection() {
        nearbyTask?.task.cancel()
        nearbyTask = nil
        if checkingNearby != nil {
            checkingNearby = nil
            renderer.setNeedsRender()
        }
    }

    private func presentNearbySheet(for profile: LocalDeviceProfile, savedDevices: [LocalDeviceProfile]) {
        let sheet = NearbyDeviceSheetController(profile: profile, savedDevices: savedDevices) { [weak self] sheet, choice in
            guard let self else { return }
            switch choice {
            case .open: self.nearbyFollowUp = .localControl(profile)
            case .save: self.nearbyFollowUp = .discoveredDevice(profile, replacing: nil)
            case let .replace(saved): self.nearbyFollowUp = .discoveredDevice(profile, replacing: saved)
            }
            // Navigation waits for `onDismiss`, after the sheet is gone, so the
            // push never fights the dismissal.
            RCSheet.dismiss(sheet)
        }
        let regularWidth = traitCollection.horizontalSizeClass == .regular
        sheet.prepareFittingSize(width: regularWidth ? min(view.bounds.width, 540) : view.bounds.width)
        RCSheet.present(sheet, from: self, detents: [.fitting]) { [weak self] in
            self?.runNearbyFollowUp()
        }
    }

    private func runNearbyFollowUp() {
        guard let route = nearbyFollowUp else { return }
        nearbyFollowUp = nil
        guard !isDemo else { return }
        push(route)
    }

    // MARK: Relay

    private func relayDevice(_ id: String) -> DevicesSnapshot.RelayDevice? {
        if isDemo { return snapshot.relay?.devices.first { $0.id == id } }
        return appModel.devices.first { $0.id == id }.map(DevicesSnapshot.RelayDevice.init)
    }

    private func openRelayDevice(_ id: String) {
        guard let device = relayDevice(id) else { return }
        if DevicesViewState.isRelayDeviceAvailable(device) {
            RCHaptics.play(.light)
            guard !isDemo else { return }
            push(.relayControl(deviceID: id))
        } else {
            RCHaptics.play(.warning)
            presentUnavailable(DevicesViewState.unavailableMessage(for: device))
        }
    }

    private func relayMenu() -> [RCMenuSection] {
        guard case let .paired(relay)? = state?.relay else { return [] }
        let busy = relay.isBusy
        let choices = relay.choices.map { choice in
            RCMenuItem(choice.title, icon: .server, isChecked: choice.isSelected) { [weak self] in
                guard let self, !self.isDemo else { return }
                Task { await self.appModel.selectProfile(choice.relayID) }
            }
        }
        return [
            RCMenuSection(title: "Relays", items: choices),
            RCMenuSection(items: [
                RCMenuItem("Add relay", icon: .plus, isEnabled: !busy) { [weak self] in self?.push(.pairRelay) },
                RCMenuItem("Refresh", icon: .refreshCw, isEnabled: !busy) { [weak self] in
                    guard let self, !self.isDemo else { return }
                    Task { await self.appModel.refreshDevices() }
                },
            ]),
            RCMenuSection(items: [
                RCMenuItem("Delete relay", icon: .trash2, role: .destructive, isEnabled: !busy) { [weak self] in
                    self?.confirmRelayDeletion()
                },
            ]),
        ]
    }

    private func confirmRelayDeletion() {
        let relayID = isDemo ? snapshot.relay?.selected.relayID : appModel.profile?.relayID
        guard let relayID else { return }
        RCDialog.present(
            title: "Delete this relay?",
            message: "The relay revokes this controller and closes its sessions, then the profile and its keys are removed from this phone. Other relays and saved local devices are not affected.",
            icon: .trash2,
            tone: .danger,
            actions: [
                RCDialogAction("Cancel", style: .cancel),
                RCDialogAction("Revoke and delete", style: .destructive) { [weak self] in
                    // Only the relay the user confirmed; never a profile selected since.
                    guard let self, !self.isDemo, self.appModel.profile?.relayID == relayID else { return }
                    Task { await self.appModel.deleteRelay() }
                },
            ],
            from: self
        )
    }

    /// The relay could not acknowledge a delete: offer a local-only delete.
    /// Presented only while this screen is visible; re-checked on appear.
    private func presentDeletionFailureIfNeeded() {
        guard homeVisible, !presentingDeletionFailure, let failure = appModel.relayDeletionFailure else { return }
        presentingDeletionFailure = true
        RCDialog.present(
            title: failure.alreadyRevoked ? "Access already revoked" : "Relay did not confirm",
            message: failure.message,
            icon: .triangleAlert,
            tone: .danger,
            actions: [
                RCDialogAction("Keep", style: .cancel) { [weak self] in
                    guard let self else { return }
                    if self.appModel.relayDeletionFailure == failure { self.appModel.relayDeletionFailure = nil }
                },
                RCDialogAction("Delete anyway", style: .destructive) { [weak self] in
                    guard let self else { return }
                    // A stale dialog must not delete a profile whose failure was cleared or replaced.
                    guard self.appModel.relayDeletionFailure == failure else { return }
                    self.appModel.forceDeleteRelay()
                },
            ],
            from: self,
            onFinish: { [weak self] in
                // Also runs when the card is torn down without a choice, so the
                // screen can offer a newer failure instead of staying blocked.
                guard let self else { return }
                self.presentingDeletionFailure = false
                self.presentDeletionFailureIfNeeded()
            }
        )
    }

    // MARK: Top bar menus

    private func addMenu() -> [RCMenuSection] {
        let busy = state?.isBusy ?? false
        return [RCMenuSection(items: [
            RCMenuItem("Scan pairing code", icon: .scanQrCode, isEnabled: !busy) { [weak self] in self?.push(.pairRelay) },
            RCMenuItem("Add local device", icon: .wifi) { [weak self] in self?.push(.localDevice(editing: nil)) },
        ])]
    }

    private func moreMenu() -> [RCMenuSection] {
        let current = environment.appearance.appearance
        let appearances = RCAppearance.allCases.map { value in
            RCMenuItem(Self.appearanceTitle(value), isChecked: value == current) { [weak self] in
                self?.environment.appearance.set(value)
            }
        }
        return [
            RCMenuSection(items: [
                RCMenuItem("Appearance", subtitle: Self.appearanceTitle(current), icon: .sunMoon, children: [RCMenuSection(title: "Appearance", items: appearances)]),
            ]),
            RCMenuSection(items: [
                RCMenuItem("About rctl", icon: .info) { [weak self] in self?.presentAbout() },
            ]),
        ]
    }

    private static func appearanceTitle(_ appearance: RCAppearance) -> String {
        switch appearance {
        case .system: "System"
        case .warm: "Warm"
        case .console: "Console"
        }
    }

    private func presentAbout() {
        let build = Self.appBuild.map { " (\($0))" } ?? ""
        RCDialog.present(
            title: "rctl controller",
            message: "Version \(Self.appVersion)\(build)\nControl your rctl devices on the local network or through a paired relay.",
            icon: .info,
            tone: .neutral,
            actions: [RCDialogAction("Done", style: .primary)],
            from: self
        )
    }

#if DEBUG
    // MARK: - Debug launch

    private func presentDebugMenu(_ name: String) {
        switch name {
        case "add": RCMenu.present(addMenu(), from: addButton, alignment: .trailing)
        case "more": RCMenu.present(moreMenu(), from: moreButton, alignment: .trailing)
        case "appearance": RCMenu.present(moreMenu().first?.items.first?.children ?? [], from: moreButton, alignment: .trailing)
        case "relay": RCMenu.present(relayMenu(), from: relayOptionsButton, alignment: .trailing)
        case "local-row":
            if let id = state?.local.rows.first?.id { contextMenus[id]?.present() }
        case "refresh": pullToRefresh.beginRefreshing()
        case "delete-relay": confirmRelayDeletion()
        case "about": presentAbout()
        case "unavailable":
            if let device = snapshot.relay?.devices.first(where: { !DevicesViewState.isRelayDeviceAvailable($0) }) { openRelayDevice(device.id) }
        case "remove":
            if let device = snapshot.localDevices.first { confirmRemoval(of: device.id) }
        case "nearby-row":
            if let id = state?.nearby.rows.first(where: \.offersAddressReplacement)?.id { contextMenus[id]?.present() }
        default: break
        }
    }

    /// `--rctl-scroll=<points>` scrolls the list for top-bar screenshots;
    /// `--rctl-demo-sheet` opens the nearby decision sheet with fixture data;
    /// `--rctl-demo-cycle` steps through every fixture to review transitions;
    /// `--rctl-devices-script=discovery` toggles real discovery on a timer
    /// (lifecycle smoke test without UI automation);
    /// `--rctl-demo-menu=add|more|appearance|relay|local-row|nearby-row` opens a menu
    /// (`delete-relay|remove|unavailable|about` a dialog, `refresh` the pull-to-refresh state).
    private func applyDebugLaunchOnce() {
        guard !appliedDebugLaunch else { return }
        appliedDebugLaunch = true
        if isDemo, let menu = DebugLaunch.argument("rctl-demo-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.presentDebugMenu(menu) }
            }
        }
        if isDemo, DebugLaunch.flag("rctl-demo-cycle") {
            let order: [DevicesDemoFixture] = [.firstRun, .nearbySearching, .nearbyEmpty, .populated, .relayLoading, .nearbyDenied, .firstRun]
            Task { [weak self] in
                for fixture in order {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard let self else { return }
                    self.demo = fixture
                    self.renderer.setNeedsRender()
                }
            }
        }
        if !isDemo, DebugLaunch.argument("rctl-devices-script") == "discovery" {
            let steps: [(UInt64, @MainActor (DevicesViewController) -> Void)] = [
                (1_500_000_000, { $0.enableDiscovery() }),
                (3_000_000_000, { $0.restartDiscovery() }),
                (3_000_000_000, { $0.disableDiscovery() }),
                (2_000_000_000, { $0.enableDiscovery() }),
            ]
            Task { [weak self] in
                for (delay, step) in steps {
                    try? await Task.sleep(nanoseconds: delay)
                    guard let self else { return }
                    step(self)
                }
            }
        }
        if DebugLaunch.flag("rctl-landscape"), #available(iOS 16.0, *), let scene = view.window?.windowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        }
        if let value = DebugLaunch.argument("rctl-scroll"), let offset = Double(value) {
            view.layoutIfNeeded()
            let maxOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            scrollView.setContentOffset(CGPoint(x: 0, y: min(CGFloat(offset), maxOffset)), animated: false)
        }
        if isDemo, DebugLaunch.flag("rctl-demo-sheet"), let address = try? LocalDeviceAddress("192.168.1.51:8080") {
            let profile = LocalDeviceProfile(id: UUID(), name: "Bedroom iPad", address: address)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.presentNearbySheet(for: profile, savedDevices: self.snapshot.localDevices)
                }
            }
        }
    }
#endif
}
