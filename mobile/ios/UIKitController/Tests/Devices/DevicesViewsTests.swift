import XCTest
@testable import RctlUIKit

/// Devices building blocks: measurements are reused across layout passes and
/// the Nearby header controls never overlap.
@MainActor
final class DevicesViewsTests: XCTestCase {
    private var host: ListsTraitHost!

    override func setUp() async throws {
        host = ListsTraitHost(category: .large)
    }

    override func tearDown() async throws {
        host.tearDown()
        host = nil
    }

    func testMeasureCacheIsKeyedByWidthCategoryAndContent() {
        var cache = DevicesMeasureCache<CGFloat>()
        var measured = 0
        func height(_ width: CGFloat, _ category: UIContentSizeCategory = .large, _ content: String = "A") -> CGFloat {
            cache.value(width: width, category: category, content: content) {
                measured += 1
                return width / 10
            }
        }
        XCTAssertEqual(height(100), 10)
        XCTAssertEqual(height(100), 10)
        XCTAssertEqual(measured, 1, "Same width, traits and text: measured once")
        _ = height(200)
        _ = height(100)
        XCTAssertEqual(measured, 2, "Each width keeps its own entry")
        _ = height(100, .accessibilityLarge)
        XCTAssertEqual(measured, 3, "A content size category change re-measures")
        _ = height(100, .large, "B")
        _ = height(200, .large, "B")
        XCTAssertEqual(measured, 5, "New text drops every stale entry")
        cache.invalidate()
        _ = height(100, .large, "B")
        XCTAssertEqual(measured, 6)
    }

    func testStatusRowMeasuresOncePerWidthAcrossSizingAndLayout() {
        let row = host.host(DevicesStatusRowView())
        row.configure(glyph: .search, busy: false, title: "No devices found",
                      message: "Make sure the device is on this network with LAN control on.",
                      actions: [.init("Add by address", prominent: true) {}])
        let size = row.sizeThatFits(CGSize(width: 362, height: CGFloat.greatestFiniteMagnitude))
        let measured = row.measurementCount
        row.frame = CGRect(origin: .zero, size: size)
        row.layoutIfNeeded()
        _ = row.sizeThatFits(CGSize(width: 362, height: CGFloat.greatestFiniteMagnitude))
        row.setNeedsLayout()
        row.layoutIfNeeded()
        XCTAssertEqual(row.measurementCount, measured, "Placement and repeated sizing reuse the measurement")

        row.configure(glyph: .search, busy: false, title: "No devices found", message: "Shorter.", actions: [])
        let shorter = row.sizeThatFits(CGSize(width: 362, height: CGFloat.greatestFiniteMagnitude))
        XCTAssertEqual(row.measurementCount, measured + 1, "New content is measured again")
        XCTAssertLessThan(shorter.height, size.height)
    }

    func testSummarySizesForTheNewTextImmediately() {
        let summary = host.host(DevicesSummaryView())
        summary.configure(text: "No devices yet.", showsDot: false, animated: false)
        let width: CGFloat = 120
        let one = summary.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        summary.configure(text: "12 online · 48 devices on this network", showsDot: true, animated: true)
        XCTAssertEqual(summary.text, "12 online · 48 devices on this network")
        XCTAssertGreaterThan(summary.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height, one,
                             "The page reflows for the incoming text while the old text fades out")
        XCTAssertEqual(summary.accessibilityLabel, "12 online · 48 devices on this network")
    }

