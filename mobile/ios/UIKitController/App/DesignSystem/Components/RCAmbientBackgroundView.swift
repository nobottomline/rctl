import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Ambient backdrop for front-door screens: canvas gradient, soft color
/// blooms, paper grain (Warm) or a faint grid (Console), and a sparse field of
/// drifting motes.
///
/// Performance model:
/// - All motion is Core Animation running on the render server: long
///   repeating keyframe animations with seeded phases, asking for about
///   15 fps on iOS 15+ (the motion is a few points per second). No display
///   link, no per-frame main-thread work, no `draw(_:)`.
/// - Bloom, halo, grain and grid bitmaps are rendered once per appearance
///   (grid: per size) and shared as layer `contents`; softness comes from
///   those bitmaps, never from blurs, filters, masks or group opacity. About
///   40 layers at most.
/// - `RCAmbientMotionPolicy` decides between running, frozen and static.
///   Motion waits `motionStartDelay` before (re)starting (a backdrop animating
///   under a push transition stutters on device) and freezes whenever the
///   view leaves the window, the scene deactivates, `isPaused` is set, a
///   blocking overlay is up (`RCOverlayActivity`) or nobody has touched the
///   window for `idleTimeout`. Freezing stops layer time, so resuming
///   continues exactly where it stopped, and a frozen tree costs the render
///   server nothing.
/// - Reduce Motion, Low Power Mode and a serious thermal state show the same
///   composition, still (no animations attached at all).
/// - Size changes regenerate the composition under a short crossfade. During
///   a live resize (Stage Manager, Split View) only the first change rebuilds
///   immediately; later ones wait until the size has been stable for
///   `resizeSettleDelay`. Appearance changes swap colored contents in place.
@MainActor
final class RCAmbientBackgroundView: RCView {
    /// Stops all motion (layer time is frozen, nothing is removed).
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            updateMotion()
        }
    }

    /// 0...1 visual intensity of blooms and motes. The canvas and texture keep full strength.
    var intensity: CGFloat = 1 {
        didSet { applyIntensity() }
    }

    /// Time without a touch in the window after which motion freezes. Any
    /// touch resumes it after `motionStartDelay`.
    var idleTimeout: TimeInterval = RCAmbientBackgroundView.defaultIdleTimeout {
        didSet {
            guard idleTimeout != oldValue else { return }
            cancelIdleCheck()
            scheduleIdleCheck()
        }
    }

    /// Delay before motion starts after entering a window, activating, or unpausing.
    static let motionStartDelay: TimeInterval = 0.65
    static let relayoutCrossfadeDuration: CFTimeInterval = 0.2
    static let defaultIdleTimeout: TimeInterval = 30
    /// A live resize rebuilds once this long after the last size change.
    static let resizeSettleDelay: TimeInterval = 0.15

    /// Composition currently shown (nil until the first layout with a non-empty size).
    private(set) var composition: RCAmbientComposition?
    /// True while layer time is running.
    private(set) var isMotionRunning = false
    /// True after `idleTimeout` without a touch in the window.
    private(set) var isIdle = false

    private let gradientLayer = CAGradientLayer()
    private let bloomContainer = CALayer()
    private var bloomLayers: [CALayer] = []
    private let grainLayer = CAReplicatorLayer()
    private let grainRowLayer = CAReplicatorLayer()
    private let grainTileLayer = CALayer()
    private let gridLayer = CALayer()
    private let moteContainer = CALayer()
    private var moteLayers: [CALayer] = []

    private var isStartScheduled = false
    private var isSceneActive = false
    private var hasMotionAnimations = false
    private var motionEpoch: CFTimeInterval = 0
    private var appliedTone: RCAmbientArtwork.Tone?
    private var appliedGridSize: CGSize = .zero

    private var interactionMonitor: RCAmbientInteractionMonitor?
    /// Last moment that counts as activity besides touches (entering the window, activation).
    private var idleReference: CFTimeInterval = 0
    private var isIdleCheckScheduled = false

    private var lastResizeTime: CFTimeInterval = -.infinity
    private var isResizeSettleScheduled = false

    private enum Key {
        static let drift = "rc.ambient.drift"
        static let breathe = "rc.ambient.breathe"
        static let fade = "rc.ambient.fade"
        static let relayout = "rc.ambient.relayout"
    }

    override func setUp() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true

        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(gradientLayer)

        for container in [bloomContainer, moteContainer] {
            // Opacity multiplies into children instead of compositing the
            // group offscreen; blooms and motes barely overlap.
            container.allowsGroupOpacity = false
            // Time starts frozen at a non-zero origin so an animation
            // `beginTime` is never 0 (which Core Animation reads as "now").
            container.speed = 0
            container.timeOffset = 1
        }
        for _ in RCAmbientComposition.BloomRole.allCases {
            let bloom = CALayer()
            bloom.contentsGravity = .resize
            bloomContainer.addSublayer(bloom)
            bloomLayers.append(bloom)
        }
        layer.addSublayer(bloomContainer)

        // The grain's faintness is baked into the tile: opacity below 1 on a
        // layer with sublayers would composite the whole field offscreen.
        grainTileLayer.contentsGravity = .resize
        grainRowLayer.addSublayer(grainTileLayer)
        grainLayer.addSublayer(grainRowLayer)
        grainLayer.isHidden = true
        layer.addSublayer(grainLayer)

        // Baked at 1 px per point: nearest filtering keeps 1 pt lines crisp.
        // A leaf layer, so its opacity costs no offscreen pass.
        gridLayer.contentsGravity = .resize
        gridLayer.contentsScale = 1
        gridLayer.magnificationFilter = .nearest
        gridLayer.opacity = 0.18
        gridLayer.isHidden = true
        layer.addSublayer(gridLayer)

        layer.addSublayer(moteContainer)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sceneDidActivate(_:)), name: UIScene.didActivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(self, selector: #selector(motionConditionsDidChange), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(motionConditionsDidChange), name: RCAmbientSystemConditions.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(overlayActivityDidChange), name: RCOverlayActivity.didChangeNotification, object: nil)
        RCAmbientSystemConditions.shared.startObserving()
    }

    // MARK: Appearance

    private var tone: RCAmbientArtwork.Tone { RCAmbientArtwork.Tone(traitCollection) }

    override func updateAppearance() {
        withoutImplicitAnimations {
            gradientLayer.colors = [RCColor.backgroundDeep.cgColor(for: self), RCColor.background.cgColor(for: self)]
            applyContents(force: false)
        }
    }

    private func applyIntensity() {
        let value = Float(min(max(intensity, 0), 1))
        withoutImplicitAnimations {
            bloomContainer.opacity = value
            moteContainer.opacity = value
        }
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitAnimations {
            gradientLayer.frame = bounds
            bloomContainer.frame = bounds
            moteContainer.frame = bounds
            grainLayer.frame = bounds
        }
        let size = bounds.size
        guard size.width >= 1, size.height >= 1, composition?.size != size else { return }
        guard composition != nil, window != nil else {
            rebuild(for: size, crossfade: false)
            return
        }
        let now = CACurrentMediaTime()
        let isLiveResize = now - lastResizeTime < Self.resizeSettleDelay
        lastResizeTime = now
        if isLiveResize {
            // Keep the texture covering the canvas; everything else waits.
            withoutImplicitAnimations { layoutGrain(size: size) }
            scheduleResizeSettle(after: Self.resizeSettleDelay)
        } else {
            rebuild(for: size, crossfade: true)
        }
    }

    private func scheduleResizeSettle(after delay: TimeInterval) {
        guard !isResizeSettleScheduled else { return }
        isResizeSettleScheduled = true
        perform(#selector(settleResize), with: nil, afterDelay: delay, inModes: [.common])
    }

    /// Rebuilds once the size has stopped changing. Reschedules itself instead
    /// of being cancelled on every layout pass of a live resize.
    @objc private func settleResize() {
        isResizeSettleScheduled = false
        let remaining = lastResizeTime + Self.resizeSettleDelay - CACurrentMediaTime()
        if remaining > 0.001 {
            scheduleResizeSettle(after: remaining)
            return
        }
        let size = bounds.size
        guard size.width >= 1, size.height >= 1, composition?.size != size else { return }
        rebuild(for: size, crossfade: window != nil)
    }

    private func rebuild(for size: CGSize, crossfade: Bool) {
        if crossfade { addCrossfade() }
        let composition = RCAmbientComposition(size: size)
        self.composition = composition
        motionEpoch = RCLayerClock.localTime(of: moteContainer)
        withoutImplicitAnimations {
            layoutGrain(size: size)
            ensureMoteLayers(count: composition.motes.count)
            applyGeometry(composition)
            applyContents(force: true)
            removeMotionAnimations()
            if motionState != .still {
                addMotionAnimations(composition, epoch: motionEpoch)
            }
        }
        updateMotion()
    }

    private func addCrossfade() {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = Self.relayoutCrossfadeDuration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(transition, forKey: Key.relayout)
    }

    private func layoutGrain(size: CGSize) {
        let tile = RCAmbientArtwork.grainTilePointSize
        grainTileLayer.frame = CGRect(x: 0, y: 0, width: tile, height: tile)
        grainRowLayer.frame = CGRect(x: 0, y: 0, width: size.width, height: tile)
        grainRowLayer.instanceCount = max(1, Int(ceil(size.width / tile)))
        grainRowLayer.instanceTransform = CATransform3DMakeTranslation(tile, 0, 0)
        grainLayer.instanceCount = max(1, Int(ceil(size.height / tile)))
        grainLayer.instanceTransform = CATransform3DMakeTranslation(0, tile, 0)
    }

    private func ensureMoteLayers(count: Int) {
        while moteLayers.count < count {
            let mote = CALayer()
            mote.contentsGravity = .resize
            moteContainer.addSublayer(mote)
            moteLayers.append(mote)
        }
        while moteLayers.count > count {
            moteLayers.removeLast().removeFromSuperlayer()
        }
    }

    /// Model values are the still composition; animations, when present, override them.
    private func applyGeometry(_ composition: RCAmbientComposition) {
        for (bloom, bloomLayer) in zip(composition.blooms, bloomLayers) {
            bloomLayer.bounds = CGRect(x: 0, y: 0, width: bloom.radius.width * 2, height: bloom.radius.height * 2)
            bloomLayer.position = bloom.center
            bloomLayer.transform = CATransform3DIdentity
        }
        for (mote, moteLayer) in zip(composition.motes, moteLayers) {
            let side = mote.frameSide
            moteLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            moteLayer.position = mote.point(at: CGFloat(mote.phase))
            moteLayer.opacity = Float(RCAmbientComposition.fadeEnvelope(at: mote.phase) * mote.brightness)
            moteLayer.cornerRadius = mote.kind == .halo ? 0 : side / 2
        }
    }

    private func applyContents(force: Bool) {
        guard let composition else { return }
        let tone = self.tone
        let gridSize = CGSize(width: ceil(composition.size.width), height: ceil(composition.size.height))
        guard force || tone != appliedTone || (tone == .console && gridSize != appliedGridSize) else { return }
        appliedTone = tone

        for (bloom, bloomLayer) in zip(composition.blooms, bloomLayers) {
            let image = RCAmbientArtwork.bloomImage(bloom.role, tone: tone)
            bloomLayer.contents = image
            bloomLayer.isHidden = image == nil
        }

        grainLayer.isHidden = tone != .warm
        if tone == .warm {
            grainTileLayer.contents = RCAmbientArtwork.grainTile()
            grainTileLayer.contentsScale = RCAmbientArtwork.grainTileScale
        } else {
            grainTileLayer.contents = nil
        }
        gridLayer.isHidden = tone != .console
        if tone == .console {
            if let grid = RCAmbientArtwork.gridImage(size: gridSize, tone: tone) {
                gridLayer.contents = grid
                gridLayer.frame = CGRect(x: 0, y: 0, width: CGFloat(grid.width), height: CGFloat(grid.height))
            }
            appliedGridSize = gridSize
        } else {
            gridLayer.contents = nil
            appliedGridSize = .zero
        }

        let style = RCAmbientArtwork.moteStyle(tone: tone)
        let halo = RCAmbientArtwork.haloImage(tone: tone, scale: displayScale)
        for (mote, moteLayer) in zip(composition.motes, moteLayers) {
            switch mote.kind {
            case .dot:
                moteLayer.contents = nil
                moteLayer.borderWidth = 0
                moteLayer.backgroundColor = style.dot.cgColor
            case .ring:
                moteLayer.contents = nil
                moteLayer.backgroundColor = nil
                moteLayer.borderWidth = style.ringWidth
                moteLayer.borderColor = style.ring.cgColor
            case .halo:
                moteLayer.backgroundColor = nil
                moteLayer.borderWidth = 0
                moteLayer.contents = halo
            }
        }
    }

    private var displayScale: CGFloat {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
        return min(max(scale, 1), 3)
    }

    // MARK: Motion

    /// Inputs of the motion policy right now.
    var motionInputs: RCAmbientMotionPolicy.Inputs {
        let conditions = RCAmbientSystemConditions.shared
        return RCAmbientMotionPolicy.Inputs(
            isInWindow: window != nil,
            isSceneActive: isSceneActive,
            isPaused: isPaused,
            isOverlayActive: RCOverlayActivity.isActive,
            isIdle: isIdle,
            isLowPowerMode: conditions.isLowPowerMode,
            thermalState: conditions.thermalState,
            reduceMotion: RCMotion.reduceMotion
        )
    }

    var motionState: RCAmbientMotionPolicy.State {
        RCAmbientMotionPolicy.state(for: motionInputs)
    }

#if DEBUG
    /// Local time of the mote field (frozen while motion is stopped), for tests.
    var motionClockTime: CFTimeInterval { RCLayerClock.localTime(of: moteContainer) }
#endif

    override func didMoveToWindow() {
        super.didMoveToWindow()
        isSceneActive = Self.isActive(window)
        attachInteractionMonitor(to: window)
        if window != nil {
            resetIdleClock()
            ensureMotionAnimations()
        } else {
            cancelIdleCheck()
            isIdle = false
        }
        updateMotion()
    }

    private static func isActive(_ window: UIWindow?) -> Bool {
        guard let window else { return false }
        if let scene = window.windowScene {
            return scene.activationState == .foregroundActive
        }
        return UIApplication.shared.applicationState == .active
    }

    private func updateMotion() {
        let state = composition == nil ? .frozen : motionState
        syncMotionAnimations(still: state == .still)
        if state == .running {
            guard !isMotionRunning, !isStartScheduled else { return }
            isStartScheduled = true
            perform(#selector(startScheduledMotion), with: nil, afterDelay: Self.motionStartDelay, inModes: [.common])
        } else {
            cancelScheduledStart()
            guard isMotionRunning else { return }
            isMotionRunning = false
            RCLayerClock.freeze(bloomContainer)
            RCLayerClock.freeze(moteContainer)
        }
    }

    @objc private func startScheduledMotion() {
        isStartScheduled = false
        guard composition != nil, motionState == .running, !isMotionRunning else { return }
        ensureMotionAnimations()
        isMotionRunning = true
        RCLayerClock.resume(bloomContainer)
        RCLayerClock.resume(moteContainer)
    }

    private func cancelScheduledStart() {
        guard isStartScheduled else { return }
        isStartScheduled = false
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(startScheduledMotion), object: nil)
    }

    /// Attaches or detaches the animations when the still (static) state
    /// flips, under the relayout crossfade. Detaching leaves the model
    /// values, which are the still composition.
    private func syncMotionAnimations(still: Bool) {
        guard let composition, still == hasMotionAnimations else { return }
        if window != nil { addCrossfade() }
        withoutImplicitAnimations {
            removeMotionAnimations()
            if !still {
                // Layer time is frozen here, so a new epoch starts each field at its seeded phase.
                motionEpoch = RCLayerClock.localTime(of: moteContainer)
                addMotionAnimations(composition, epoch: motionEpoch)
            }
        }
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        isSceneActive = true
        resetIdleClock()
        ensureMotionAnimations()
        updateMotion()
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        isSceneActive = false
        updateMotion()
    }

    @objc private func motionConditionsDidChange() {
        updateMotion()
    }

    @objc private func overlayActivityDidChange() {
        // Overlays are almost always dismissed by the user: count it as activity.
        if !RCOverlayActivity.isActive, window != nil { resetIdleClock() }
        updateMotion()
    }

    /// Re-adds animations the system dropped (e.g. across backgrounding) with
    /// the original epoch, so the field continues from the same state.
    private func ensureMotionAnimations() {
        guard let composition, hasMotionAnimations else { return }
        let missing = moteLayers.contains { $0.animation(forKey: Key.drift) == nil }
            || bloomLayers.contains { $0.animation(forKey: Key.drift) == nil }
        guard missing else { return }
        withoutImplicitAnimations {
            removeMotionAnimations()
            addMotionAnimations(composition, epoch: motionEpoch)
        }
    }

    private func removeMotionAnimations() {
        hasMotionAnimations = false
        for sublayer in bloomLayers + moteLayers {
            sublayer.removeAnimation(forKey: Key.drift)
            sublayer.removeAnimation(forKey: Key.breathe)
            sublayer.removeAnimation(forKey: Key.fade)
        }
    }

    private func addMotionAnimations(_ composition: RCAmbientComposition, epoch: CFTimeInterval) {
        hasMotionAnimations = true
        for (bloom, bloomLayer) in zip(composition.blooms, bloomLayers) {
            let drift = CAKeyframeAnimation(keyPath: "position")
            drift.values = bloom.driftLoop().map { NSValue(cgPoint: $0) }
            drift.calculationMode = .cubic
            configureRepeating(drift, duration: bloom.driftDuration, phase: bloom.phase, epoch: epoch)
            bloomLayer.add(drift, forKey: Key.drift)

            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 1
            breathe.toValue = bloom.breatheScale
            breathe.autoreverses = true
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            configureRepeating(breathe, duration: bloom.breatheDuration, phase: bloom.phase, epoch: epoch)
            // Autoreversing animations span two durations per cycle.
            breathe.timeOffset = bloom.phase * bloom.breatheDuration * 2
            bloomLayer.add(breathe, forKey: Key.breathe)
        }
        for (mote, moteLayer) in zip(composition.motes, moteLayers) {
            let drift = CAKeyframeAnimation(keyPath: "position")
            drift.path = mote.path()
            drift.calculationMode = .paced
            configureRepeating(drift, duration: mote.duration, phase: mote.phase, epoch: epoch)
            moteLayer.add(drift, forKey: Key.drift)

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = RCAmbientComposition.fadeEnvelopeValues.map { NSNumber(value: Double($0 * mote.brightness)) }
            fade.keyTimes = RCAmbientComposition.fadeKeyTimes.map { NSNumber(value: $0) }
            configureRepeating(fade, duration: mote.duration, phase: mote.phase, epoch: epoch)
            moteLayer.add(fade, forKey: Key.fade)
        }
    }

    private func configureRepeating(_ animation: CAAnimation, duration: Double, phase: Double, epoch: CFTimeInterval) {
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.beginTime = epoch
        animation.timeOffset = phase * duration
        animation.isRemovedOnCompletion = false
        if #available(iOS 15.0, *) {
            // Blooms and motes move a few points per second: a low frame rate
            // is indistinguishable and lets the display idle between frames.
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 20, preferred: 15)
        }
    }

    // MARK: Idle

    private func attachInteractionMonitor(to window: UIWindow?) {
        if let monitor = interactionMonitor, monitor.view !== window || window == nil {
            monitor.remove(self)
            interactionMonitor = nil
        }
        guard let window, interactionMonitor == nil else { return }
        let monitor = RCAmbientInteractionMonitor.monitor(for: window)
        monitor.add(self)
        interactionMonitor = monitor
    }

    private var lastActivity: CFTimeInterval {
        max(idleReference, interactionMonitor?.lastInteraction ?? 0)
    }

    private func resetIdleClock() {
        idleReference = CACurrentMediaTime()
        setIdle(false)
        scheduleIdleCheck()
    }

    /// Called by the window's interaction monitor for every touch that begins.
    fileprivate func windowDidReceiveInteraction() {
        setIdle(false)
        scheduleIdleCheck()
    }

    private func setIdle(_ idle: Bool) {
        guard idle != isIdle else { return }
        isIdle = idle
        updateMotion()
    }

    /// One pending check at a time: touches only move `lastActivity`, and the
    /// check re-arms itself for the remainder instead of being rescheduled
    /// on every touch.
    private func scheduleIdleCheck() {
        guard window != nil, !isIdle, !isIdleCheckScheduled else { return }
        isIdleCheckScheduled = true
        let remaining = lastActivity + idleTimeout - CACurrentMediaTime()
        perform(#selector(idleCheck), with: nil, afterDelay: max(remaining, 0.01), inModes: [.common])
    }

    private func cancelIdleCheck() {
        guard isIdleCheckScheduled else { return }
        isIdleCheckScheduled = false
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(idleCheck), object: nil)
    }

    @objc private func idleCheck() {
        isIdleCheckScheduled = false
        guard window != nil else { return }
        if CACurrentMediaTime() - lastActivity >= idleTimeout - 0.005 {
            setIdle(true)
        } else {
            scheduleIdleCheck()
        }
    }

    /// Number of layers this view owns (for budget checks).
    var layerCount: Int {
        func count(_ layer: CALayer) -> Int {
            (layer.sublayers ?? []).reduce(1) { $0 + count($1) }
        }
        return count(layer) - 1
    }
}

