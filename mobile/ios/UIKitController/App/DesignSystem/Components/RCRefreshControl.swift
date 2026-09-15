import UIKit

/// Pull-to-refresh state machine, free of UIKit so it can be unit-tested.
///
/// Inputs are the pull distance past the resting offset (positive when content
/// is pulled down) and whether the user's finger is dragging. Outputs are
/// effects the view applies. Invariants:
/// - Only a drag arms a refresh; momentum or bounce past the threshold never does.
/// - The threshold haptic plays once per upward crossing, with hysteresis so
///   jitter at the boundary cannot repeat it.
/// - A refresh starts on release while armed and holds a top inset until it
///   finishes; if the finger is still down when it finishes, the inset is
///   released only on release.
struct RCRefreshStateMachine: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        /// Dragging, below the threshold.
        case pulling
        /// Dragging, past the threshold: releasing starts a refresh.
        case armed
        case refreshing
        /// Refresh finished while the user was still dragging; the held inset
        /// is released when the drag ends.
        case finishing
    }

    enum Effect: Equatable, Sendable {
        /// Pull passed the threshold during a drag.
        case thresholdHaptic
        /// Hold the refreshing inset. `animated` is false when applied at
        /// release (the scroll view's own bounce settles onto it).
        case holdInset(animated: Bool)
        case releaseInset
        /// Start the refresh work and show the spinner.
        case startRefresh
        /// Stop the spinner and fade the indicator out.
        case stopIndicator
    }

    var threshold: CGFloat
    /// Distance below the threshold the pull must fall back to before it disarms.
    var hysteresis: CGFloat

    private(set) var phase: Phase = .idle
    /// Last pull distance seen (points, may be negative).
    private(set) var pull: CGFloat = 0

    init(threshold: CGFloat = 72, hysteresis: CGFloat = 10) {
        self.threshold = threshold
        self.hysteresis = hysteresis
    }

    var isRefreshing: Bool { phase == .refreshing }

    /// True while the refreshing inset is applied to the scroll view.
    var holdsInset: Bool { phase == .refreshing || phase == .finishing }

    /// 0...1 pull progress toward the threshold (1 while refreshing).
    var progress: CGFloat {
        if phase == .refreshing { return 1 }
        guard threshold > 0 else { return 0 }
        return min(max(pull / threshold, 0), 1)
    }

    mutating func scrolled(pull: CGFloat, isDragging: Bool) -> [Effect] {
        self.pull = pull
        switch phase {
        case .idle, .pulling, .armed:
            guard isDragging else {
                phase = .idle
                return []
            }
            if phase == .armed {
                if pull < threshold - hysteresis { phase = .pulling }
                return []
            }
            if pull >= threshold {
                phase = .armed
                return [.thresholdHaptic]
            }
            phase = pull > 0 ? .pulling : .idle
            return []
        case .refreshing, .finishing:
            return []
        }
    }

    mutating func endDragging(pull: CGFloat) -> [Effect] {
        self.pull = pull
        switch phase {
        case .armed:
            phase = .refreshing
            return [.holdInset(animated: false), .startRefresh]
        case .pulling, .idle:
            phase = .idle
            return []
        case .refreshing:
            return []
        case .finishing:
            phase = .idle
            return [.releaseInset]
        }
    }

    /// Programmatic start (no drag).
    mutating func begin() -> [Effect] {
        switch phase {
        case .idle, .pulling, .armed:
            phase = .refreshing
            return [.holdInset(animated: true), .startRefresh]
        case .finishing:
            // Inset is still held from the previous refresh.
            phase = .refreshing
            return [.startRefresh]
        case .refreshing:
            return []
        }
    }

    mutating func finish(isDragging: Bool) -> [Effect] {
        guard phase == .refreshing else { return [] }
        if isDragging {
            phase = .finishing
            return [.stopIndicator]
        }
        phase = .idle
        return [.stopIndicator, .releaseInset]
    }
}

