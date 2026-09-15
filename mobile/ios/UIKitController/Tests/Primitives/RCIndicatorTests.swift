import XCTest
@testable import RctlUIKit

@MainActor
final class RCIndicatorTests: XCTestCase {
    private var host: PrimitiveTestHost!

    override func setUp() async throws {
        host = PrimitiveTestHost()
    }

    override func tearDown() async throws {
        host.tearDown()
        host = nil
    }

    // MARK: Status badge

    func testBadgeConfigureIsIdempotent() {
        let badge = RCStatusBadge()
        host.add(badge)
        badge.configure(text: "Online", tone: .success, pulsing: true)
        let applied = badge.appliedConfigurationCount
        badge.frame = CGRect(origin: .zero, size: badge.sizeThatFits(.zero))
        host.window.layoutIfNeeded()
        let size = badge.sizeThatFits(.zero)

        badge.configure(text: "Online", tone: .success, pulsing: true)
        badge.configure(text: "Online", tone: .success, pulsing: true, animated: true)
        XCTAssertEqual(badge.appliedConfigurationCount, applied)
        XCTAssertEqual(badge.sizeThatFits(.zero), size)
        XCTAssertFalse(badge.layer.animationKeys()?.contains { $0.hasPrefix("rc.badge") || $0 == "backgroundColor" } ?? false,
                       "a repeated configuration adds no animations")

        badge.configure(text: "Offline", tone: .danger)
        XCTAssertEqual(badge.appliedConfigurationCount, applied + 1)
    }

    func testBadgeAccessibilityCarriesTextAndBusyState() {
        let badge = RCStatusBadge(text: "Online", tone: .success)
        XCTAssertTrue(badge.isAccessibilityElement)
        XCTAssertEqual(badge.accessibilityLabel, "Online")
        XCTAssertNil(badge.accessibilityValue)
        badge.configure(text: "Checking", tone: .neutral, busy: true)
        XCTAssertEqual(badge.accessibilityLabel, "Checking")
        XCTAssertEqual(badge.accessibilityValue, "In progress")
    }

    func testBadgeWidthFollowsTextAndHeightGrowsWithDynamicType() {
        let badge = RCStatusBadge(text: "Online", tone: .success)
        host.add(badge)
        let short = badge.sizeThatFits(.zero)
        XCTAssertEqual(short.height, 24)
        badge.configure(text: "Relay unreachable", tone: .danger)
        XCTAssertGreaterThan(badge.sizeThatFits(.zero).width, short.width)
        host.setCategory(.accessibilityExtraLarge)
        XCTAssertGreaterThan(badge.sizeThatFits(.zero).height, 24)
    }

    func testAnimatedBadgeChangeSpringsFromThePreviousFrame() {
        let badge = RCStatusBadge(text: "Online", tone: .success)
        let size = badge.sizeThatFits(.zero)
        host.add(badge, frame: CGRect(x: 300 - size.width, y: 10, width: size.width, height: size.height))
        badge.configure(text: "Relay unreachable", tone: .danger, animated: true)
        let newSize = badge.sizeThatFits(.zero)
        badge.frame = CGRect(x: 300 - newSize.width, y: 10, width: newSize.width, height: newSize.height)
        badge.layoutIfNeeded()
        XCTAssertNotNil(badge.layer.animation(forKey: "rc.badge.bounds"))
        XCTAssertNotNil(badge.layer.animation(forKey: "rc.badge.position"))
    }

    func testPulseRunsOnlyWhilePulsingAndInAWindow() {
        let badge = RCStatusBadge()
        badge.configure(text: "Live", tone: .success, pulsing: true)
        XCTAssertFalse(badge.hasPulseAnimation, "no animation before the badge is on screen")
        host.add(badge)
        XCTAssertEqual(badge.hasPulseAnimation, !RCMotion.reduceMotion)
        badge.removeFromSuperview()
        XCTAssertFalse(badge.hasPulseAnimation)
        host.add(badge)
        XCTAssertEqual(badge.hasPulseAnimation, !RCMotion.reduceMotion)
        badge.configure(text: "Live", tone: .success, pulsing: false)
        XCTAssertFalse(badge.hasPulseAnimation)
    }