// MARK: - Motion policy

/// When the ambient backdrop animates. Pure, so every combination is testable.
enum RCAmbientMotionPolicy {
    enum State: Equatable, Sendable {
        /// Layer time runs.
        case running
        /// Animations stay attached with layer time stopped; resuming continues seamlessly.
        case frozen
        /// The still composition with no animations attached (static).
        case still
    }

    struct Inputs: Equatable, Sendable {
        var isInWindow: Bool
        var isSceneActive: Bool
        var isPaused: Bool
        var isOverlayActive: Bool
        var isIdle: Bool
        var isLowPowerMode: Bool
        var thermalState: ProcessInfo.ThermalState
        var reduceMotion: Bool
    }

    static func state(for inputs: Inputs) -> State {
        let thermallyConstrained = switch inputs.thermalState {
        case .serious, .critical: true
        default: false
        }
        if inputs.reduceMotion || inputs.isLowPowerMode || thermallyConstrained {
            return .still
        }
        let visible = inputs.isInWindow && inputs.isSceneActive
        let unobstructed = !inputs.isPaused && !inputs.isOverlayActive && !inputs.isIdle
        return visible && unobstructed ? .running : .frozen
    }
}

/// Process-wide Low Power Mode and thermal state, republished on the main
/// thread (the system posts these notifications on arbitrary threads).
@MainActor
final class RCAmbientSystemConditions {
    static let shared = RCAmbientSystemConditions()
    static let didChangeNotification = Notification.Name("RCAmbientSystemConditionsDidChange")