/// Custom pull-to-refresh for a `UIScrollView`. It installs itself behind the
/// scroll view's content; the owner forwards two delegate callbacks:
///
/// ```swift
/// func scrollViewDidScroll(_ scrollView: UIScrollView) { refresh.scrollViewDidScroll() }
/// func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
///                                targetContentOffset: UnsafeMutablePointer<CGPoint>) {
///     refresh.scrollViewWillEndDragging()
/// }
/// ```
///
/// An accent ring fills with the pull and completes at `threshold` (light
/// haptic once); releasing there holds an inset, shows a spinner and runs
/// `onRefresh`, then the inset animates back. Insets are applied additively to
/// `contentInset`, so both `contentInsetAdjustmentBehavior` `.automatic` and
/// `.never` keep their own insets; an owner that re-assigns the same base
/// `contentInset.top` in every layout pass keeps working (the held gap is
/// restored on the next scroll callback). Scroll updates only move the
/// indicator and set layer properties.
@MainActor
final class RCRefreshControl: RCView {
    /// Pull distance that triggers a refresh on release.
    var threshold: CGFloat {
        get { machine.threshold }
        set { machine.threshold = max(1, newValue) }
    }

    /// Height of the gap held open above content while refreshing.
    var refreshingHeight: CGFloat = 56

    /// Distance from the scroll view's top edge to where the revealed gap
    /// begins, e.g. a custom top bar's height. `nil` uses the resting top
    /// content inset (the content's own resting top edge).
    var topOffset: CGFloat? {
        didSet { scrollViewDidScroll() }
    }

    var isRefreshing: Bool { machine.isRefreshing }

    private weak var scrollView: UIScrollView?
    private let onRefresh: @MainActor () async -> Void
    private var machine = RCRefreshStateMachine()
    private let indicator = UIView()
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private let spinner = RCSpinner(diameter: RCRefreshControl.diameter, lineWidth: RCRefreshControl.lineWidth)
    private var appliedExtraInset: CGFloat = 0
    /// `contentInset.top` as last written with the extra inset applied.
    private var lastWrittenInsetTop: CGFloat?
    private var isApplyingInset = false
    private var refreshGeneration = 0
    private var hapticPrepared = false
    /// The indicator is fading out after a refresh; scroll updates leave its
    /// opacity and scale alone until the fade completes.
    private var isFadingOut = false
    /// The indicator was last applied fully hidden at rest; scroll callbacks
    /// while content is not pulled skip all view and layer writes.
    private var isIndicatorParked = false
#if DEBUG
    /// Number of scroll-driven indicator updates that wrote view or layer state (tests).
    private(set) var indicatorWriteCount = 0
#endif

    private static let diameter: CGFloat = 22
    private static let lineWidth: CGFloat = 2
    private static let boxSide: CGFloat = 44

    init(scrollView: UIScrollView, onRefresh: @escaping @MainActor () async -> Void) {
        self.scrollView = scrollView
        self.onRefresh = onRefresh
        super.init(frame: CGRect(x: 0, y: -Self.boxSide, width: scrollView.bounds.width, height: Self.boxSide))
        scrollView.insertSubview(self, at: 0)
        scrollViewDidScroll()
    }

