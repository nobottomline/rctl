import XCTest
@testable import RctlUIKit

@MainActor
final class RCListRowLayoutTests: XCTestCase {
    private let standard = UITraitCollection(traitsFrom: [
        UITraitCollection(preferredContentSizeCategory: .large),
        UITraitCollection(layoutDirection: .leftToRight),
    ])
    /// Column width of a 402 pt phone with 20 pt gutters.
    private let phoneWidth: CGFloat = 362
    /// Column width of a 320 pt phone with 20 pt gutters.
    private let smallPhoneWidth: CGFloat = 280

    private var host: ListsTraitHost!

    override func setUp() async throws {
        host = ListsTraitHost(category: .large)
    }

    override func tearDown() async throws {
        host.tearDown()
        host = nil
    }

    private func badgeSize(_ text: String, busy: Bool = false) -> CGSize {
        let badge = host.host(RCStatusBadge())
        badge.configure(text: text, tone: .neutral, busy: busy)
        return badge.sizeThatFits(.zero)
    }

    private func device(_ status: String, detail: String? = "192.168.1.20:8080", mono: Bool = true, busy: Bool = false) -> RCListRow.Content {
        .init(title: "Studio iPad", detail: detail, detailIsMonospaced: mono, glyph: .tabletSmartphone, trailing: .badgeAndChevron(text: status, tone: .neutral, busy: busy))
    }

    func testInlineHeightIsStableAcrossStatusChanges() {
        let checking = RCListRow.layout(for: device("Checking", busy: true), width: phoneWidth, traits: standard, badgeSize: badgeSize("Checking", busy: true))
        let online = RCListRow.layout(for: device("Online"), width: phoneWidth, traits: standard, badgeSize: badgeSize("Online"))
        XCTAssertFalse(checking.isStacked)
        XCTAssertFalse(online.isStacked)
        XCTAssertEqual(checking.size.height, online.size.height)
        XCTAssertEqual(checking.titleFrame.minY, online.titleFrame.minY)
    }

    func testAddressAndPlainDetailShareOneLineHeight() {
        let resolving = RCListRow.layout(for: device("Checking", detail: "Resolving address…", mono: false), width: phoneWidth, traits: standard, badgeSize: badgeSize("Checking"))
        let resolved = RCListRow.layout(for: device("Checking", detail: "192.168.1.20:8080", mono: true), width: phoneWidth, traits: standard, badgeSize: badgeSize("Checking"))
        XCTAssertEqual(resolving.size.height, resolved.size.height, "Switching the detail to an address must not move the row")
    }

    func testRowWithoutDetailIsSizedByTheTile() {
        let layout = RCListRow.layout(for: .init(title: "Add local device", glyph: .wifi, tileTone: .dashed, trailing: .plus), width: phoneWidth, traits: standard)
        XCTAssertEqual(layout.size.height, RCListRow.tileSide + RCListRow.insets.top + RCListRow.insets.bottom)
        XCTAssertEqual(layout.tileFrame.midY, layout.size.height / 2)
    }

    func testAccessibilitySizesStackBadgeUnderDetail() {
        let traits = UITraitCollection(traitsFrom: [standard, UITraitCollection(preferredContentSizeCategory: .accessibilityMedium)])
        let layout = RCListRow.layout(for: device("Online"), width: phoneWidth, traits: traits, badgeSize: badgeSize("Online"))
        XCTAssertTrue(layout.isStacked)
        XCTAssertGreaterThanOrEqual(layout.badgeFrame.minY, layout.detailFrame.maxY)
        XCTAssertEqual(layout.badgeFrame.minX, layout.titleFrame.minX)
        XCTAssertLessThanOrEqual(layout.badgeFrame.maxY, layout.size.height - RCListRow.insets.bottom + 0.5)
    }

