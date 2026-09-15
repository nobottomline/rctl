import Combine
import UIKit

/// Full-screen pairing-code scanner. The reticle rests in the middle, springs
/// onto a detected code, confirms the lock, then claims the code in place.
/// Success pops back to Devices through the router; failures are presented by
/// the app and the same code is ignored briefly.
///
/// Layering: the preview, the edge gradients and the reticle share one
/// full-bleed stage so detection bounds (preview-layer coordinates) map 1:1.
/// Copy and controls sit above it inside the safe area.
@MainActor
final class ScannerViewController: RCViewController, AppRoutable {
    let route: AppRoute = .scanPairingCode
    private let environment: AppEnvironment
    private let flow = ScannerDetectionFlow(clock: MainQueueScannerClock())

    private let stage = UIView()
    private var camera: QRScannerService?
    private let topGradient = CAGradientLayer()
    private let bottomGradient = CAGradientLayer()
    private let reticle = ScannerReticleView()
    private let instruction = ScannerInstructionView()
    private let backButton = RCIconButton(icon: .arrowLeft, variant: .overlayProminent, diameter: 60, iconSize: 22, accessibilityLabel: "Back")
    private let pasteButton = RCButton(title: "Paste code", icon: nil, variant: .ghost, size: .medium)
    private let torchButton = RCIconButton(icon: .flashlightOff, variant: .overlay, diameter: 60, iconSize: 22, accessibilityLabel: "Flashlight")
    private let unavailableView = ScannerCameraUnavailableView()
    private let unavailableBackButton = RCIconButton(icon: .arrowLeft, variant: .overlay, diameter: 48, iconSize: 20, accessibilityLabel: "Back")

