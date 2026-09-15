import CoreGraphics
import Foundation

/// A decoded QR code in stage (full-bleed preview) coordinates.
struct ScannerDetection: Equatable, Sendable {
    let payload: String
    /// `.null` when the code could not be mapped into the preview.
    let bounds: CGRect
}

/// Cancellable one-shot timer handed out by a `ScannerClock`.
@MainActor
protocol ScannerTimer: AnyObject {
    func cancel()
}

/// Time source for the scanner flow, injectable so the lock delay, rejection
/// window and foreign-code throttling can be tested without waiting.
@MainActor
protocol ScannerClock: AnyObject {
    /// Monotonic seconds.
    var now: TimeInterval { get }
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScannerTimer
}

/// Production clock: system uptime and main-queue deadlines.
@MainActor
final class MainQueueScannerClock: ScannerClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> ScannerTimer {
        let timer = MainQueueScannerTimer(action: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [timer] in
            MainActor.assumeIsolated { timer.fire() }
        }
        return timer
    }
}

@MainActor
private final class MainQueueScannerTimer: ScannerTimer {
    private var action: (@MainActor () -> Void)?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func fire() {
        let pending = action
        action = nil
        pending?()
    }

    func cancel() {
        action = nil
    }
}

/// Decides what the scanner does with each detection: lock onto a pairing
/// code, confirm it after a short hold, claim it once, reject non-pairing
/// codes locally, and ignore a failed code for a while. UIKit-free; the
/// screen renders `phase`, `isShowingForeignCode` and `detection`.
@MainActor
final class ScannerDetectionFlow {
    enum Phase: Equatable, Sendable {
        case scanning
        /// A pairing code is in view; it is claimed if it stays for the lock delay.
        case locked(payload: String)
        /// A claim is running.
        case pairing
    }

    enum Feedback: Equatable, Sendable {
        /// Lock-on to a pairing code.
        case lock
        /// A new code that is not a pairing code.
        case foreign
        /// The code is being claimed.
        case deliver
    }

    struct Timing: Sendable {
        var lockDelay: TimeInterval = 0.42
        var reducedMotionLockDelay: TimeInterval = 0.12
        /// How long a payload whose claim failed is ignored.
        var rejectionWindow: TimeInterval = 6
        /// Minimum spacing of foreign-code feedback.
        var foreignFeedbackInterval: TimeInterval = 2.5
        /// Foreign-code message stays readable this long after the code leaves the frame.
        var foreignLinger: TimeInterval = 1.5
    }

    private(set) var phase: Phase = .scanning
    private(set) var isShowingForeignCode = false
    private(set) var detection: ScannerDetection?
    /// Shortens the lock hold (no reticle motion to wait for).
    var reduceMotion = false

    /// Any published state changed.
    var onStateChange: (@MainActor () -> Void)?
    var onFeedback: (@MainActor (Feedback) -> Void)?
    /// Claim `payload`; report the result with `deliveryDidFinish(payload:paired:)`.
    var onDeliver: (@MainActor (String) -> Void)?

    private let clock: ScannerClock
    private let timing: Timing
    private var lockTimer: ScannerTimer?
    private var lingerTimer: ScannerTimer?
    private var rejected: (payload: String, until: TimeInterval)?
    private var foreignPayload: String?
    private var foreignFeedbackNotBefore = -TimeInterval.infinity

    init(clock: ScannerClock, timing: Timing = Timing()) {
        self.clock = clock
        self.timing = timing
    }

    /// Latest camera (or demo) detection; nil when no code is in view.
    func update(_ next: ScannerDetection?) {
        guard next != detection else { return }
        detection = next
        handle(next)
        notify()
    }

    /// A pasted code skips detection and is claimed right away.
    /// Returns false while a claim is already running.
    @discardableResult
    func deliverPasted(_ payload: String) -> Bool {
        guard phase != .pairing else { return false }
        deliver(payload)
        notify()
        return true
    }

    /// Result of a claim started by `onDeliver`. On success the phase stays
    /// `.pairing` while the router leaves the flow; a failure is explained
    /// elsewhere, so scanning resumes and the same payload is ignored briefly.
    func deliveryDidFinish(payload: String, paired: Bool) {
        guard !paired else { return }
        rejected = (payload, clock.now + timing.rejectionWindow)
        guard phase == .pairing else { return }
        phase = .scanning
        notify()
    }

    /// The camera stopped (screen hidden, app inactive): drop transient
    /// detection state and timers but keep a running claim.
    func suspend() {
        cancelLock()
        cancelLinger()
        detection = nil
        isShowingForeignCode = false
        foreignPayload = nil
        if case .locked = phase { phase = .scanning }
        notify()
    }

