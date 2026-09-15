import Combine
import RctlClient
import RctlRealtime
import UIKit

/// What a remote session connects to.
enum RemoteSessionTarget: Equatable {
    case local(LocalDeviceProfile)
    case relay(deviceID: String)
}

/// Full-screen remote screen/camera session on the black stage.
///
/// Lifecycle (parity with the SwiftUI controller):
/// - connects on first appearance; suspends when the scene resigns active and
///   resumes when it becomes active again, only while this screen is in the stack;
/// - disconnects when popped or removed from the stack;
/// - the video view is attached to the session only while it is in a window.
///
/// Safety: every (re)connection, interruption and suspension returns to View
/// (enforced by the model). Control requires an explicit tap and is selectable
/// only while `canControl`. Remote input, Home and the keyboard exist only while
/// controls are enabled; the keyboard panel closes itself when they are not.
@MainActor
final class RemoteSessionViewController: RCViewController, AppRoutable {
    let route: AppRoute
    private let environment: AppEnvironment
    private let target: RemoteSessionTarget
    /// Nil when the relay device disappeared before the screen opened (the
    /// screen then never connects), or in the Debug screenshot demo.
    private let model: RemoteSessionModel?
    private let deviceName: String
    private let accessPath: RemoteAccessPathPresentation?
#if DEBUG
    private var demo: RemoteSessionDemo?
#endif

    private lazy var renderer = RenderScheduler { [weak self] in self?.render() }
    private var lifecycleObservation: AnyCancellable?

    private var viewport: RemoteViewportView?
    private var header: RemoteSessionHeaderView?
    private let dock = RemoteControlDockView()
    private let statusOverlay = RemoteStatusOverlayView()
    private var keyboardPanel: RemoteKeyboardPanelView?
    private weak var toolsController: RemoteToolsViewController?
    private var missingState: (back: RCIconButton, empty: RCEmptyStateView)?

    private var presentation: RemoteSessionPresentation?
    private var toolsDiagnostics: RctlRealtimeDiagnostics?
    private var keyboardVisible = false
    private var keyboardOverlap: CGFloat = 0
    private var didStartSession = false
    private var tornDown = false

    init(environment: AppEnvironment, target: RemoteSessionTarget) {
        self.environment = environment
        self.target = target
        var name = ""
        var path: RemoteAccessPathPresentation?
        var relayDevice: ControllerDevice?
        switch target {
        case let .local(device):
            route = .localControl(device)
            name = device.name
            path = RemoteAccessPathPresentation(.lan(device.address))
        case let .relay(deviceID):
            route = .relayControl(deviceID: deviceID)
            // The name is captured once, like the SwiftUI screen. A device that
            // is gone at creation shows an explanation and never connects.
            relayDevice = environment.appModel.devices.first { $0.id == deviceID }
            if let relayDevice {
                name = relayDevice.name
                path = RemoteAccessPathPresentation(.relay(origin: environment.appModel.profile?.origin))
            }
        }
#if DEBUG
        var demo = RemoteSessionDemo.fromLaunchArguments(target: target)
        if demo?.state == .missing {
            demo = nil
            path = nil
        }
        self.demo = demo
        let forcesMissing = DebugLaunch.argument("rctl-remote-demo") == "missing"
        if let demo {
            if name.isEmpty { name = "Studio iPad" }
            path = RemoteAccessPathPresentation(demo.accessPath)
        }
        let createsModel = demo == nil && !forcesMissing
#else
        let createsModel = true
#endif
        var model: RemoteSessionModel?
        if createsModel {
            switch target {
            case let .local(device):
                model = RemoteSessionModel(
                    appModel: environment.appModel,
                    target: .local(device.address),
                    localClient: environment.localDevices.client
                )
            case .relay:
                model = relayDevice.map { RemoteSessionModel(appModel: environment.appModel, deviceID: $0.id) }
            }
        }
        if let model { path = RemoteAccessPathPresentation(model.accessPath) }
        self.model = model
        deviceName = name
        accessPath = path
        super.init(chrome: .stage)
    }