    func testRowsWithoutBadgeNeverStack() {
        let traits = UITraitCollection(traitsFrom: [standard, UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)])
        let layout = RCListRow.layout(for: .init(title: "Pair with relay", detail: "Scan a one-time code", glyph: .scanQrCode, trailing: .plus), width: phoneWidth, traits: traits)
        XCTAssertFalse(layout.isStacked)
    }

    func testTruncatedDetailStacksInsteadOfShrinkingTheAddress() {
        let badge = badgeSize("Online")
        let short = RCListRow.layout(for: device("Online", detail: "10.0.0.7:8080"), width: phoneWidth, traits: standard, badgeSize: badge)
        XCTAssertFalse(short.isStacked)
        let long = RCListRow.layout(for: device("Online", detail: "192.168.100.200:8080 · saved as Living room"), width: phoneWidth, traits: standard, badgeSize: badge)
        XCTAssertTrue(long.isStacked)
        XCTAssertGreaterThan(long.detailFrame.width, short.detailFrame.width, "Stacking gives the detail the badge's width")
    }

    func testNarrowColumnStacksBesideAWideBadge() {
        let content = device("Incompatible", detail: "10.0.0.7:8080")
        XCTAssertTrue(RCListRow.layout(for: content, width: smallPhoneWidth - 60, traits: standard, badgeSize: badgeSize("Incompatible")).isStacked)
    }

    func testTitleIsLimitedToTwoLines() {
        let content = RCListRow.Content(title: String(repeating: "Living room iPad Pro ", count: 8), glyph: .tablet, trailing: .chevron)
        let layout = RCListRow.layout(for: content, width: smallPhoneWidth, traits: standard)
        XCTAssertEqual(layout.titleLineCount, 2)
        XCTAssertEqual(layout.titleFrame.height, 2 * RCTypography.lineHeight(.bodyStrong, compatibleWith: standard))
    }

    func testRightToLeftMirrorsHorizontalPositions() {
        let rtl = UITraitCollection(traitsFrom: [standard, UITraitCollection(layoutDirection: .rightToLeft)])
        let badge = badgeSize("Online")
        let ltrLayout = RCListRow.layout(for: device("Online"), width: phoneWidth, traits: standard, badgeSize: badge)
        let rtlLayout = RCListRow.layout(for: device("Online"), width: phoneWidth, traits: rtl, badgeSize: badge)
        XCTAssertEqual(rtlLayout.tileFrame.maxX, phoneWidth - ltrLayout.tileFrame.minX, accuracy: 0.001)
        XCTAssertEqual(rtlLayout.accessoryFrame.minX, phoneWidth - ltrLayout.accessoryFrame.maxX, accuracy: 0.001)
        XCTAssertEqual(rtlLayout.size, ltrLayout.size)
    }

    func testRowMeasurementIsStableAndTracksContent() {
        let row = host.host(RCListRow(content: device("Checking", busy: true)))
        let first = row.sizeThatFits(CGSize(width: phoneWidth, height: .greatestFiniteMagnitude))
        XCTAssertEqual(row.sizeThatFits(CGSize(width: phoneWidth, height: .greatestFiniteMagnitude)), first)
        row.configure(device("Online"))
        XCTAssertEqual(row.sizeThatFits(CGSize(width: phoneWidth, height: .greatestFiniteMagnitude)).height, first.height)
        row.configure(.init(title: "Studio iPad", glyph: .tabletSmartphone, trailing: .chevron))
        let withoutDetail = row.sizeThatFits(CGSize(width: phoneWidth, height: .greatestFiniteMagnitude)).height
        XCTAssertLessThan(withoutDetail, first.height, "A content change must invalidate the cached layout")
    }

    func testTrailingViewReservesSpaceBeforeTheAccessory() {
        let row = host.host(RCListRow(content: device("Online")))
        let button = RCIconButton(icon: .ellipsis, variant: .ghost, diameter: 32, accessibilityLabel: "More")
        row.frame = CGRect(x: 0, y: 0, width: phoneWidth, height: 64)
        row.trailingView = button
        row.layoutIfNeeded()
        let layout = row.layout(forWidth: phoneWidth)
        XCTAssertEqual(button.frame, layout.trailingViewFrame)
        XCTAssertLessThanOrEqual(button.frame.maxX, layout.accessoryFrame.minX)
        XCTAssertEqual(row.accessibilityCustomActions?.map(\.name), ["More"])
    }

    func testVoiceOverReadsTitleThenDetailAndStatus() {
        let row = RCListRow(content: device("Offline", detail: "10.0.0.7:8080"))
        row.accessibilityHintText = "Opens remote control"
        XCTAssertTrue(row.isAccessibilityElement)
        XCTAssertEqual(row.accessibilityLabel, "Studio iPad")
        XCTAssertEqual(row.accessibilityValue, "10.0.0.7:8080, Offline")
        XCTAssertEqual(row.accessibilityHint, "Opens remote control")
        XCTAssertTrue(row.accessibilityTraits.contains(.button))
        row.configure(.init(title: "Warm", trailing: .check))
        XCTAssertTrue(row.accessibilityTraits.contains(.selected))
        XCTAssertNil(row.accessibilityValue)
    }

    // MARK: Detail accessory

    private func addressRow(accessory: String? = "rctld 0.3.0-180", trailing: RCListRow.Trailing = .chevron) -> RCListRow.Content {
        .init(title: "Living room iPad", detail: "192.168.1.20:8080", detailAccessory: accessory, detailIsMonospaced: true, glyph: .tabletSmartphone, trailing: trailing)
    }

    /// Row width whose text column is `textWidth` for `content` (no badge, so no stacking decision).
    private func rowWidth(textWidth: CGFloat, for content: RCListRow.Content) -> CGFloat {
        let wide = RCListRow.layout(for: content, width: 1000, traits: standard)
        return textWidth + (1000 - wide.titleFrame.width)
    }

    func testDetailSplitGivesWayAccessoryFirst() {
        typealias Split = (detail: CGFloat, accessory: CGFloat)
        func split(_ available: CGFloat) -> Split {
            RCListRow.detailSplit(detailWidth: 120, accessoryWidth: 130, minimumAccessoryWidth: 60, available: available)
        }
        XCTAssertTrue(split(300) == (120, 130), "Both fit whole")
        XCTAssertTrue(split(250) == (120, 130), "Exactly fits")
        XCTAssertTrue(split(200) == (120, 80), "The accessory truncates; the address keeps its width")
        XCTAssertTrue(split(179) == (179, 0), "Too little left for a readable accessory: it is dropped")
        XCTAssertTrue(split(120) == (120, 0), "The address alone fills the column")
        XCTAssertTrue(split(90) == (90, 0), "Only now is the address shortened")
        XCTAssertTrue(RCListRow.detailSplit(detailWidth: 120, accessoryWidth: 0, minimumAccessoryWidth: 0, available: 200) == (200, 0), "Without an accessory the detail spans the column")
        XCTAssertTrue(RCListRow.detailSplit(detailWidth: 120, accessoryWidth: 40, minimumAccessoryWidth: 60, available: 165) == (120, 40))
        XCTAssertTrue(RCListRow.detailSplit(detailWidth: 120, accessoryWidth: 40, minimumAccessoryWidth: 60, available: 159) == (159, 0), "A short accessory shows whole or not at all")
    }

    func testAccessoryFollowsTheAddressWhenBothFit() {
        let content = addressRow()
        let layout = RCListRow.layout(for: content, width: 1000, traits: standard)
        let addressOnly = RCListRow.layout(for: addressRow(accessory: nil), width: 1000, traits: standard)
        XCTAssertGreaterThan(layout.detailAccessoryFrame.width, 0)
        XCTAssertEqual(layout.detailAccessoryFrame.minX, layout.detailFrame.maxX)
        XCTAssertEqual(layout.detailAccessoryFrame.minY, layout.detailFrame.minY)
        XCTAssertEqual(layout.size.height, addressOnly.size.height, "The accessory shares the detail line")
        XCTAssertLessThan(layout.detailFrame.width, addressOnly.detailFrame.width, "With an accessory the address takes its natural width")
    }

    func testAccessoryTruncatesThenDisappearsBeforeTheAddressShortens() {
        let content = addressRow()
        let natural = RCListRow.layout(for: content, width: 1000, traits: standard)
        let address = natural.detailFrame.width
        let accessory = natural.detailAccessoryFrame.width

        let truncated = RCListRow.layout(for: content, width: rowWidth(textWidth: address + accessory - 30, for: content), traits: standard)
        XCTAssertEqual(truncated.detailFrame.width, address, "The port stays visible")
        XCTAssertEqual(truncated.detailAccessoryFrame.width, accessory - 30, accuracy: 0.5)
        XCTAssertEqual(truncated.detailAccessoryFrame.maxX, truncated.titleFrame.maxX, accuracy: 0.5)

        let dropped = RCListRow.layout(for: content, width: rowWidth(textWidth: address + 12, for: content), traits: standard)
        XCTAssertEqual(dropped.detailAccessoryFrame, .zero, "A sliver of metadata is noise: dropped")
        XCTAssertGreaterThanOrEqual(dropped.detailFrame.width, address)

        let tight = RCListRow.layout(for: content, width: rowWidth(textWidth: address - 20, for: content), traits: standard)
        XCTAssertEqual(tight.detailAccessoryFrame, .zero)
        XCTAssertEqual(tight.detailFrame.width, address - 20, accuracy: 0.5, "Only an address wider than the column is shortened")
    }

    func testSmallPhoneAtLargestTextKeepsTheAddressWhole() {
        let traits = UITraitCollection(traitsFrom: [standard, UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)])
        let content = addressRow(trailing: .badgeAndChevron(text: "Online", tone: .success, busy: false))
        let wide = RCListRow.layout(for: content, width: 2000, traits: traits, badgeSize: badgeSize("Online"))
        // 320 pt phone: 280 pt column.
        let layout = RCListRow.layout(for: content, width: smallPhoneWidth, traits: traits, badgeSize: badgeSize("Online"))
        XCTAssertTrue(layout.isStacked)
        if wide.detailFrame.width <= layout.titleFrame.width {
            XCTAssertEqual(layout.detailFrame.width, wide.detailFrame.width, "The address fits the column, so it is not truncated")
        } else {
            XCTAssertEqual(layout.detailAccessoryFrame, .zero, "An address wider than the column drops the metadata first")
            XCTAssertEqual(layout.detailFrame.width, layout.titleFrame.width)
        }
    }

    func testAccessoryCountsTowardStackingBesideABadge() {
        let badge = badgeSize("Online")
        let trailing = RCListRow.Trailing.badgeAndChevron(text: "Online", tone: .success, busy: false)
        let plain = RCListRow.layout(for: addressRow(accessory: nil, trailing: trailing), width: phoneWidth, traits: standard, badgeSize: badge)
        let withAccessory = RCListRow.layout(for: addressRow(trailing: trailing), width: phoneWidth, traits: standard, badgeSize: badge)
        XCTAssertFalse(plain.isStacked)
        XCTAssertTrue(withAccessory.isStacked, "Metadata that would not fit beside the badge moves the badge down instead of hiding the metadata")
        XCTAssertGreaterThan(withAccessory.detailAccessoryFrame.width, 0)
    }

    func testAccessoryMirrorsAfterTheAddressRightToLeft() {
        let rtl = UITraitCollection(traitsFrom: [standard, UITraitCollection(layoutDirection: .rightToLeft)])
        let layout = RCListRow.layout(for: addressRow(), width: 1000, traits: rtl)
        XCTAssertEqual(layout.detailAccessoryFrame.maxX, layout.detailFrame.minX, accuracy: 0.001, "The accessory reads after the detail")
    }

    func testRowShowsAndSpeaksTheAccessory() {
        let row = host.host(RCListRow(content: addressRow(trailing: .badgeAndChevron(text: "Online", tone: .success, busy: false))))
        row.frame = CGRect(x: 0, y: 0, width: 1000, height: 80)
        row.layoutIfNeeded()
        let labels = row.subviews.compactMap { $0 as? RCLabel }
        let accessory = labels.first { $0.text == " · rctld 0.3.0-180" }
        XCTAssertNotNil(accessory)
        XCTAssertEqual(accessory?.isHidden, false)
        XCTAssertEqual(row.accessibilityValue, "192.168.1.20:8080, rctld 0.3.0-180, Online")

        row.frame.size.width = rowWidth(textWidth: 60, for: addressRow())
        row.layoutIfNeeded()
        XCTAssertEqual(accessory?.isHidden, true, "Dropped on screen")
        XCTAssertEqual(row.accessibilityValue, "192.168.1.20:8080, rctld 0.3.0-180, Online", "Still spoken")
    }

    func testStackedRowCentersTheChevronOnTheRow() {
        let traits = UITraitCollection(traitsFrom: [standard, UITraitCollection(preferredContentSizeCategory: .accessibilityMedium)])
        for layout in [
            RCListRow.layout(for: device("Online"), width: phoneWidth, traits: standard, badgeSize: badgeSize("Online"), forcesStacking: true),
            RCListRow.layout(for: device("Online"), width: phoneWidth, traits: traits, badgeSize: badgeSize("Online")),
        ] {
            XCTAssertTrue(layout.isStacked)
            XCTAssertEqual(layout.accessoryFrame.midY, layout.size.height / 2, accuracy: 0.5, "The chevron belongs to the whole row, badge line included")
        }
    }

    func testDisabledAppearanceStillSendsTaps() {
        var taps = 0
        let row = RCListRow(content: .init(title: "Workshop iPad", glyph: .tablet, trailing: .badge(text: "Offline", tone: .neutral, busy: false), appearsEnabled: false))
        row.onTap = { taps += 1 }
        row.haptic = nil
        XCTAssertTrue(row.accessibilityActivate())
        XCTAssertEqual(taps, 1)
    }
}