    private(set) var isLowPowerMode: Bool
    private(set) var thermalState: ProcessInfo.ThermalState
    private var isObserving = false

    private init() {
        let info = ProcessInfo.processInfo
        isLowPowerMode = info.isLowPowerModeEnabled
        thermalState = info.thermalState
    }

    /// Starts observing (idempotent). Observers live as long as the process.
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RCAmbientSystemConditions.shared.refresh() }
            }
        }
        refresh()
    }

    private func refresh() {
        let info = ProcessInfo.processInfo
        let lowPower = info.isLowPowerModeEnabled
        let thermal = info.thermalState
        guard lowPower != isLowPowerMode || thermal != thermalState else { return }
        isLowPowerMode = lowPower
        thermalState = thermal
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

/// Passive touch observer installed on a window while ambient backdrops are
/// in it (one per window, shared). It never recognizes, never delays or
/// cancels touches, recognizes simultaneously with everything and cannot
/// prevent or be prevented: it only notes that a touch began, then fails.
@MainActor
final class RCAmbientInteractionMonitor: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private(set) var lastInteraction: CFTimeInterval
    private let clients = NSHashTable<RCAmbientBackgroundView>.weakObjects()

    private init() {
        lastInteraction = CACurrentMediaTime()
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
        delegate = self
        name = "rc.ambient.interaction"
    }

    /// The window's shared monitor, installed on first use.
    static func monitor(for window: UIWindow) -> RCAmbientInteractionMonitor {
        if let existing = installed(on: window) { return existing }
        let monitor = RCAmbientInteractionMonitor()
        window.addGestureRecognizer(monitor)
        return monitor
    }

    static func installed(on window: UIWindow) -> RCAmbientInteractionMonitor? {
        window.gestureRecognizers?.lazy.compactMap { $0 as? RCAmbientInteractionMonitor }.first
    }

    func add(_ client: RCAmbientBackgroundView) {
        clients.add(client)
    }

    /// Removes the client; the last one takes the monitor off its window.
    func remove(_ client: RCAmbientBackgroundView) {
        clients.remove(client)
        if clients.allObjects.isEmpty {
            view?.removeGestureRecognizer(self)
        }
    }

    /// Marks activity now and wakes idle backdrops.
    func recordInteraction() {
        lastInteraction = CACurrentMediaTime()
        for client in clients.allObjects {
            client.windowDidReceiveInteraction()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        recordInteraction()
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - Layer clock

/// Pauses and resumes a layer's local time without discontinuity (Apple QA1673).
@MainActor
enum RCLayerClock {
    static func localTime(of layer: CALayer) -> CFTimeInterval {
        layer.convertTime(CACurrentMediaTime(), from: nil)
    }

    static func freeze(_ layer: CALayer) {
        guard layer.speed != 0 else { return }
        let now = localTime(of: layer)
        layer.speed = 0
        layer.timeOffset = now
    }

    static func resume(_ layer: CALayer) {
        guard layer.speed == 0 else { return }
        let frozen = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = localTime(of: layer) - frozen
    }
}

// MARK: - Composition

/// Deterministic layout of blooms and motes for a canvas size. Pure value
/// type: the same size and seed always give the same field, and positions are
/// proportional, so a rotated screen keeps its character.
struct RCAmbientComposition: Equatable, Sendable {
    enum BloomRole: Int, CaseIterable, Sendable {
        /// Terracotta (Warm) / amber (Console), top trailing.
        case signal
        /// Sage / green, top leading.
        case online
        /// Warm accent glow from the bottom (Warm only).
        case warmth
    }

    struct Bloom: Equatable, Sendable {
        var role: BloomRole
        var center: CGPoint
        var radius: CGSize
        /// Amplitude of the figure-eight drift around `center`.
        var drift: CGSize
        var driftDuration: Double
        var breatheScale: CGFloat
        /// Half a breathing cycle (the animation autoreverses).
        var breatheDuration: Double
        /// 0..<1 start position within the cycles.
        var phase: Double

        /// Closed drift loop sampled for a cubic keyframe animation.
        func driftLoop(samples: Int = 12) -> [CGPoint] {
            (0...samples).map { index in
                let angle = Double(index) / Double(samples) * 2 * .pi
                return CGPoint(
                    x: center.x + drift.width * CGFloat(sin(angle)),
                    y: center.y + drift.height * CGFloat(sin(2 * angle + 0.9))
                )
            }
        }
    }

    enum MoteKind: Equatable, Sendable {
        case dot
        /// Warm-tinted core with a soft glow.
        case halo
        /// Thin outline.
        case ring
    }

    struct Mote: Equatable, Sendable {
        var kind: MoteKind
        /// Visible core diameter in points.
        var diameter: CGFloat
        /// Cubic path that enters and leaves outside the canvas.
        var start: CGPoint
        var control1: CGPoint
        var control2: CGPoint
        var end: CGPoint
        var duration: Double
        var phase: Double
        var brightness: CGFloat

        /// Layer side: halos include their glow.
        var frameSide: CGFloat {
            kind == .halo ? diameter * RCAmbientComposition.haloScale : diameter
        }

        func point(at t: CGFloat) -> CGPoint {
            let u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(
                x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                y: a * start.y + b * control1.y + c * control2.y + d * end.y
            )
        }

        func path() -> CGPath {
            let path = CGMutablePath()
            path.move(to: start)
            path.addCurve(to: end, control1: control1, control2: control2)
            return path
        }
    }

    static let defaultSeed: UInt64 = 0x5243_544C_4D4F_5445
    static let minimumMotes = 8
    static let maximumMotes = 28
    /// Halo layer side relative to its core diameter.
    static let haloScale: CGFloat = 5.5
    /// Motes travel between points this far outside the canvas.
    static let travelMargin: CGFloat = 28
    /// Opacity envelope over one traversal: fade in, hold, fade out.
    static let fadeKeyTimes: [Double] = [0, 0.1, 0.9, 1]
    static let fadeEnvelopeValues: [CGFloat] = [0, 1, 1, 0]

    let size: CGSize
    let blooms: [Bloom]
    let motes: [Mote]

    /// Sparse on every screen: about one mote per 13,500 pt², 8...28.
    static func moteCount(for size: CGSize) -> Int {
        let area = max(0, size.width) * max(0, size.height)
        return min(maximumMotes, max(minimumMotes, Int((area / 13_500).rounded())))
    }

    static func fadeEnvelope(at phase: Double) -> CGFloat {
        let t = phase - floor(phase)
        for index in 1..<fadeKeyTimes.count where t <= fadeKeyTimes[index] {
            let t0 = fadeKeyTimes[index - 1], t1 = fadeKeyTimes[index]
            let f = CGFloat((t - t0) / max(t1 - t0, .ulpOfOne))
            return fadeEnvelopeValues[index - 1] + (fadeEnvelopeValues[index] - fadeEnvelopeValues[index - 1]) * f
        }
        return 0
    }

    init(size: CGSize, seed: UInt64 = RCAmbientComposition.defaultSeed) {
        self.size = size
        var random = RCSplitMix64(seed: seed)
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        // Rotation-invariant reference so blooms keep their size when turned.
        let reference = (width * height).squareRoot()
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(value, low), high) }

        let signalRadius = clamp(reference * 0.66, 260, 700)
        let onlineRadius = clamp(reference * 0.56, 220, 600)
        let warmthRadius = clamp(reference * 0.62, 240, 660)
        blooms = [
            Bloom(
                role: .signal,
                center: CGPoint(x: width * 0.82, y: -height * 0.05),
                radius: CGSize(width: signalRadius, height: signalRadius * 0.8),
                drift: CGSize(width: signalRadius * 0.07, height: signalRadius * 0.8 * 0.06),
                driftDuration: 34, breatheScale: 1.1, breatheDuration: 13,
                phase: random.nextDouble()
            ),
            Bloom(
                role: .online,
                center: CGPoint(x: width * 0.05, y: height * 0.05),
                radius: CGSize(width: onlineRadius, height: onlineRadius * 0.84),
                drift: CGSize(width: onlineRadius * 0.08, height: onlineRadius * 0.84 * 0.07),
                driftDuration: 29, breatheScale: 0.92, breatheDuration: 17,
                phase: random.nextDouble()
            ),
            Bloom(
                role: .warmth,
                center: CGPoint(x: width * 0.34, y: height * 1.03),
                radius: CGSize(width: warmthRadius, height: warmthRadius * 0.7),
                drift: CGSize(width: warmthRadius * 0.07, height: warmthRadius * 0.7 * 0.06),
                driftDuration: 38, breatheScale: 1.12, breatheDuration: 21,
                phase: random.nextDouble()
            ),
        ]

        let canvas = CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: -Self.travelMargin, dy: -Self.travelMargin)
        motes = (0..<Self.moteCount(for: size)).map { index in
            let kind: MoteKind = index % 6 == 1 ? .halo : (index % 7 == 4 ? .ring : .dot)
            let sizeRoll = CGFloat(random.nextDouble())
            let diameter: CGFloat = switch kind {
            case .dot: 1.5 + 2.0 * sizeRoll
            case .halo: 2.4 + 1.4 * sizeRoll
            case .ring: 3.0 + 1.0 * sizeRoll
            }
            let origin = CGPoint(x: CGFloat(random.nextDouble()) * width, y: CGFloat(random.nextDouble()) * height)
            let sideways = random.nextDouble() < 0.18
            let sideRoll = random.nextDouble()
            let spread = random.nextDouble() - 0.5
            // Mostly rising, a few drifting sideways.
            let angle = sideways ? (sideRoll < 0.5 ? 0 : Double.pi) + spread * 0.7 : -Double.pi / 2 + spread * 2.1
            let speed = (3.5 + 5.5 * random.nextDouble()) * (kind == .halo ? 0.75 : 1)
            let sway = CGFloat(6 + 20 * random.nextDouble())
            let swayBalance = CGFloat(0.6 + 0.4 * random.nextDouble())
            let brightness = CGFloat(0.45 + 0.55 * random.nextDouble())
            let phase = random.nextDouble()

            let direction = CGVector(dx: cos(angle), dy: sin(angle))
            let (entry, exit) = Self.crossing(of: canvas, through: origin, direction: direction)
            let dx = exit.x - entry.x, dy = exit.y - entry.y
            let length = max((dx * dx + dy * dy).squareRoot(), 1)
            let normal = CGVector(dx: -dy / length, dy: dx / length)
            return Mote(
                kind: kind,
                diameter: diameter,
                start: entry,
                control1: CGPoint(x: entry.x + dx / 3 + normal.dx * sway, y: entry.y + dy / 3 + normal.dy * sway),
                control2: CGPoint(x: entry.x + dx * 2 / 3 - normal.dx * sway * swayBalance, y: entry.y + dy * 2 / 3 - normal.dy * sway * swayBalance),
                end: exit,
                duration: max(24, Double(length) / speed),
                phase: phase,
                brightness: brightness
            )
        }
    }

    /// Where a line through `point` (inside `rect`) enters and leaves `rect`.
    static func crossing(of rect: CGRect, through point: CGPoint, direction: CGVector) -> (CGPoint, CGPoint) {
        var tMin = -CGFloat.greatestFiniteMagnitude
        var tMax = CGFloat.greatestFiniteMagnitude
        for (origin, delta, low, high) in [(point.x, direction.dx, rect.minX, rect.maxX), (point.y, direction.dy, rect.minY, rect.maxY)] {
            guard abs(delta) > 1e-6 else { continue }
            let t1 = (low - origin) / delta
            let t2 = (high - origin) / delta
            tMin = max(tMin, min(t1, t2))
            tMax = min(tMax, max(t1, t2))
        }
        return (
            CGPoint(x: point.x + direction.dx * tMin, y: point.y + direction.dy * tMin),
            CGPoint(x: point.x + direction.dx * tMax, y: point.y + direction.dy * tMax)
        )
    }
}