    private var isSessionScreen: Bool {
#if DEBUG
        if demo != nil { return true }
#endif
        return model != nil
    }

    // MARK: View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        guard isSessionScreen, let path = accessPath else {
            buildMissingState()
            return
        }
        let viewport = RemoteViewportView()
        let header = RemoteSessionHeaderView(deviceName: deviceName, path: path)
        self.viewport = viewport
        self.header = header
        view.addSubview(viewport)
        view.addSubview(statusOverlay)
        view.addSubview(dock)
        view.addSubview(header)
        view.accessibilityElements = [header, statusOverlay, viewport, dock]

        header.onBack = { [weak self] in self?.environment.router.pop() }
        statusOverlay.onReconnect = { [weak self] in self?.reconnect() }
        dock.onSelectMedia = { [weak self] media in self?.selectMedia(media) }
        dock.onSelectMode = { [weak self] mode in self?.selectMode(mode) }
        dock.onHome = { [weak self] in self?.sendHardware(.home) }
        dock.onKeyboard = { [weak self] in self?.setKeyboardVisible(self?.presentation?.controlsEnabled == true) }
        dock.onTools = { [weak self] in
            self?.setKeyboardVisible(false)
            self?.presentTools()
        }

        if let model {
            viewport.session = model.session
            viewport.onTouch = { [weak model] event in
                model?.sendTouch(phase: event.phase.rawValue, finger: event.finger, x: event.x, y: event.y)
            }
            renderer.observe(model)
        }
#if DEBUG
        if let demo { viewport.showDemoPlaceholder(RemoteSessionDemo.placeholderImage(media: demo.snapshot.media)) }
#endif

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)

        // Only changes matter (like SwiftUI's onChange(of: scenePhase)); the
        // first appearance connects on its own.
        lifecycleObservation = environment.lifecycle.$isActive
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] active in
                MainActor.assumeIsolated { self?.sceneActivityChanged(active) }
            }
        renderer.renderNow()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStartSession, !tornDown, isSessionScreen else { return }
        didStartSession = true
        if let model {
            Task { await model.connect() }
        }
#if DEBUG
        switch demo?.state {
        case .keyboard:
            // A forced demo orientation rotates after appearance; open the keyboard once it settled.
            let delay: TimeInterval = demo?.orientation == nil ? 0 : 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.setKeyboardVisible(true) }
            }
        case .tools: presentTools()
        case .lock:
            presentTools()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                MainActor.assumeIsolated { self?.toolsController?.presentLockConfirmation() }
            }
        case .sourceMenu:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.dock.openSourceMenu() }
            }
        case .cycle: runDemoCycle(step: 0)
        default: break
        }
#endif
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || parent == nil {
            tearDown()
        }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        // Covers stack replacement while this screen was not visible.
        if parent == nil { tearDown() }
    }

#if DEBUG
    private func runDemoCycle(step: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.tornDown, self.demo != nil else { return }
                let state = RemoteSessionDemo.cycleScript[step % RemoteSessionDemo.cycleScript.count]
                self.demo?.show(state)
                self.viewport?.showDemoPlaceholder(RemoteSessionDemo.placeholderImage(media: self.demo?.snapshot.media ?? .screen))
                self.renderer.renderNow()
                if state == .keyboard { self.setKeyboardVisible(true) }
                self.runDemoCycle(step: step + 1)
            }
        }
    }
