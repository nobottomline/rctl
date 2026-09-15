import XCTest
@testable import RctlUIKit

@MainActor
final class RCButtonTests: XCTestCase {
    private var host: PrimitiveTestHost!

    override func setUp() async throws {
        host = PrimitiveTestHost()
    }

    override func tearDown() async throws {
        host.tearDown()
        host = nil
    }

    private let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

    func testSizesUseTheirMinimumHeightsAtTheDefaultCategory() {
        for size in [RCButton.Size.small, .medium, .large] {
            let button = RCButton(title: "Pair", icon: .qrCode, variant: .primary, size: size)
            host.add(button)
            XCTAssertEqual(button.sizeThatFits(unbounded).height, size.height, "\(size)")
        }
    }

    func testSizeThatFitsIsStableAndOnThePixelGrid() {
        let button = RCButton(title: "Add local device", icon: .wifi, variant: .secondary, size: .medium)
        host.add(button)
        let first = button.sizeThatFits(unbounded)
        button.frame = CGRect(origin: .zero, size: first)
        button.layoutIfNeeded()
        XCTAssertEqual(button.sizeThatFits(unbounded), first)
        XCTAssertEqual(button.sizeThatFits(CGSize(width: 10, height: 10)), first, "natural size ignores the proposal")
        XCTAssertEqual(button.intrinsicContentSize, first)
        let scale = UIScreen.main.scale
        XCTAssertEqual((first.width * scale).rounded(), first.width * scale, accuracy: 0.001)
    }

    func testWidthAccountsForIconAndTitle() {
        let titleOnly = RCButton(title: "Continue", variant: .primary, size: .medium)
        let withIcon = RCButton(title: "Continue", icon: .arrowRight, variant: .primary, size: .medium)
        host.add(titleOnly)
        host.add(withIcon)
        XCTAssertGreaterThan(withIcon.sizeThatFits(unbounded).width, titleOnly.sizeThatFits(unbounded).width + 18)
        let iconOnly = RCButton(icon: .refreshCw, variant: .secondary, size: .medium)
        host.add(iconOnly)
        XCTAssertEqual(iconOnly.sizeThatFits(unbounded), CGSize(width: 44, height: 44), "icon-only buttons are square")
    }

    func testDynamicTypeGrowsHeightButNeverBelowTheMinimum() {
        let button = RCButton(title: "Pair with relay", icon: .qrCode, variant: .accent, size: .large)
        host.add(button)
        let regular = button.sizeThatFits(unbounded)
        host.setCategory(.extraSmall)
        XCTAssertEqual(button.sizeThatFits(unbounded).height, RCButton.Size.large.height)
        host.setCategory(.accessibilityExtraExtraExtraLarge)
        let huge = button.sizeThatFits(unbounded)
        XCTAssertGreaterThan(huge.height, regular.height)
        XCTAssertGreaterThan(huge.width, regular.width)
        XCTAssertEqual(button.sizeThatFits(unbounded), huge, "stable after the category change")
    }

    func testLoadingKeepsWidthAndBlocksTaps() {
        let withIcon = RCButton(title: "Refresh", icon: .refreshCw, variant: .secondary, size: .medium)
        let textOnly = RCButton(title: "Save", variant: .primary, size: .medium)
        host.add(withIcon)
        host.add(textOnly)
        for button in [withIcon, textOnly] {
            var taps = 0
            button.onTap = { taps += 1 }
            let before = button.sizeThatFits(unbounded)
            button.isLoading = true
            XCTAssertEqual(button.sizeThatFits(unbounded), before)
            XCTAssertTrue(button.accessibilityTraits.contains(.notEnabled))
            XCTAssertEqual(button.accessibilityValue, "In progress")
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(taps, 0)
            button.isLoading = false
            XCTAssertEqual(button.sizeThatFits(unbounded), before)
            XCTAssertNil(button.accessibilityValue)
            button.sendActions(for: .touchUpInside)
            XCTAssertEqual(taps, 1)
        }
    }

    func testAccessibilityDefaultsToTitleAndReflectsDisabled() {
        let button = RCButton(title: "Delete device", icon: .trash2, variant: .destructive)
        XCTAssertEqual(button.accessibilityLabel, "Delete device")
        XCTAssertTrue(button.accessibilityTraits.contains(.button))
        XCTAssertFalse(button.accessibilityTraits.contains(.notEnabled))
        button.isEnabled = false
        XCTAssertTrue(button.accessibilityTraits.contains(.notEnabled))
        button.accessibilityLabel = "Delete Kitchen iPad"
        XCTAssertEqual(button.accessibilityLabel, "Delete Kitchen iPad")
    }

    func testLongTitlesTruncateInsideTheFrame() {
        let button = RCButton(title: "Forget this device and every saved address", icon: .trash2, variant: .destructiveSoft, size: .medium)
        host.add(button, frame: CGRect(x: 0, y: 0, width: 180, height: 44))
        button.layoutIfNeeded()
        let label = button.subviews.first?.subviews.compactMap { $0 as? RCLabel }.first
        XCTAssertNotNil(label)
        if let label {
            let frame = label.convert(label.bounds, to: button)
            XCTAssertLessThanOrEqual(frame.maxX, 180 - 17.9)
            XCTAssertGreaterThan(frame.width, 60)
        }
    }

    func testIconPlacementMirrorsInRightToLeft() {
        let button = RCButton(title: "Next", icon: .chevronRight, variant: .secondary, size: .medium)
        host.add(button, frame: CGRect(x: 0, y: 0, width: 160, height: 44))
        func iconMidX() -> CGFloat {
            let icon = button.subviews.first!.subviews.compactMap { $0 as? RCIconView }.first!
            return icon.frame.midX
        }
        button.layoutIfNeeded()
        XCTAssertLessThan(iconMidX(), 80, "leading icon on the left in LTR")
        button.semanticContentAttribute = .forceRightToLeft
        button.setNeedsLayout()
        button.layoutIfNeeded()
        XCTAssertGreaterThan(iconMidX(), 80, "leading icon on the right in RTL")
    }

    func testPressFeedbackScalesTheBodyNotTheControl() {
        let button = RCButton(title: "Press", variant: .accent, size: .medium)
        host.add(button, frame: CGRect(x: 0, y: 0, width: 120, height: 44))
        button.isHighlighted = true
        XCTAssertEqual(button.transform, .identity, "the control's own geometry stays intact for layout")
        XCTAssertNotEqual(button.subviews.first?.transform, .identity)
        button.isHighlighted = false
        XCTAssertEqual(button.subviews.first?.transform, .identity)
    }
}
