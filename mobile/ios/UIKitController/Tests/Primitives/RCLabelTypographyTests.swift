import XCTest
@testable import RctlUIKit

@MainActor
final class RCLabelTypographyTests: XCTestCase {
    private var host: PrimitiveTestHost!

    override func setUp() async throws {
        host = PrimitiveTestHost()
    }

    override func tearDown() async throws {
        host.tearDown()
        host = nil
    }

    // MARK: Rebuild avoidance

    func testUnchangedAssignmentsDoNotRebuildAttributedText() {
        let label = RCLabel("Kitchen iPad", style: .body, color: RCColor.textSecondary, lines: 2, alignment: .center)
        let initial = label.rebuildCount
        XCTAssertEqual(initial, 1, "init builds exactly once")

        label.text = "Kitchen iPad"
        label.style = .body
        label.color = RCColor.textSecondary
        label.textAlignment = .center
        label.lineBreakMode = label.lineBreakMode
        label.usesMonospacedDigits = false
        XCTAssertEqual(label.rebuildCount, initial)

        host.add(label, frame: CGRect(x: 0, y: 0, width: 200, height: 44))
        XCTAssertEqual(label.rebuildCount, initial, "moving into a window with the same category must not rebuild")
        label.layoutIfNeeded()
        _ = label.sizeThatFits(CGSize(width: 200, height: 100))
        XCTAssertEqual(label.rebuildCount, initial, "measuring and layout never rebuild")
    }

    func testEachRealChangeRebuildsOnce() {
        let label = RCLabel("A", style: .body)
        host.add(label)
        var count = label.rebuildCount
        label.text = "B"
        XCTAssertEqual(label.rebuildCount, count + 1)
        count = label.rebuildCount
        label.style = .headline
        XCTAssertEqual(label.rebuildCount, count + 1)
        count = label.rebuildCount
        label.color = RCColor.accent
        XCTAssertEqual(label.rebuildCount, count + 1)
        count = label.rebuildCount
        label.textAlignment = .right
        XCTAssertEqual(label.rebuildCount, count + 1)
        count = label.rebuildCount
        host.setCategory(.accessibilityLarge)
        XCTAssertEqual(label.rebuildCount, count + 1, "a content size change rebuilds once")
        count = label.rebuildCount
        host.setCategory(.accessibilityLarge)
        XCTAssertEqual(label.rebuildCount, count)
    }

    // MARK: Metrics

    func testSingleLineHeightIsTheStyleLineHeight() {
        for style in RCTextStyle.allCases {
            let label = RCLabel("Kitchen iPad · 192.168.1.30", style: style)
            host.add(label)
            let size = label.sizeThatFits(CGSize(width: 1000, height: 1000))
            XCTAssertEqual(size.height, RCTypography.lineHeight(style, compatibleWith: label.traitCollection), accuracy: 0.01, "\(style)")
            XCTAssertEqual(label.intrinsicContentSize, size, "\(style)")
            XCTAssertEqual(label.sizeThatFits(CGSize(width: 1000, height: 1000)), size, "sizeThatFits is stable")
            label.removeFromSuperview()
        }
    }