#endif

    private func sceneActivityChanged(_ active: Bool) {
        guard !tornDown, let model else { return }
        if active {
            Task { await model.resume() }
        } else {
            model.suspend()
        }
    }

    private func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        lifecycleObservation = nil
        NotificationCenter.default.removeObserver(self)
        keyboardPanel?.resignFocus()
        // Release held touches through the model before the session closes.
        viewport?.inputEnabled = false
        model?.disconnect()
        renderer.cancelAll()
    }

    // MARK: Render

    private func currentSnapshot() -> RemoteSessionSnapshot? {
#if DEBUG
        if let demo { return demo.snapshot }
#endif
        guard let model, let accessPath else { return nil }
        return RemoteSessionSnapshot(
            state: model.state,
            videoAvailable: model.videoAvailable,
            videoHealth: model.videoHealth,
            media: model.media,
            interactionMode: model.interactionMode,
            canControl: model.canControl,
            reconnecting: model.reconnecting,
            reconnectAttempt: model.reconnectAttempt,
            errorMessage: model.errorMessage,
            isLocal: accessPath.isLocal
        )
    }

    private var currentDiagnostics: RctlRealtimeDiagnostics {
#if DEBUG
        if let demo { return demo.diagnostics }
#endif
        return model?.diagnostics ?? RctlRealtimeDiagnostics()
    }

    private func render() {
        guard !tornDown, let snapshot = currentSnapshot() else { return }
        let next = RemoteSessionPresentation(snapshot)
        let previous = presentation
        if next != previous {
            presentation = next
            let animated = previous != nil && view.window != nil
            header?.apply(next, animated: animated)
            dock.apply(next)
            viewport?.inputEnabled = next.controlsEnabled
            statusOverlay.apply(next.overlay, animated: animated)
            if !next.controlsEnabled, keyboardVisible {
                setKeyboardVisible(false)
            }
            if previous?.isControlMode != next.isControlMode {
                updateSystemGestureDeferral()
            }
        }
        renderTools()
    }

    private func renderTools() {
        guard let toolsController, let presentation else { return }
        let diagnostics = currentDiagnostics
        let tools = RemoteToolsPresentation(
            diagnostics: diagnostics == toolsDiagnostics ? toolsController.currentDiagnostics : RemoteDiagnosticsPresentation(diagnostics),
            actionsEnabled: presentation.controlsEnabled
        )
        toolsDiagnostics = diagnostics
        toolsController.update(tools)
    }

    // MARK: Actions

    private func selectMedia(_ media: ControllerMediaRole) {
        setKeyboardVisible(false)
#if DEBUG
        if demo != nil {
            demo?.selectMedia(media)
            viewport?.showDemoPlaceholder(RemoteSessionDemo.placeholderImage(media: media))
            renderer.setNeedsRender()
            return
        }
#endif
        guard let model else { return }
        Task { await model.selectMedia(media) }
    }

    private func selectMode(_ mode: RemoteInteractionMode) {
        if mode != .control { setKeyboardVisible(false) }
#if DEBUG
        if demo != nil {
            demo?.selectMode(mode)
            renderer.setNeedsRender()
            return
        }
#endif
        model?.setInteractionMode(mode)
        // A refused Control request still re-renders and snaps the segment back.
        renderer.setNeedsRender()
    }

    private func sendHardware(_ action: RemoteHardwareAction) {
        model?.sendHardware(action)
    }

    private func reconnect() {
#if DEBUG
        if demo != nil {
            demo?.reconnect()
            renderer.setNeedsRender()
            return
        }
#endif
        guard let model else { return }
        Task { await model.connect() }
    }

    private func sendText(_ text: String) -> RemoteTextInputResult {
#if DEBUG
        if demo != nil { return .sent(characterCount: text.count) }
#endif
        return model?.sendText(text) ?? .rejected(message: "Control mode is required for keyboard input.")
    }

    private func presentTools() {
        guard toolsController == nil, !tornDown, let path = accessPath, let presentation else { return }
        let diagnostics = currentDiagnostics
        let controller = RemoteToolsViewController(
            deviceName: deviceName,
            path: path,
            tools: RemoteToolsPresentation(diagnostics: RemoteDiagnosticsPresentation(diagnostics), actionsEnabled: presentation.controlsEnabled)
        )
        toolsDiagnostics = diagnostics
        controller.onHardware = { [weak self] action in self?.sendHardware(action) }
        controller.onReconnect = { [weak self] in self?.reconnect() }
        toolsController = controller
        RCSheet.present(controller, from: self, detents: [.fitting, .large])
    }

    // MARK: Keyboard panel

    private func makeKeyboardPanel() -> RemoteKeyboardPanelView {
        if let keyboardPanel { return keyboardPanel }
        let panel = RemoteKeyboardPanelView()
        panel.isHidden = true
        panel.alpha = 0
        panel.onSendText = { [weak self] text in
            self?.sendText(text) ?? .rejected(message: "Control mode is required for keyboard input.")
        }
        panel.onSendKey = { [weak self] key in
#if DEBUG
            if self?.demo != nil { return }
#endif
            self?.model?.sendKeyboard(key)
        }
        panel.onClose = { [weak self] in self?.setKeyboardVisible(false) }
        panel.onHeightChange = { [weak self] in
            guard let self, self.keyboardVisible else { return }
            self.view.setNeedsLayout()
            RCMotion.animate(RCMotion.snappy) { self.view.layoutIfNeeded() }
        }
        view.insertSubview(panel, belowSubview: header ?? dock)
        keyboardPanel = panel
        view.accessibilityElements = [header, statusOverlay, viewport, panel, dock].compactMap { $0 }
        return panel
    }

    private func setKeyboardVisible(_ visible: Bool, animated: Bool = true) {
        guard visible != keyboardVisible else { return }
        if visible, presentation?.controlsEnabled != true { return }
        keyboardVisible = visible
        guard let panel = visible ? makeKeyboardPanel() : keyboardPanel else { return }
        let incoming: UIView = visible ? panel : dock
        let outgoing: UIView = visible ? dock : panel
        let offset = RCMotion.reduceMotion ? CGAffineTransform.identity : CGAffineTransform(translationX: 0, y: 14)

        incoming.isHidden = false
        if visible {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            panel.focus()
        } else {
            panel.resignFocus()
            view.setNeedsLayout()
        }
        let animate = animated && view.window != nil
        if animate, incoming.alpha < 1 { incoming.transform = offset }

        // The outgoing surface leaves quickly so the two never read as stacked;
        // the incoming one settles with a spring (a fade under Reduce Motion).
        let hideOutgoing: @MainActor @Sendable () -> Void = { outgoing.alpha = 0 }
        let finishOutgoing: @MainActor @Sendable (Bool) -> Void = { [weak self] _ in
            guard let self, self.keyboardVisible == visible else { return }
            outgoing.isHidden = true
            outgoing.transform = .identity
        }
        let showIncoming: @MainActor @Sendable () -> Void = {
            self.view.layoutIfNeeded()
            incoming.alpha = 1
            incoming.transform = .identity
        }
        if animate {
            RCMotion.animate(duration: 0.12, animations: hideOutgoing, completion: finishOutgoing)
            RCMotion.animate(RCMotion.standard, animations: showIncoming)
        } else {
            hideOutgoing()
            finishOutgoing(true)
            showIncoming()
        }
        UIAccessibility.post(notification: .layoutChanged, argument: incoming)
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let info = notification.userInfo,
              let endFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let screenSpace: UICoordinateSpace = view.window?.screen.coordinateSpace ?? UIScreen.main.coordinateSpace
        let frame = view.convert(endFrame, from: screenSpace)
        let overlap = notification.name == UIResponder.keyboardWillHideNotification
            ? 0
            : max(0, view.bounds.maxY - frame.minY)
        guard abs(overlap - keyboardOverlap) > 0.5 else { return }
        keyboardOverlap = overlap
        guard keyboardVisible else { return }
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        view.setNeedsLayout()
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState, .allowUserInteraction],
            animations: { self.view.layoutIfNeeded() }
        )
    }

    // MARK: Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header, let viewport else {
            layoutMissingState()
            return
        }
        let size = view.bounds.size
        let safe = view.safeAreaInsets
        let style = RemoteSessionLayout.style(for: size)
        header.style = style == .rail ? .rail : .bar
        dock.axis = style == .rail ? .vertical : .horizontal

        let headerSize = header.sizeThatFits(CGSize(width: size.width, height: .greatestFiniteMagnitude))
        let dockSize = style == .bars
            ? dock.sizeThatFits(CGSize(width: RemoteSessionLayout.dockAvailableWidth(size: size, safeArea: safe), height: .greatestFiniteMagnitude))
            : dock.sizeThatFits(.zero)
        var input = RemoteSessionLayout.Input(
            size: size,
            safeArea: safe,
            style: style,
            headerHeight: headerSize.height,
            headerWidth: headerSize.width,
            dockSize: dockSize,
            keyboardOverlap: keyboardOverlap
        )
        let resting = RemoteSessionLayout(input)
        var active = resting
        if keyboardVisible, let panel = keyboardPanel {
            let panelWidth = style == .bars
                ? RemoteSessionLayout.dockAvailableWidth(size: size, safeArea: safe)
                : RemoteSessionLayout.railPanelAvailableWidth(size: size, safeArea: safe, headerWidth: headerSize.width)
            input.keyboardPanelHeight = panel.sizeThatFits(CGSize(width: panelWidth, height: .greatestFiniteMagnitude)).height
            active = RemoteSessionLayout(input)
            place(panel, active.dock)
        } else if let panel = keyboardPanel {
            // Parked just above the resting dock so the next show starts from there.
            let width = style == .bars ? RemoteSessionLayout.dockAvailableWidth(size: size, safeArea: safe) : resting.viewport.width
            let height = panel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            place(panel, CGRect(x: style == .bars ? (size.width - width) / 2 : resting.viewport.minX, y: size.height - max(safe.bottom, RemoteSessionLayout.margin) - height, width: width, height: height))
        }
        place(header, active.header)
        place(dock, resting.dock)
        place(viewport, active.viewport)
        place(statusOverlay, active.viewport)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Header and dock sizes follow Dynamic Type; the screen owns their frames.
        if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory {
            view.setNeedsLayout()
        }
    }

    /// Frame assignment that stays correct while a view carries a transition transform.
    private func place(_ target: UIView, _ frame: CGRect) {
        let aligned = RCLayout.pixelAligned(frame)
        if target.bounds.size != aligned.size { target.bounds = CGRect(origin: .zero, size: aligned.size) }
        let center = CGPoint(x: aligned.midX, y: aligned.midY)
        if target.center != center { target.center = center }
    }

    // MARK: System gestures

    override var allowsInteractivePop: Bool { presentation?.isControlMode != true }

    override var prefersHomeIndicatorAutoHidden: Bool { presentation?.isControlMode == true }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        presentation?.isControlMode == true ? .all : []
    }

    private func updateSystemGestureDeferral() {
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        navigationController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
        navigationController?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
#if DEBUG
        if let orientation = demo?.orientation { return orientation }
#endif
        return super.supportedInterfaceOrientations
    }

    override func accessibilityPerformEscape() -> Bool {
        if keyboardVisible {
            setKeyboardVisible(false)
            return true
        }
        guard allowsInteractivePop else { return false }
        environment.router.pop()
        return true
    }

    // MARK: Missing relay device

    private func buildMissingState() {
        let back = RCIconButton(icon: .chevronLeft, variant: .stage, diameter: 40, accessibilityLabel: "Back to devices")
        back.haptic = .selection
        back.onTap = { [weak self] in self?.environment.router.pop() }
        let action = RCButton(title: "Back to devices", variant: .primary, size: .medium)
        action.onTap = { [weak self] in self?.environment.router.pop() }
        let empty = RCEmptyStateView(
            icon: .unplug,
            title: "Device no longer available",
            message: "It was removed from this controller's device list. Refresh and try again.",
            actions: [action]
        )
        view.addSubview(empty)
        view.addSubview(back)
        missingState = (back, empty)
    }

    private func layoutMissingState() {
        guard let (back, empty) = missingState else { return }
        let safe = view.safeAreaInsets
        back.frame = CGRect(x: safe.left + RemoteSessionLayout.margin, y: safe.top + 8, width: 40, height: 40)
        let width = min(360, view.bounds.width - safe.left - safe.right - 40)
        let height = empty.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        empty.frame = CGRect(
            x: safe.left + (view.bounds.width - safe.left - safe.right - width) / 2,
            y: safe.top + max(56, (view.bounds.height - safe.top - safe.bottom - height) / 2),
            width: width,
            height: height
        )
    }
}