    func testSearchSlotSwapsSpinnerAndButtonInOnePlace() {
        let button = RCIconButton(icon: .refreshCw, variant: .ghost, diameter: 32, iconSize: 16, accessibilityLabel: "Search again")
        let slot = host.host(DevicesSearchSlot(button: button))
        let stop = RCIconButton(icon: .x, variant: .ghost, diameter: 32, iconSize: 16, accessibilityLabel: "Stop searching")
        let stack = host.host(DevicesAccessoryStack())
        stack.arrangedViews = [slot, stop]

        slot.setSearching(true, animated: false)
        let searchingSize = stack.sizeThatFits(.zero)
        stack.frame = CGRect(origin: CGPoint(x: 100, y: 100), size: searchingSize)
        stack.layoutIfNeeded()
        let stopFrame = stop.frame
        XCTAssertTrue(button.isHidden)
        XCTAssertFalse(slot.spinner.isHidden)
        XCTAssertTrue(slot.spinner.isAnimating)

        slot.setSearching(false, animated: false)
        stack.setNeedsLayout()
        stack.layoutIfNeeded()
        XCTAssertEqual(stack.sizeThatFits(.zero), searchingSize, "Stop never moves when the slot changes")
        XCTAssertEqual(stop.frame, stopFrame)
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(slot.spinner.isHidden)
        XCTAssertFalse(slot.spinner.isAnimating)

        // 44 pt hit areas of neighbouring 32 pt buttons touch but do not overlap.
        let buttonHit = button.convert(button.bounds.insetBy(dx: -6, dy: -6), to: stack)
        let stopHit = stop.convert(stop.bounds.insetBy(dx: -6, dy: -6), to: stack)
        XCTAssertLessThanOrEqual(buttonHit.maxX, stopHit.minX + 0.5)
        let between = CGPoint(x: (slot.frame.maxX + stop.frame.minX) / 2, y: stop.frame.midY)
        XCTAssertFalse(button.point(inside: stack.convert(between, to: button), with: nil) && stop.point(inside: stack.convert(between, to: stop), with: nil))
    }

    func testSectionPlacementReusesItsMeasurement() {
        let accessory = CountingView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        let section = host.host(DevicesSectionView(title: "Nearby"))
        section.setHeader(subtitle: "2 found", accessory: accessory)
        section.setRows([.init(id: "a", view: RCListRow(content: .init(title: "A", detail: "192.168.1.2:8080", detailIsMonospaced: true, glyph: .tablet)))], animated: false)
        let fit = CGSize(width: 362, height: CGFloat.greatestFiniteMagnitude)

        accessory.sizeCalls = 0
        let height = section.sizeThatFits(fit).height
        section.frame = CGRect(x: 0, y: 0, width: 362, height: height)
        section.layoutIfNeeded()
        // iOS 15 and earlier run one more header layout pass when the section's
        // frame is first set; the caching guarantee is the unchanged-header check below.
        let firstPlacementBudget = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 16, minorVersion: 0, patchVersion: 0)) ? 2 : 3
        XCTAssertLessThanOrEqual(accessory.sizeCalls, firstPlacementBudget, "One header measurement for sizing plus the header's own layout")

        accessory.sizeCalls = 0
        XCTAssertEqual(section.sizeThatFits(fit).height, height)
        section.setNeedsLayout()
        section.layoutIfNeeded()
        XCTAssertEqual(accessory.sizeCalls, 0, "An unchanged header is not measured again")

        section.setHeader(subtitle: "Searching", accessory: accessory)
        _ = section.sizeThatFits(fit)
        XCTAssertGreaterThan(accessory.sizeCalls, 0, "A header change is measured again")
    }

    func testBrandCollapsesToTheMark() {
        let brand = host.host(DevicesBrandView())
        let expanded = brand.sizeThatFits(.zero)
        XCTAssertTrue(brand.setCollapsed(true, animated: false))
        XCTAssertFalse(brand.setCollapsed(true, animated: false), "No change, no top bar layout")
        let collapsed = brand.sizeThatFits(.zero)
        XCTAssertEqual(collapsed.width, 28)
        XCTAssertLessThan(collapsed.width, expanded.width)
        XCTAssertEqual(brand.accessibilityLabel, "rctl", "The brand is still announced")
        XCTAssertTrue(brand.setCollapsed(false, animated: false))
        XCTAssertEqual(brand.sizeThatFits(.zero), expanded)
    }
}

private final class CountingView: UIView {
    var sizeCalls = 0

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        sizeCalls += 1
        return CGSize(width: 32, height: 32)
    }
}