    override func setUp() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        alpha = 0
        indicator.isUserInteractionEnabled = false
        addSubview(indicator)
        track.fillColor = nil
        track.lineWidth = Self.lineWidth
        arc.fillColor = nil
        arc.lineWidth = Self.lineWidth
        arc.lineCap = .round
        arc.strokeEnd = 0
        let circle = UIBezierPath(
            arcCenter: CGPoint(x: Self.boxSide / 2, y: Self.boxSide / 2),
            radius: (Self.diameter - Self.lineWidth) / 2,
            startAngle: -.pi / 2,
            endAngle: .pi * 1.5,
            clockwise: true
        ).cgPath
        track.path = circle
        arc.path = circle
        indicator.layer.addSublayer(track)
        indicator.layer.addSublayer(arc)
        spinner.hidesWhenStopped = false
        spinner.alpha = 0
        indicator.addSubview(spinner)
    }

    override func updateAppearance() {
        withoutImplicitAnimations {
            track.strokeColor = RCColor.lineStrong.cgColor(for: self)
            arc.strokeColor = RCColor.accent.cgColor(for: self)
        }
        spinner.tintColor = RCColor.accent
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let box = CGRect(x: (bounds.width - Self.boxSide) / 2, y: (bounds.height - Self.boxSide) / 2, width: Self.boxSide, height: Self.boxSide)
        indicator.bounds = CGRect(origin: .zero, size: box.size)
        indicator.center = CGPoint(x: box.midX, y: box.midY)
        withoutImplicitAnimations {
            track.frame = indicator.bounds
            arc.frame = indicator.bounds
        }
        spinner.frame = CGRect(x: (Self.boxSide - Self.diameter) / 2, y: (Self.boxSide - Self.diameter) / 2, width: Self.diameter, height: Self.diameter)
    }

    // MARK: Scroll forwarding

    /// Resting top inset without the inset this control adds while refreshing.
    private func restingTopInset(_ scrollView: UIScrollView) -> CGFloat {
        scrollView.adjustedContentInset.top - appliedExtraInset
    }

    private func pullDistance(_ scrollView: UIScrollView) -> CGFloat {
        -(scrollView.contentOffset.y + restingTopInset(scrollView))
    }

    /// Forward from `scrollViewDidScroll`.
    func scrollViewDidScroll() {
        guard let scrollView, !isApplyingInset else { return }
        reconcileInset(scrollView)
        let pull = pullDistance(scrollView)
        let effects = machine.scrolled(pull: pull, isDragging: scrollView.isDragging)
        apply(effects)
        if machine.phase == .pulling, !hapticPrepared, pull > threshold * 0.5 {
            hapticPrepared = true
            RCHaptics.prepare(.light)
        } else if machine.phase == .idle {
            hapticPrepared = false
        }
        updateIndicator(in: scrollView, pull: pull)
    }

    /// Forward from `scrollViewWillEndDragging`.
    func scrollViewWillEndDragging() {
        guard let scrollView else { return }
        apply(machine.endDragging(pull: pullDistance(scrollView)))
        hapticPrepared = false
    }

    func beginRefreshing() {
        apply(machine.begin())
    }

    func endRefreshing() {
        apply(machine.finish(isDragging: scrollView?.isDragging ?? false))
    }

    // MARK: Effects

    private func apply(_ effects: [RCRefreshStateMachine.Effect]) {
        guard !effects.isEmpty else { return }
        for effect in effects {
            switch effect {
            case .thresholdHaptic:
                RCHaptics.play(.light)
                confirmThreshold()
            case let .holdInset(animated):
                setExtraInset(refreshingHeight, animated: animated)
            case .releaseInset:
                setExtraInset(0, animated: true)
            case .startRefresh:
                startRefresh()
            case .stopIndicator:
                stopIndicator()
            }
        }
        if let scrollView { updateIndicator(in: scrollView, pull: pullDistance(scrollView)) }
    }

    private func startRefresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        isFadingOut = false
        spinner.startAnimating()
        RCMotion.animate(duration: RCMotion.quickDuration) {
            self.spinner.alpha = 1
            self.alpha = 1
        }
        let ringFade = CABasicAnimation(keyPath: "opacity")
        ringFade.fromValue = 1
        ringFade.toValue = 0
        ringFade.duration = RCMotion.quickDuration
        withoutImplicitAnimations {
            track.opacity = 0
            arc.opacity = 0
        }
        track.add(ringFade, forKey: "rc.fade")
        arc.add(ringFade, forKey: "rc.fade")
        Task { [weak self, onRefresh] in
            await onRefresh()
            guard let self, self.refreshGeneration == generation else { return }
            self.endRefreshing()
        }
    }

    private func stopIndicator() {
        isFadingOut = true
        RCMotion.animate(duration: RCMotion.releaseDuration, animations: {
            self.spinner.alpha = 0
            self.alpha = 0
        }, completion: { [weak self] _ in
            guard let self, !self.machine.isRefreshing else { return }
            self.isFadingOut = false
            self.spinner.stopAnimating()
            withoutImplicitAnimations {
                self.track.opacity = 1
                self.arc.opacity = 1
                self.arc.strokeEnd = 0
            }
        })
    }

    private func confirmThreshold() {
        guard !RCMotion.reduceMotion else { return }
        let tick = CAKeyframeAnimation(keyPath: "transform.scale")
        tick.values = [1, 1.14, 1]
        tick.keyTimes = [0, 0.4, 1]
        tick.duration = 0.28
        tick.timingFunctions = [RCMotion.easeOut, CAMediaTimingFunction(name: .easeInEaseOut)]
        indicator.layer.add(tick, forKey: "rc.tick")
    }

    /// Restores the held gap when the owner re-assigned its base inset.
    private func reconcileInset(_ scrollView: UIScrollView) {
        guard appliedExtraInset != 0, let last = lastWrittenInsetTop else { return }
        let current = scrollView.contentInset.top
        guard abs(current - last) > 0.01 else { return }
        if abs(current - (last - appliedExtraInset)) < 0.5 {
            isApplyingInset = true
            scrollView.contentInset.top = current + appliedExtraInset
            isApplyingInset = false
        }
        // Any other change is the owner's own adjustment on top of the held gap.
        lastWrittenInsetTop = scrollView.contentInset.top
    }

    private func setExtraInset(_ value: CGFloat, animated: Bool) {
        guard let scrollView else { return }
        reconcileInset(scrollView)
        let delta = value - appliedExtraInset
        guard abs(delta) > 0.01 else { return }
        let restingBefore = restingTopInset(scrollView)
        // Content resting at (or pulled past) its top edge, not scrolled into.
        let wasAtRest = pullDistance(scrollView) >= -1
        appliedExtraInset = value
        isApplyingInset = true
        defer { isApplyingInset = false }
        var inset = scrollView.contentInset
        inset.top += delta
        lastWrittenInsetTop = value == 0 ? nil : inset.top
        guard animated, window != nil else {
            scrollView.contentInset = inset
            return
        }
        let target = -(restingBefore + value)
        RCMotion.animate(RCMotion.smooth, animations: {
            scrollView.contentInset = inset
            if value > 0 {
                // Reveal the spinner only when the content was resting at the top.
                if wasAtRest, scrollView.contentOffset.y > target, !scrollView.isDragging {
                    scrollView.contentOffset.y = target
                }
            } else if scrollView.contentOffset.y < target {
                scrollView.contentOffset.y = target
            }
        })
    }

    private func updateIndicator(in scrollView: UIScrollView, pull: CGFloat) {
        // Scrolled into content (or resting) with nothing showing: the hidden
        // indicator's position, ring and transform are irrelevant until a pull.
        let isHiddenAtRest = !machine.holdsInset && !isFadingOut && visibility(forPull: pull) == 0
        if isHiddenAtRest, isIndicatorParked { return }
        isIndicatorParked = isHiddenAtRest
#if DEBUG
        indicatorWriteCount += 1
#endif
        let resting = restingTopInset(scrollView)
        let gapTop = topOffset ?? resting
        let hold = refreshingHeight
        // Scroll-space y of the content's resting top edge below the gap start.
        let restLine = -resting + gapTop
        let centerY: CGFloat
        if machine.holdsInset {
            centerY = restLine - max(pull, hold) / 2
        } else {
            centerY = pull >= hold ? restLine - pull / 2 : restLine - pull + hold / 2
        }
        let width = scrollView.bounds.width
        withoutImplicitAnimations {
            if bounds.width != width {
                bounds = CGRect(x: 0, y: 0, width: width, height: Self.boxSide)
            }
            center = CGPoint(x: scrollView.bounds.minX + width / 2, y: centerY)
        }
        guard !machine.holdsInset, !isFadingOut else { return }
        let progress = machine.progress
        alpha = visibility(forPull: pull)
        withoutImplicitAnimations {
            arc.strokeEnd = progress
            if RCMotion.reduceMotion {
                indicator.transform = .identity
            } else {
                let scale = 0.7 + 0.3 * progress
                indicator.transform = CGAffineTransform(scaleX: scale, y: scale).rotated(by: progress * .pi * 0.5)
            }
        }
    }

    private func visibility(forPull pull: CGFloat) -> CGFloat {
        min(max((pull - 8) / (threshold * 0.45), 0), 1)
    }
}
