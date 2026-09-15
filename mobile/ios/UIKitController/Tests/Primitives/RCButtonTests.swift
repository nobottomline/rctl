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

    // MARK: Disabled

    private func contrast(_ a: UIColor, _ b: UIColor) -> CGFloat {
        func luminance(_ color: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, al: CGFloat = 0
            color.getRed(&r, green: &g, blue: &bl, alpha: &al)
            func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(bl)
        }
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testDisabledFilledVariantsKeepAReadableLabelInBothAppearances() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            host.window.overrideUserInterfaceStyle = style
            for variant in [RCButton.Variant.primary, .accent, .destructive] {
                let button = RCButton(title: "Connect", icon: .arrowRight, variant: variant, size: .large)
                host.add(button, frame: CGRect(x: 0, y: 0, width: 300, height: 52))
                let enabledFill = button.appearanceForTesting.fill
                button.isEnabled = false
                let look = button.appearanceForTesting
                XCTAssertEqual(look.bodyAlpha, 1, "\(variant): no group-opacity fade that washes the label out")
                let fill = try? XCTUnwrap(look.fill)
                XCTAssertNotEqual(fill, enabledFill, "\(variant): disabled swaps the saturated fill")
                if let fill {
                    XCTAssertGreaterThanOrEqual(contrast(look.label, fill), 4.5, "\(variant) \(style.rawValue): disabled label contrast")
                }
                XCTAssertFalse(button.subviews.first?.layer.shouldRasterize ?? true, "opaque disabled look needs no flattening")
                button.isEnabled = true
                XCTAssertEqual(button.appearanceForTesting.fill, enabledFill, "\(variant): enabled look returns")
                button.removeFromSuperview()
            }
        }
    }

    func testDisabledOutlineVariantsStillFade() {
        let button = RCButton(title: "Cancel", variant: .secondary, size: .medium)
        host.add(button, frame: CGRect(x: 0, y: 0, width: 160, height: 44))
        button.isEnabled = false
        let alpha = button.appearanceForTesting.bodyAlpha
        XCTAssertEqual(alpha, 0.45, accuracy: 0.001)
    }

    // MARK: Wrapping

    private func titleLabel(of button: RCButton) -> RCLabel? {
        button.subviews.first?.subviews.compactMap { $0 as? RCLabel }.first
    }

    func testTitlesWrapToThreeLinesAtAccessibilitySizesWithAnExactHeight() throws {
        let title = "Use this address for a saved device…"
        let button = RCButton(title: title, variant: .ghost, size: .medium)
        host.add(button)
        let proposal = CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude)
        let regular = button.sizeThatFits(proposal)
        XCTAssertEqual(regular.height, RCButton.Size.medium.height, "one line at the default size")
        XCTAssertEqual(button.appearanceForTesting.titleLines, 1)

        host.setCategory(.accessibilityExtraExtraExtraLarge)
        XCTAssertEqual(button.appearanceForTesting.titleLines, RCButton.maximumTitleLines)
        let lineHeight = RCTypography.lineHeight(.calloutStrong, compatibleWith: button.traitCollection)
        let singleLine = button.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        let wrapped = button.sizeThatFits(proposal)
        XCTAssertLessThanOrEqual(wrapped.width, 280)
        XCTAssertGreaterThan(wrapped.height, singleLine.height, "the height grows instead of truncating")
        XCTAssertLessThanOrEqual(wrapped.height, lineHeight * 3 + 20 + 1, "never more than three lines")
        let scale = UIScreen.main.scale
        XCTAssertEqual((wrapped.height * scale).rounded(), wrapped.height * scale, accuracy: 0.001, "on the pixel grid")

        button.frame = CGRect(origin: .zero, size: wrapped)
        button.layoutIfNeeded()
        XCTAssertEqual(button.sizeThatFits(proposal), wrapped, "stable once laid out at its own size")
        let label = try XCTUnwrap(titleLabel(of: button))
        let frame = label.convert(label.bounds, to: button)
        XCTAssertTrue(button.bounds.contains(frame.insetBy(dx: 0.5, dy: 0.5)), "label \(frame) inside \(button.bounds)")
        let needed = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
        XCTAssertLessThanOrEqual(needed, label.bounds.height + 0.5, "the whole title fits: nothing truncated")
        XCTAssertGreaterThanOrEqual(label.bounds.height, lineHeight * 2 - 0.5, "wrapped onto more than one line")
    }

    func testShortTitlesStayOnOneLineAtAccessibilitySizes() {
        host.setCategory(.accessibilityExtraExtraExtraLarge)
        let button = RCButton(title: "Save", variant: .primary, size: .large)
        host.add(button)
        let natural = button.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        XCTAssertEqual(button.sizeThatFits(CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)), natural)
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
