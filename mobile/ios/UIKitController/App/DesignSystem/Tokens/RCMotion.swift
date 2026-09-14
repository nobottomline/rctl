import UIKit

/// Motion tokens. Springs are described the way designers tune them
/// (response + damping) and converted to UIKit and Core Animation parameters.
/// Every helper honors Reduce Motion: movement becomes a short crossfade or is
/// applied instantly.
@MainActor
enum RCMotion {
    struct Spring: Sendable {
        /// Approximate settle time in seconds.
        let response: TimeInterval
        /// 1 = critically damped, lower = bouncier.
        let damping: CGFloat
    }

    /// Press-down feedback on buttons and rows.
    static let pressDuration: TimeInterval = 0.12
    /// Release back to rest.
    static let releaseDuration: TimeInterval = 0.22
    /// Small state changes: colors, badges, icon swaps.
    static let quickDuration: TimeInterval = 0.18
    /// Crossfade used instead of movement under Reduce Motion.
    static let reducedDuration: TimeInterval = 0.16

    /// General layout and panel motion.
    static let standard = Spring(response: 0.42, damping: 0.86)
    /// Menus, popovers, segmented thumbs.
    static let snappy = Spring(response: 0.30, damping: 0.84)
    /// Sheets and large surfaces.
    static let smooth = Spring(response: 0.50, damping: 0.92)
    /// Playful confirmations (checkmarks, lock-on).
    static let bouncy = Spring(response: 0.38, damping: 0.68)

    static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// Ease-out curve matching the web client's `--ease-out` (cubic-bezier(0.16, 1, 0.3, 1)).
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    static let easeIn = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)

    /// Interruptible spring animation. Under Reduce Motion the changes are
    /// applied with a short linear fade.
    @discardableResult
    static func animate(
        _ spring: Spring = standard,
        delay: TimeInterval = 0,
        initialVelocity: CGVector = .zero,
        animations: @escaping @MainActor () -> Void,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) -> UIViewPropertyAnimator {
        let animator: UIViewPropertyAnimator
        if reduceMotion {
            animator = UIViewPropertyAnimator(duration: reducedDuration, curve: .linear, animations: animations)
        } else {
            let timing = UISpringTimingParameters(dampingRatio: spring.damping, initialVelocity: initialVelocity)
            animator = UIViewPropertyAnimator(duration: spring.response, timingParameters: timing)
            animator.addAnimations(animations)
        }
        if let completion {
            animator.addCompletion { position in
                MainActor.assumeIsolated { completion(position == .end) }
            }
        }
        animator.startAnimation(afterDelay: delay)
        return animator
    }

    /// Non-spring timed animation with the product ease-out curve.
    @discardableResult
    static func animate(
        duration: TimeInterval,
        curve: CAMediaTimingFunction = easeOut,
        delay: TimeInterval = 0,
        animations: @escaping @MainActor () -> Void,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) -> UIViewPropertyAnimator {
        let points = curve.controlPointPair
        let timing = UICubicTimingParameters(controlPoint1: points.0, controlPoint2: points.1)
        let animator = UIViewPropertyAnimator(duration: reduceMotion ? min(duration, reducedDuration) : duration, timingParameters: timing)
        animator.addAnimations(animations)
        if let completion {
            animator.addCompletion { position in
                MainActor.assumeIsolated { completion(position == .end) }
            }
        }
        animator.startAnimation(afterDelay: delay)
        return animator
    }

    /// Core Animation spring equivalent to `spring`, for layer properties
    /// (paths, shadow paths, strokeEnd) that run on the render server.
    static func caSpring(keyPath: String, spring: Spring = standard) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        let omega = 2 * Double.pi / max(spring.response, 0.01)
        animation.stiffness = CGFloat(omega * omega)
        animation.damping = CGFloat(4 * Double.pi * Double(spring.damping) / max(spring.response, 0.01))
        animation.initialVelocity = 0
        animation.duration = animation.settlingDuration
        animation.fillMode = .backwards
        return animation
    }
}

private extension CAMediaTimingFunction {
    var controlPointPair: (CGPoint, CGPoint) {
        var first = [Float](repeating: 0, count: 2)
        var second = [Float](repeating: 0, count: 2)
        getControlPoint(at: 1, values: &first)
        getControlPoint(at: 2, values: &second)
        return (
            CGPoint(x: CGFloat(first[0]), y: CGFloat(first[1])),
            CGPoint(x: CGFloat(second[0]), y: CGFloat(second[1]))
        )
    }
}