    func testMultiLineWrapsInWholeLinesAndTwoLineLabelsClamp() {
        let text = String(repeating: "Relay devices stay reachable anywhere. ", count: 6)
        let wrapping = RCLabel(text, style: .body, lines: 0)
        let clamped = RCLabel(text, style: .body, lines: 2)
        host.add(wrapping)
        host.add(clamped)
        let lineHeight = RCTypography.lineHeight(.body, compatibleWith: wrapping.traitCollection)
        let wrapped = wrapping.sizeThatFits(CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude)).height
        XCTAssertGreaterThan(wrapped, lineHeight * 3)
        XCTAssertEqual(wrapped.truncatingRemainder(dividingBy: lineHeight), 0, accuracy: 0.5)
        XCTAssertEqual(clamped.sizeThatFits(CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude)).height, lineHeight * 2, accuracy: 0.5)
        XCTAssertEqual(clamped.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(wrapping.lineBreakMode, .byWordWrapping)
    }

    func testDynamicTypeGrowsLabelsAndRespectsCaps() {
        let label = RCLabel("Kitchen iPad", style: .body)
        host.add(label)
        let regular = label.sizeThatFits(CGSize(width: 1000, height: 1000)).height
        host.setCategory(.accessibilityExtraExtraExtraLarge)
        let huge = label.sizeThatFits(CGSize(width: 1000, height: 1000)).height
        XCTAssertGreaterThan(huge, regular)
        XCTAssertLessThanOrEqual(RCTypography.font(.body, compatibleWith: label.traitCollection).pointSize, RCTextStyle.body.spec.maximumSize + 0.01)
    }

    func testUppercaseStylesKeepTheSourceTextForVoiceOver() {
        let label = RCLabel("Nearby", style: .overline)
        XCTAssertEqual(label.attributedText?.string, "NEARBY")
        XCTAssertEqual(label.accessibilityLabel, "Nearby")
        label.accessibilityLabel = "Nearby devices"
        XCTAssertEqual(label.accessibilityLabel, "Nearby devices")
    }

    func testTrackingIsNotAppliedAfterTheLastCharacter() {
        let string = RCTypography.attributedString("Nearby", style: .overline, color: RCColor.text)
        XCTAssertEqual(string.string, "NEARBY")
        XCTAssertNotNil(string.attribute(.kern, at: 0, effectiveRange: nil))
        XCTAssertNil(string.attribute(.kern, at: string.length - 1, effectiveRange: nil))
    }

    func testUnspecifiedCategoryResolvesToARealCategory() {
        let unspecified = RCTypography.font(.body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .unspecified))
        let screen = RCTypography.font(.body, compatibleWith: UIScreen.main.traitCollection)
        XCTAssertTrue(unspecified === screen)
    }

    /// Glyphs in an RCLabel line box land where a plain UILabel of the font's
    /// natural height, centered in the same box, draws them (within 1.5 device pixels).
    func testSingleLineTextIsOpticallyCenteredLikeAPlainLabel() {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        for style in RCTextStyle.allCases {
            let font = RCTypography.font(style, compatibleWith: traits)
            let lineHeight = RCTypography.lineHeight(style, compatibleWith: traits)
            let plain = UILabel()
            plain.font = font
            plain.text = "HHH"
            plain.frame = CGRect(x: 0, y: 0, width: 120, height: plain.sizeThatFits(CGSize(width: 1000, height: 1000)).height)
            let expected = inkTop(of: plain) + (lineHeight - font.lineHeight) / 2
            let styled = UILabel()
            styled.attributedText = RCTypography.attributedString("HHH", style: style, color: .black, compatibleWith: traits)
            styled.frame = CGRect(x: 0, y: 0, width: 120, height: lineHeight)
            XCTAssertEqual(inkTop(of: styled), expected, accuracy: 1.5 / UIScreen.main.scale + 0.01, "\(style)")
        }
    }

    func testFirstBaselineMatchesRenderedCapTop() {
        let traits = UITraitCollection(preferredContentSizeCategory: .large)
        for style in [RCTextStyle.overline, .caption, .body, .title2] {
            let font = RCTypography.font(style, compatibleWith: traits)
            let label = UILabel()
            label.attributedText = RCTypography.attributedString("HHH", style: style, color: .black, compatibleWith: traits)
            label.frame = CGRect(x: 0, y: 0, width: 120, height: RCTypography.lineHeight(style, compatibleWith: traits))
            let capTop = RCTypography.firstBaseline(style, compatibleWith: traits) - font.capHeight
            XCTAssertEqual(inkTop(of: label), capTop, accuracy: 2 / UIScreen.main.scale + 0.01, "\(style)")
        }
    }

    private func inkTop(of view: UIView) -> CGFloat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return -1 }
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        for y in 0..<cgImage.height {
            for x in 0..<cgImage.width where bytes[y * cgImage.bytesPerRow + x * bytesPerPixel + 3] > 40 {
                return CGFloat(y) / UIScreen.main.scale
            }
        }
        return -1
    }
}