    private var isVisible = false
    /// Scene activity as last published (`@Published` emits before storing, so it is kept here).
    private var isSceneActive = false
    private var laidOutBounds: CGRect = .zero
    private var restingRect: CGRect = .zero
    private var laidOutRestingRect: CGRect = .zero
    private var cancellables: Set<AnyCancellable> = []
    /// A claim waiting for the model to become idle; cancelled when the scanner is popped.
    private var pendingClaim: Task<Void, Never>?

#if DEBUG
    private var demo: ScannerDemo?
    private var demoPreview: ScannerDemoPreviewView?
    private var forcedAvailability: QRScannerService.Availability?
#endif

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(chrome: .stage)
    }

    override var allowsInteractivePop: Bool { flow.phase != .pairing }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildStage()
        buildControls()
        wireFlow()
        environment.lifecycle.$isActive
            .removeDuplicates()
            .sink { [weak self] active in
                MainActor.assumeIsolated {
                    self?.isSceneActive = active
                    self?.updateCapture()
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIAccessibility.reduceMotionStatusDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.flow.reduceMotion = RCMotion.reduceMotion
                    self.render(animated: false)
                }
            }
            .store(in: &cancellables)
        flow.reduceMotion = RCMotion.reduceMotion
        render(animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        updateCapture()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        if isMovingFromParent || navigationController == nil {
            // Leaving the scanner must not claim a code the user walked away from.
            pendingClaim?.cancel()
            pendingClaim = nil
        }
        updateCapture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutStage()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.camera?.previewView.alignOrientation()
        }
    }

    // MARK: - Building

    private func buildStage() {
        stage.backgroundColor = RCColor.stage
        view.addSubview(stage)
#if DEBUG
        if let state = DebugLaunch.argument("rctl-scanner-state") {
            switch state {
            case "denied": forcedAvailability = .denied
            case "unavailable": forcedAvailability = .unavailable("This device has no usable camera.")
            default: break
            }
        }
        if forcedAvailability == nil, ScannerDemo.isEnabled {
            let preview = ScannerDemoPreviewView()
            stage.addSubview(preview)
            demoPreview = preview
            let demo = ScannerDemo()
            demo.onDetection = { [weak self] detection in self?.flow.update(detection) }
            self.demo = demo
        }
        if forcedAvailability == nil, demo == nil {
            installCamera()
        }
#else
        installCamera()
#endif
        topGradient.colors = [UIColor(white: 0, alpha: 0.55).cgColor, UIColor(white: 0, alpha: 0).cgColor]
        bottomGradient.colors = [UIColor(white: 0, alpha: 0).cgColor, UIColor(white: 0, alpha: 0.62).cgColor]
        stage.layer.addSublayer(topGradient)
        stage.layer.addSublayer(bottomGradient)
        stage.addSubview(reticle)
    }

    private func installCamera() {
        let camera = QRScannerService()
        camera.onDetection = { [weak self] detection in
            // While a dialog or progress card covers the scanner (e.g. the error
            // from a failed claim), a code still in view must not be claimed again.
            guard detection == nil || RCModalQueue.shared.isIdle else { return }
            self?.flow.update(detection)
        }
        camera.onStateChange = { [weak self] in self?.render(animated: true) }
        stage.addSubview(camera.previewView)
        self.camera = camera
    }

    private func buildControls() {
        view.addSubview(instruction)

        backButton.onTap = { [weak self] in self?.environment.router.pop() }
        pasteButton.haptic = nil
        pasteButton.accessibilityLabel = "Paste pairing code"
        pasteButton.onTap = { [weak self] in self?.paste() }
        torchButton.onTap = { [weak self] in self?.toggleTorch() }
        view.addSubview(backButton)
        view.addSubview(pasteButton)
        view.addSubview(torchButton)

        unavailableView.isHidden = true
        unavailableView.settingsButton.onTap = { [weak self] in self?.openSettings() }
        unavailableView.pasteButton.onTap = { [weak self] in self?.paste() }
        unavailableBackButton.onTap = { [weak self] in self?.environment.router.pop() }
        unavailableBackButton.isHidden = true
        view.addSubview(unavailableView)
        view.addSubview(unavailableBackButton)
    }

    private func wireFlow() {
        flow.onStateChange = { [weak self] in self?.render(animated: true) }
        flow.onFeedback = { feedback in
            switch feedback {
            case .lock: RCHaptics.play(.light)
            case .foreign: RCHaptics.play(.soft)
            case .deliver: RCHaptics.play(.success)
            }
        }
        flow.onDeliver = { [weak self] payload in self?.claim(payload) }
    }

    // MARK: - Layout

    private func layoutStage() {
        let bounds = view.bounds
        let safe = bounds.inset(by: view.safeAreaInsets)
        let insets = view.safeAreaInsets
        stage.frame = bounds
        camera?.previewView.frame = bounds
#if DEBUG
        demoPreview?.frame = bounds
#endif
        reticle.frame = bounds
        restingRect = ScannerGeometry.restingRect(safeFrame: safe)

        let compactHeight = traitCollection.verticalSizeClass == .compact
        let controlSide: CGFloat = 60
        let pasteSize = pasteButton.sizeThatFits(bounds.size)
        let copyBottom: CGFloat
        let controlsTop: CGFloat

        if compactHeight {
            // Landscape phone: copy in the left column, controls stacked on the right.
            let columnWidth = max(0, restingRect.minX - safe.minX - 2 * RCSpace.xl)
            let size = instruction.sizeThatFits(CGSize(width: columnWidth, height: safe.height))
            instruction.frame = CGRect(x: safe.minX + RCSpace.xl, y: safe.midY - size.height / 2, width: columnWidth, height: size.height)
            copyBottom = safe.minY
            let x = safe.maxX - RCSpace.xl - controlSide
            backButton.frame = CGRect(x: x, y: safe.minY + RCSpace.md, width: controlSide, height: controlSide)
            torchButton.frame = CGRect(x: x, y: safe.maxY - RCSpace.md - controlSide, width: controlSide, height: controlSide)
            pasteButton.frame = CGRect(
                x: min(x + controlSide / 2 - pasteSize.width / 2, safe.maxX - pasteSize.width),
                y: safe.midY - pasteSize.height / 2,
                width: pasteSize.width,
                height: pasteSize.height
            )
            controlsTop = bounds.maxY
        } else {
            let width = min(safe.width - 2 * RCSpace.xxxl, 440)
            let size = instruction.sizeThatFits(CGSize(width: width, height: safe.height))
            instruction.frame = CGRect(x: safe.midX - width / 2, y: safe.minY + 18, width: width, height: size.height)
            copyBottom = instruction.frame.maxY
            let reservedCopyBottom = instruction.frame.minY + instruction.reservedHeight(width: width)
            let bottomPadding: CGFloat = insets.bottom > 0 ? 14 : RCSpace.xl
            let rowCenter = safe.maxY - bottomPadding - controlSide / 2
            // Keep the controls within thumb reach on wide screens.
            let rowWidth = min(safe.width - 44, 520)
            let rowMinX = safe.midX - rowWidth / 2
            backButton.frame = CGRect(x: rowMinX, y: rowCenter - controlSide / 2, width: controlSide, height: controlSide)
            torchButton.frame = CGRect(x: rowMinX + rowWidth - controlSide, y: rowCenter - controlSide / 2, width: controlSide, height: controlSide)
            let pasteWidth = min(pasteSize.width, torchButton.frame.minX - backButton.frame.maxX - 2 * RCSpace.sm)
            pasteButton.frame = CGRect(x: safe.midX - pasteWidth / 2, y: rowCenter - pasteSize.height / 2, width: pasteWidth, height: pasteSize.height)
            controlsTop = rowCenter - controlSide / 2
            // Large Dynamic Type: rest below the tallest copy, above the controls.
            restingRect = ScannerGeometry.restingRect(
                safeFrame: safe,
                minimumTop: reservedCopyBottom + RCSpace.xl,
                maximumBottom: controlsTop - RCSpace.xxl
            )
        }
        reticle.restingRect = restingRect
        withoutImplicitAnimations {
            // The top scrim always backs the copy, however tall it gets.
            topGradient.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(insets.top + 130, copyBottom + 56))
            let bottomHeight = insets.bottom + 170
            bottomGradient.frame = CGRect(x: 0, y: bounds.height - bottomHeight, width: bounds.width, height: bottomHeight)
        }
        reticle.captionLimits = (top: copyBottom + RCSpace.sm, bottom: controlsTop - RCSpace.md)

        unavailableView.frame = bounds.inset(by: UIEdgeInsets(top: insets.top + 56, left: insets.left, bottom: insets.bottom, right: insets.right))
        unavailableBackButton.frame = CGRect(x: safe.minX + RCSpace.lg, y: safe.minY + RCSpace.sm, width: 48, height: 48)

        if bounds != laidOutBounds || restingRect != laidOutRestingRect {
            laidOutBounds = bounds
            laidOutRestingRect = restingRect
            render(animated: false)
#if DEBUG
            if isRunningCapture { demo?.start(stageSize: bounds.size) }
#endif
        }
    }

    // MARK: - Capture lifecycle

    private var isRunningCapture: Bool {
        isVisible && isSceneActive
    }

    /// The camera runs only while the screen is visible and the scene is active.
    private func updateCapture() {
        guard isViewLoaded else { return }
        if isRunningCapture {
            camera?.start()
#if DEBUG
            demo?.start(stageSize: view.bounds.size)
#endif
            reticle.resumeMotion()
        } else {
            camera?.stop()
#if DEBUG
            demo?.stop()
#endif
            flow.suspend()
        }
    }

    private var availability: QRScannerService.Availability {
#if DEBUG
        if let forcedAvailability { return forcedAvailability }
        if demo != nil { return .running }
#endif
        return camera?.availability ?? .initializing
    }

    // MARK: - Rendering

    private func render(animated: Bool) {
        guard isViewLoaded else { return }
        let availability = availability
        let showsStage: Bool
        switch availability {
        case .initializing, .running:
            showsStage = true
        case .denied:
            showsStage = false
            unavailableView.configure(.denied)
        case let .unavailable(reason):
            showsStage = false
            unavailableView.configure(.unavailable(reason: reason))
        }
        // Runs on every camera detection: only write what changed.
        for chrome in [reticle, instruction, backButton, pasteButton, torchButton] as [UIView] where chrome.isHidden == showsStage {
            chrome.isHidden = !showsStage
        }
        if unavailableView.isHidden != showsStage {
            unavailableView.isHidden = showsStage
            unavailableBackButton.isHidden = showsStage
        }
        let unavailableControlsEnabled = flow.phase != .pairing
        setEnabled(unavailableView.pasteButton, unavailableControlsEnabled)
        setEnabled(unavailableBackButton, unavailableControlsEnabled)

        let presentation = ScannerPresentation(
            phase: flow.phase,
            isShowingForeignCode: flow.isShowingForeignCode,
            hasDetection: flow.detection != nil,
            reduceMotion: RCMotion.reduceMotion
        )
#if DEBUG
        demoPreview?.detection = flow.detection
#endif
        let target = ScannerGeometry.targetRect(detectionBounds: flow.detection?.bounds, resting: restingRect)
        if !restingRect.isEmpty {
            reticle.apply(
                target: target,
                tone: presentation.tone,
                showsBadge: presentation.showsLockBadge,
                showsCaption: presentation.showsForeignCaption,
                showsCard: presentation.showsPairingCard,
                breathing: presentation.isBreathing && showsStage,
                animated: animated && isVisible
            )
        }

        if instruction.setText(title: presentation.title, message: presentation.message, animated: animated && isVisible) {
            view.setNeedsLayout()
            if animated, isVisible, UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: presentation.title)
            }
        }

        setEnabled(backButton, presentation.controlsEnabled)
        setEnabled(pasteButton, presentation.controlsEnabled)
        let torchAvailable = camera?.isTorchAvailable ?? false
        let torchOn = camera?.isTorchOn ?? false
        torchButton.setGlyphIfNeeded(torchOn ? .flashlight : .flashlightOff)
        let torchVariant: RCIconButton.Variant = torchOn ? .overlayProminent : .overlay
        if torchButton.variant != torchVariant { torchButton.variant = torchVariant }
        let torchValue = torchOn ? "On" : "Off"
        if torchButton.accessibilityValue != torchValue { torchButton.accessibilityValue = torchValue }
        setEnabled(torchButton, presentation.controlsEnabled && torchAvailable)
        let torchAlpha: CGFloat = torchAvailable ? (torchButton.isEnabled ? 1 : 0.4) : 0.35
        if torchButton.alpha != torchAlpha { torchButton.alpha = torchAlpha }
    }

    private func setEnabled(_ control: UIControl, _ enabled: Bool) {
        if control.isEnabled != enabled { control.isEnabled = enabled }
    }

    // MARK: - Actions

    private func claim(_ payload: String) {
#if DEBUG
        if demo != nil {
            // The demo never reaches the model: report a failed claim so the
            // rejection window and the return to scanning are exercised.
            DispatchQueue.main.asyncAfter(deadline: .now() + ScannerDemo.claimDuration) { [weak self] in
                MainActor.assumeIsolated {
                    self?.flow.deliveryDidFinish(payload: payload, paired: false)
                }
            }
            return
        }
#endif
        let model = environment.appModel
        pendingClaim?.cancel()
        pendingClaim = Task { @MainActor [weak self] in
            // Another short request (e.g. a device refresh) may hold the model;
            // wait for it instead of dropping the code, but never past a pop.
            var waited: TimeInterval = 0
            while model.isBusy, waited < 10 {
                do { try await Task.sleep(seconds: 0.1) } catch { return }
                waited += 0.1
            }
            guard !Task.isCancelled, let self else { return }
            self.pendingClaim = nil
            guard !model.isBusy else {
                // Claiming now would be refused without an explanation.
                self.flow.deliveryDidFinish(payload: payload, paired: false)
                RCToast.show("Relay is still busy", message: "Try the code again in a moment.", tone: .warning, in: self.view.window)
                return
            }
            // The claim itself runs outside the cancellable wait: a successful
            // pairing pops this screen while the model is still loading devices.
            Task { @MainActor [weak self] in
                let paired = await model.pair(using: payload)
                self?.flow.deliveryDidFinish(payload: payload, paired: paired)
            }
        }
    }

    private func paste() {
        guard flow.phase != .pairing else { return }
        guard let code = PairingClipboard.takePairingCode(presentingIn: view.window) else { return }
        flow.deliverPasted(code)
    }

    private func toggleTorch() {
        guard let camera else { return }
        camera.setTorch(!camera.isTorchOn)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private extension RCIconButton {
    func setGlyphIfNeeded(_ glyph: RCIconGlyph) {
        if icon != glyph { icon = glyph }
    }
}