/// Small deterministic generator (SplitMix64) for seeded compositions and textures.
struct RCSplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}


// MARK: - Artwork

/// Bitmaps behind the ambient backdrop, rendered once and cached. Colors are
/// resolved from `RCColor` for the tone, never hard-coded. The cache is
/// bounded (grids, the only size-dependent bitmaps, keep the two most recent
/// sizes) and purged on memory warnings; layers keep what they display.
@MainActor
enum RCAmbientArtwork {
    enum Tone: Hashable, Sendable {
        case warm, console

        init(_ traits: UITraitCollection) {
            self = traits.userInterfaceStyle == .dark ? .console : .warm
        }

        var traits: UITraitCollection {
            UITraitCollection(userInterfaceStyle: self == .console ? .dark : .light)
        }
    }

    struct MoteStyle {
        let dot: UIColor
        let ring: UIColor
        let ringWidth: CGFloat
    }

    static let grainTilePointSize: CGFloat = 128
    static let grainTileScale: CGFloat = 2
    /// Strength of the Warm paper grain, baked into the tile's alpha.
    static let grainOpacity: Double = 0.05
    static let gridSpacing: CGFloat = 46
    /// Grid bitmaps kept (full canvas width at 1 px per point).
    static let gridCacheLimit = 2

    private struct BloomKey: Hashable {
        let role: RCAmbientComposition.BloomRole
        let tone: Tone
    }