    // MARK: Continuous animations

    func testSpinnerPausesOffWindowAndResumes() {
        let spinner = RCSpinner(diameter: 20, lineWidth: 2)
        spinner.startAnimating()
        XCTAssertFalse(spinner.hasRunningAnimations)
        XCTAssertFalse(spinner.isHidden)
        host.add(spinner)
        XCTAssertTrue(spinner.hasRunningAnimations)
        spinner.removeFromSuperview()
        XCTAssertFalse(spinner.hasRunningAnimations)
        XCTAssertTrue(spinner.isAnimating, "logical state survives leaving the window")
        host.add(spinner)
        XCTAssertTrue(spinner.hasRunningAnimations)
        spinner.stopAnimating()
        XCTAssertFalse(spinner.hasRunningAnimations)
        XCTAssertTrue(spinner.isHidden)
    }

    func testIconButtonSpinResumesAfterReenteringAWindow() {
        let button = RCIconButton(icon: .refreshCw, accessibilityLabel: "Refresh")
        button.isSpinning = true
        host.add(button)
        XCTAssertTrue(button.hasSpinAnimation)
        button.removeFromSuperview()
        XCTAssertFalse(button.hasSpinAnimation)
        host.add(button)
        XCTAssertTrue(button.hasSpinAnimation)
        XCTAssertEqual(button.accessibilityValue, "In progress")
        button.isSpinning = false
        XCTAssertFalse(button.hasSpinAnimation)
    }

    func testSkeletonShimmersOnlyInAWindow() {
        let skeleton = RCSkeletonView()
        skeleton.frame = CGRect(x: 20, y: 20, width: 200, height: 12)
        XCTAssertFalse(skeleton.hasShimmerAnimation)
        host.add(skeleton, frame: CGRect(x: 20, y: 20, width: 200, height: 12))
        XCTAssertEqual(skeleton.hasShimmerAnimation, !RCMotion.reduceMotion)
        skeleton.removeFromSuperview()
        XCTAssertFalse(skeleton.hasShimmerAnimation)
    }

    func testRepeatingAnimationsShareOnePhase() {
        let first = CALayer()
        let second = CALayer()
        host.container.layer.addSublayer(first)
        host.container.layer.addSublayer(second)
        let a = RCLayerAnimation.alignedBeginTime(period: 1.8, in: first)
        let b = RCLayerAnimation.alignedBeginTime(period: 1.8, in: second)
        XCTAssertEqual(fmod(a, 1.8), fmod(b, 1.8), accuracy: 0.001)
        XCTAssertLessThanOrEqual(a, first.convertTime(CACurrentMediaTime(), from: nil))
    }

    // MARK: Icon button

    func testIconButtonSelectionAndHitArea() {
        let button = RCIconButton(icon: .hand, variant: .stage, diameter: 32, iconSize: 16, accessibilityLabel: "Control mode")
        host.add(button, frame: CGRect(x: 100, y: 100, width: 32, height: 32))
        XCTAssertFalse(button.accessibilityTraits.contains(.selected))
        button.isSelected = true
        XCTAssertTrue(button.accessibilityTraits.contains(.selected))
        XCTAssertTrue(button.point(inside: CGPoint(x: -5, y: -5), with: nil), "hit area extends to 44 pt")
        XCTAssertFalse(button.point(inside: CGPoint(x: -7, y: 16), with: nil))
        XCTAssertEqual(button.sizeThatFits(.zero), CGSize(width: 32, height: 32))
        button.isEnabled = false
        XCTAssertTrue(button.accessibilityTraits.contains(.notEnabled))
        XCTAssertTrue(button.accessibilityTraits.contains(.button))
        button.isEnabled = true
        XCTAssertFalse(button.accessibilityTraits.contains(.notEnabled))
    }
}