    // MARK: - Rules

    private func handle(_ detection: ScannerDetection?) {
        guard phase != .pairing else { return }
        guard let detection else {
            cancelLock()
            if case .locked = phase { phase = .scanning }
            if isShowingForeignCode { scheduleForeignLinger() }
            return
        }
        if let rejected, rejected.payload == detection.payload, clock.now < rejected.until {
            return
        }
        guard PairingPayload.looksLikePairingCode(detection.payload) else {
            noteForeign(detection.payload)
            return
        }
        clearForeign()
        if case let .locked(payload) = phase, payload == detection.payload { return }
        cancelLock()
        phase = .locked(payload: detection.payload)
        onFeedback?(.lock)
        let payload = detection.payload
        lockTimer = clock.schedule(after: reduceMotion ? timing.reducedMotionLockDelay : timing.lockDelay) { [weak self] in
            guard let self else { return }
            self.lockTimer = nil
            guard self.phase == .locked(payload: payload) else { return }
            self.deliver(payload)
            self.notify()
        }
    }

    /// One soft cue per new foreign code, never more often than the interval,
    /// so a stray code on a desk does not keep buzzing.
    private func noteForeign(_ payload: String) {
        cancelLinger()
        if !isShowingForeignCode || foreignPayload != payload {
            foreignPayload = payload
            let now = clock.now
            if now >= foreignFeedbackNotBefore {
                onFeedback?(.foreign)
                foreignFeedbackNotBefore = now + timing.foreignFeedbackInterval
            }
        }
        isShowingForeignCode = true
    }

    private func scheduleForeignLinger() {
        cancelLinger()
        lingerTimer = clock.schedule(after: timing.foreignLinger) { [weak self] in
            guard let self else { return }
            self.lingerTimer = nil
            self.clearForeign()
            self.notify()
        }
    }

    private func clearForeign() {
        cancelLinger()
        isShowingForeignCode = false
        foreignPayload = nil
    }

    private func deliver(_ payload: String) {
        cancelLock()
        clearForeign()
        phase = .pairing
        onFeedback?(.deliver)
        onDeliver?(payload)
    }

    private func cancelLock() {
        lockTimer?.cancel()
        lockTimer = nil
    }

    private func cancelLinger() {
        lingerTimer?.cancel()
        lingerTimer = nil
    }

    private func notify() {
        onStateChange?()
    }
}

/// Display values for the scanner derived from the flow (UIKit-free).
struct ScannerPresentation: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        /// White brackets: looking for a code.
        case searching
        /// Green brackets and a check badge: a pairing code is locked or being claimed.
        case locked
        /// Amber brackets and a caption: the code in view is not a pairing code.
        case rejected
    }

    /// Every title/message pair the scanner can show, for reserving space.
    static let allCopy: [(title: String, message: String)] = [
        ScannerPresentation(phase: .scanning, isShowingForeignCode: false, hasDetection: false, reduceMotion: false),
        ScannerPresentation(phase: .scanning, isShowingForeignCode: true, hasDetection: true, reduceMotion: false),
        ScannerPresentation(phase: .locked(payload: ""), isShowingForeignCode: false, hasDetection: true, reduceMotion: false),
        ScannerPresentation(phase: .pairing, isShowingForeignCode: false, hasDetection: true, reduceMotion: false),
    ].map { ($0.title, $0.message) }

    let tone: Tone
    let title: String
    let message: String
    let showsForeignCaption: Bool
    let showsLockBadge: Bool
    let showsPairingCard: Bool
    /// Idle scale pulse of the brackets: only while searching with nothing in view.
    let isBreathing: Bool
    let controlsEnabled: Bool

    init(phase: ScannerDetectionFlow.Phase, isShowingForeignCode: Bool, hasDetection: Bool, reduceMotion: Bool) {
        let foreign = isShowingForeignCode && phase == .scanning
        switch phase {
        case .scanning:
            tone = foreign ? .rejected : .searching
            title = foreign ? "That is not a pairing code" : "Scan the pairing code"
            message = foreign
                ? "Open relay admin and show the controller pairing QR code."
                : "Point the camera at the QR code shown in relay admin."
        case .locked:
            tone = .locked
            title = "Code found"
            message = "Hold still for a moment."
        case .pairing:
            tone = .locked
            title = "Pairing with relay"
            message = "Creating your controller key and claiming the code."
        }
        showsForeignCaption = foreign
        showsLockBadge = tone == .locked
        showsPairingCard = phase == .pairing
        isBreathing = phase == .scanning && !hasDetection && !isShowingForeignCode && !reduceMotion
        controlsEnabled = phase != .pairing
    }
}