    private struct HaloKey: Hashable {
        let tone: Tone
        let scale: CGFloat
    }

    private struct GridKey: Hashable {
        let size: CGSize
        let tone: Tone

        func hash(into hasher: inout Hasher) {
            hasher.combine(size.width)
            hasher.combine(size.height)
            hasher.combine(tone)
        }
    }

    private static var blooms: [BloomKey: CGImage] = [:]
    private static var halos: [HaloKey: CGImage] = [:]
    /// Most recently used last.
    private static var grids: [(key: GridKey, image: CGImage)] = []
    private static var grain: CGImage?
    private static var memoryWarningObserver: NSObjectProtocol?

    /// Number of cached bitmaps (for tests).
    static var cachedImageCount: Int {
        blooms.count + halos.count + grids.count + (grain == nil ? 0 : 1)
    }

    /// Drops every cached bitmap. Layers keep the images they display.
    static func purgeCaches() {
        blooms.removeAll()
        halos.removeAll()
        grids.removeAll()
        grain = nil
    }

    private static func observeMemoryWarnings() {
        guard memoryWarningObserver == nil else { return }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { RCAmbientArtwork.purgeCaches() }
        }
    }

    /// Bloom color and peak opacity (web `body::before`); nil when the tone has no such bloom.
    static func bloomTint(_ role: RCAmbientComposition.BloomRole, tone: Tone) -> (color: UIColor, alpha: CGFloat)? {
        let traits = tone.traits
        switch (role, tone) {
        case (.signal, .warm): return (RCColor.accent.resolvedColor(with: traits), 0.13)
        case (.online, .warm): return (RCColor.success.resolvedColor(with: traits), 0.075)
        case (.warmth, .warm): return (RCColor.accentHigh.resolvedColor(with: traits), 0.06)
        case (.signal, .console): return (RCColor.accent.resolvedColor(with: traits), 0.11)
        case (.online, .console): return (RCColor.success.resolvedColor(with: traits), 0.05)
        case (.warmth, .console): return nil
        }
    }

    static func moteStyle(tone: Tone) -> MoteStyle {
        let traits = tone.traits
        switch tone {
        case .warm:
            return MoteStyle(
                dot: RCColor.textTertiary.resolvedColor(with: traits).withAlphaComponent(0.8),
                ring: RCColor.textTertiary.resolvedColor(with: traits).withAlphaComponent(0.65),
                ringWidth: 0.75
            )
        case .console:
            return MoteStyle(
                dot: RCColor.textTertiary.resolvedColor(with: traits).withAlphaComponent(0.55),
                ring: RCColor.textTertiary.resolvedColor(with: traits).withAlphaComponent(0.45),
                ringWidth: 0.75
            )
        }
    }

    /// Circular soft falloff with the bloom's tint baked in; stretched to the
    /// bloom's ellipse. Dithered so an 8-bit ramp this faint never bands.
    static func bloomImage(_ role: RCAmbientComposition.BloomRole, tone: Tone) -> CGImage? {
        let key = BloomKey(role: role, tone: tone)
        if let cached = blooms[key] { return cached }
        guard let tint = bloomTint(role, tone: tone) else { return nil }
        observeMemoryWarnings()
        let side = 256
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        tint.color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let peak = Double(tint.alpha) * 255
        let channels = (Double(red), Double(green), Double(blue))
        var random = RCSplitMix64(seed: 0xB1_00_00 &+ UInt64(role.rawValue))
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        bytes.withUnsafeMutableBufferPointer { buffer in
            for y in 0..<side {
                let dy = (Double(y) + 0.5) / Double(side) * 2 - 1
                for x in 0..<side {
                    let dx = (Double(x) + 0.5) / Double(side) * 2 - 1
                    let dither = random.nextDouble() - 0.5
                    let r2 = dx * dx + dy * dy
                    guard r2 < 1 else { continue }
                    let falloff = (1 - r2) * (1 - r2)
                    let value = Int((peak * falloff + dither).rounded())
                    guard value > 0 else { continue }
                    let a = Double(min(value, 255))
                    let index = (y * side + x) * 4
                    buffer[index] = UInt8(channels.0 * a + 0.5)
                    buffer[index + 1] = UInt8(channels.1 * a + 0.5)
                    buffer[index + 2] = UInt8(channels.2 * a + 0.5)
                    buffer[index + 3] = UInt8(a)
                }
            }
        }
        let image = makeImage(bytes, width: side, height: side)
        blooms[key] = image
        return image
    }

    /// Mote with a glow; the core occupies `1 / haloScale` of the side.
    static func haloImage(tone: Tone, scale: CGFloat) -> CGImage? {
        let key = HaloKey(tone: tone, scale: scale)
        if let cached = halos[key] { return cached }
        observeMemoryWarnings()
        let side: CGFloat = 24
        let traits = tone.traits
        let color = tone == .warm
            ? RCColor.accent.resolvedColor(with: traits)
            : RCColor.textSecondary.resolvedColor(with: traits)
        let glow: CGFloat = tone == .warm ? 0.42 : 0.24
        let coreAlpha: CGFloat = tone == .warm ? 0.82 : 0.66
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let cg = context.cgContext
            let center = CGPoint(x: side / 2, y: side / 2)
            let colors = [color.withAlphaComponent(glow).cgColor, color.withAlphaComponent(glow * 0.45).cgColor, color.withAlphaComponent(glow * 0.12).cgColor, color.withAlphaComponent(0).cgColor] as CFArray
            if let space = CGColorSpace(name: CGColorSpace.sRGB),
               let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.28, 0.62, 1]) {
                cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: side / 2, options: [])
            }
            let coreRadius = side / RCAmbientComposition.haloScale / 2
            cg.setFillColor(color.withAlphaComponent(coreAlpha).cgColor)
            cg.fillEllipse(in: CGRect(x: center.x - coreRadius, y: center.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2))
        }.cgImage
        halos[key] = image
        return image
    }

    /// Ink-tinted monochrome noise tile (fixed seed) for the Warm paper grain,
    /// with `grainOpacity` baked in. Alpha this faint is quantized with
    /// stochastic rounding (from bits the speck roll does not use), so the
    /// field keeps the exact average strength of a 5% layer and the same
    /// speck pattern.
    static func grainTile() -> CGImage? {
        if let grain { return grain }
        observeMemoryWarnings()
        let side = Int(grainTilePointSize * grainTileScale)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        RCColor.text.resolvedColor(with: Tone.warm.traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        var random = RCSplitMix64(seed: 0x6752_4149_4E)
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        bytes.withUnsafeMutableBufferPointer { buffer in
            for pixel in 0..<(side * side) {
                let value = random.next()
                let roll = Int(value >> 56)
                // Skewed toward faint specks with occasional darker fibers.
                let strength = Double((roll * roll) >> 8) * grainOpacity
                let threshold = Double((value >> 24) & 0xFFFF) / 65_536
                let a = min(floor(strength) + (strength - floor(strength) > threshold ? 1 : 0), 255)
                guard a > 0 else { continue }
                let index = pixel * 4
                buffer[index] = UInt8(Double(red) * a + 0.5)
                buffer[index + 1] = UInt8(Double(green) * a + 0.5)
                buffer[index + 2] = UInt8(Double(blue) * a + 0.5)
                buffer[index + 3] = UInt8(a)
            }
        }
        grain = makeImage(bytes, width: side, height: side)
        return grain
    }

    /// The web console grid (`body::after`): 1 pt `line` rules every 46 pt,
    /// radially faded from above the top center. Rendered at 1 px per point
    /// and only as tall as the fade reaches.
    ///
    /// Not tiled from a small pattern: the fade is radial (not separable per
    /// line), and applying it over a tiled pattern would need a mask or group
    /// compositing, i.e. an offscreen pass every frame instead of one bitmap
    /// per size. Live resizes regenerate it only once the size settles.
    static func gridImage(size: CGSize, tone: Tone) -> CGImage? {
        let key = GridKey(size: size, tone: tone)
        if let index = grids.firstIndex(where: { $0.key == key }) {
            let entry = grids.remove(at: index)
            grids.append(entry)
            return entry.image
        }
        let fadeCenter = CGPoint(x: size.width / 2, y: -size.height * 0.1)
        let radiusX = max(size.width * 0.95, 460)
        let radiusY = min(max(size.height * 0.7, 440), 700)
        let width = Int(ceil(size.width))
        let height = Int(ceil(min(size.height, fadeCenter.y + radiusY)))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        observeMemoryWarnings()
        // Top-left origin.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(RCColor.line.resolvedColor(with: tone.traits).cgColor)
        var x: CGFloat = 0
        while x < CGFloat(width) {
            context.fill(CGRect(x: x, y: 0, width: 1, height: CGFloat(height)))
            x += gridSpacing
        }
        var y: CGFloat = 0
        while y < CGFloat(height) {
            context.fill(CGRect(x: 0, y: y, width: CGFloat(width), height: 1))
            y += gridSpacing
        }
        context.setBlendMode(.destinationIn)
        context.translateBy(x: fadeCenter.x, y: fadeCenter.y)
        context.scaleBy(x: 1, y: radiusY / radiusX)
        let colors = [UIColor(white: 0, alpha: 1).cgColor, UIColor(white: 0, alpha: 0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radiusX, options: [.drawsAfterEndLocation])
        }
        guard let image = context.makeImage() else { return nil }
        grids.append((key, image))
        if grids.count > gridCacheLimit { grids.removeFirst(grids.count - gridCacheLimit) }
        return image
    }

    private static func makeImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
