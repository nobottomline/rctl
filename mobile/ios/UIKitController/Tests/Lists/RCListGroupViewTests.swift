import XCTest
@testable import RctlUIKit

@MainActor
final class RCListGroupViewTests: XCTestCase {
    private let width: CGFloat = 362
    private var host: ListsTraitHost!

    override func setUp() async throws {
        host = ListsTraitHost(category: .large)
    }

    override func tearDown() async throws {
        host.tearDown()
        host = nil
    }

    private func row(_ title: String) -> RCListRow {
        RCListRow(content: .init(title: title, detail: "192.168.1.20:8080", detailIsMonospaced: true, glyph: .tabletSmartphone, trailing: .badgeAndChevron(text: "Online", tone: .success, busy: false)))
    }

    func testDiffReportsInsertedRemovedAndMovedIDs() {
        let diff = RCListGroupView.diff(from: ["a", "b", "c", "d"], to: ["d", "a", "e", "c"])
        XCTAssertEqual(diff.inserted, ["e"])
        XCTAssertEqual(diff.removed, ["b"])
        XCTAssertEqual(diff.moved, ["d"])
    }

    func testDiffOrdersRemovalsByOldPosition() {
        let diff = RCListGroupView.diff(from: ["a", "b", "c", "d"], to: ["c"])
        XCTAssertEqual(diff.removed, ["a", "b", "d"])
        XCTAssertTrue(diff.inserted.isEmpty)
        XCTAssertTrue(diff.moved.isEmpty)
    }

    func testIdenticalListsProduceEmptyDiff() {
        XCTAssertTrue(RCListGroupView.diff(from: ["a", "b"], to: ["a", "b"]).isEmpty)
        XCTAssertEqual(RCListGroupView.diff(from: [], to: ["a"]).inserted, ["a"])
    }

    func testSetItemsStacksRowsAndReportsFittedHeight() {
        let group = RCListGroupView()
        group.frame = CGRect(x: 0, y: 0, width: width, height: 0)
        var reported: [CGFloat] = []
        group.onHeightChange = { reported.append($0) }
        let rows = [row("Studio"), row("Kitchen"), row("Living room")]
        group.setItems(rows.enumerated().map { .init(id: "\($0.offset)", view: $0.element) }, animated: false)

        let rowHeight = rows[0].sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let expected = rowHeight * 3 + group.contentInsets.top + group.contentInsets.bottom
        XCTAssertEqual(reported, [expected])
        XCTAssertEqual(group.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height, expected)

        group.frame.size.height = expected
        group.layoutIfNeeded()
        XCTAssertEqual(rows[0].frame.minY, 0)
        XCTAssertEqual(rows[1].frame.minY, rows[0].frame.maxY)
        XCTAssertEqual(rows[2].frame.minY, rows[1].frame.maxY)
        let separators = group.contentView.subviews.compactMap { $0 as? RCSeparator }
        XCTAssertEqual(separators.count, 2, "One separator between each pair of rows")
        XCTAssertEqual(group.contentView.accessibilityElements?.count, 3)
    }

    func testBadgeRowsInOneGroupStackTogether() {
        let group = host.host(RCListGroupView())
        let short = RCListRow(content: .init(title: "Kitchen", detail: "10.0.0.7:8080", detailIsMonospaced: true, glyph: .tablet, trailing: .badgeAndChevron(text: "Offline", tone: .attention, busy: false)))
        let long = RCListRow(content: .init(title: "Studio", detail: "192.168.100.200:8080 · saved as Living room", detailIsMonospaced: true, glyph: .tablet, trailing: .badgeAndChevron(text: "Online", tone: .success, busy: false)))
        let add = RCListRow(content: .init(title: "Add local device", glyph: .wifi, tileTone: .dashed, trailing: .plus))
        let size = CGSize(width: width, height: .greatestFiniteMagnitude)
        let shortAlone = host.host(short).sizeThatFits(size).height
        group.setItems([.init(id: "short", view: short), .init(id: "long", view: long), .init(id: "add", view: add)], animated: false)
        _ = group.sizeThatFits(size)
        XCTAssertTrue(short.layout(forWidth: width).isStacked, "Short row follows the stacked row")
        XCTAssertEqual(short.sizeThatFits(size).height, long.sizeThatFits(size).height)
        XCTAssertGreaterThan(short.sizeThatFits(size).height, shortAlone)
        XCTAssertFalse(add.layout(forWidth: width).isStacked, "Rows without a badge are unaffected")

        group.setItems([.init(id: "short", view: short), .init(id: "add", view: add)], animated: false)
        _ = group.sizeThatFits(size)
        XCTAssertFalse(short.layout(forWidth: width).isStacked, "Stacking is released when no row needs it")
        XCTAssertEqual(short.sizeThatFits(size).height, shortAlone)
    }

    func testReusedViewsKeepIdentityAndRemovedViewsLeave() {
        let group = RCListGroupView()
        group.frame = CGRect(x: 0, y: 0, width: width, height: 200)
        let studio = row("Studio"), kitchen = row("Kitchen"), living = row("Living room")
        group.setItems([.init(id: "s", view: studio), .init(id: "k", view: kitchen), .init(id: "l", view: living)], animated: false)
        group.setItems([.init(id: "l", view: living), .init(id: "s", view: studio)], animated: false)
        XCTAssertNil(kitchen.superview)
        XCTAssertTrue(studio.superview === group.contentView)
        XCTAssertEqual(group.items.map(\.id), ["l", "s"])
        group.layoutIfNeeded()
        XCTAssertEqual(living.frame.minY, 0)
        XCTAssertEqual(group.contentView.subviews.compactMap { $0 as? RCSeparator }.count, 1)
    }

    func testDuplicateIDsAreIgnored() {
        let group = RCListGroupView()
        let first = row("First"), second = row("Second")
        group.setItems([.init(id: "same", view: first), .init(id: "same", view: second)], animated: false)
        XCTAssertEqual(group.items.count, 1)
        XCTAssertTrue(group.items[0].view === first)
        XCTAssertNil(second.superview)
    }

    func testPlaceholderMatchesStackedRowsAtAccessibilitySizes() {
        let large = ListsTraitHost(category: .accessibilityExtraLarge)
        defer { large.tearDown() }
        let placeholder = large.host(RCListGroupView.placeholder(rows: 2))
        let loaded = large.host(RCListGroupView())
        loaded.setItems((0..<2).map { .init(id: "\($0)", view: row("Device \($0)")) }, animated: false)
        let size = CGSize(width: width, height: .greatestFiniteMagnitude)
        XCTAssertEqual(placeholder.sizeThatFits(size).height, loaded.sizeThatFits(size).height)
    }

    func testPlaceholderMatchesDeviceRowHeightsAndHandsOffToRows() {
        let placeholder = host.host(RCListGroupView.placeholder(rows: 3))
        XCTAssertTrue(placeholder.isShowingPlaceholder)
        XCTAssertTrue(placeholder.isAccessibilityElement)
        XCTAssertEqual(placeholder.accessibilityLabel, "Loading")

        let loaded = host.host(RCListGroupView())
        loaded.setItems((0..<3).map { .init(id: "\($0)", view: row("Device \($0)")) }, animated: false)
        let size = CGSize(width: width, height: .greatestFiniteMagnitude)
        XCTAssertEqual(placeholder.sizeThatFits(size).height, loaded.sizeThatFits(size).height, "Loading must not change the card height")

        placeholder.setItems([.init(id: "a", view: row("A"))], animated: false)
        XCTAssertFalse(placeholder.isShowingPlaceholder)
        XCTAssertFalse(placeholder.isAccessibilityElement)
    }

    func testAnimatedChangeMovesShadowWithTheCard() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let host = UIView(frame: window.bounds)
        window.addSubview(host)
        window.isHidden = false
        defer { window.isHidden = true }

        let group = RCListGroupView()
        host.addSubview(group)
        let rows = [row("Studio"), row("Kitchen")]
        group.onHeightChange = { height in group.frame.size.height = height; group.layoutIfNeeded() }
        group.frame = CGRect(x: 20, y: 20, width: width, height: 0)
        group.setItems([.init(id: "s", view: rows[0])], animated: false)
        group.layoutIfNeeded()

        group.setItems([.init(id: "s", view: rows[0]), .init(id: "k", view: rows[1])], animated: true)
        guard !RCMotion.reduceMotion else { return }
        XCTAssertNotNil(group.layer.animationKeys()?.first { $0.hasPrefix("bounds") }, "Height change should animate")
        XCTAssertNotNil(group.layer.animation(forKey: "rc.shadowPath"), "Shadow path must follow the animated bounds")
        XCTAssertNotNil(rows[1].layer.animation(forKey: "rc.fadeIn"), "Inserted rows fade in")
    }

    /// Spins the main run loop until `condition` holds (dispatches and animation completions run).
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return true
    }

    func testReplaceFadesTheOldStateOutBeforeTheNewStateArrives() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.isHidden = false
        defer { window.isHidden = true }
        let group = RCListGroupView()
        window.addSubview(group)
        var heights: [CGFloat] = []
        group.onHeightChange = { height in
            heights.append(height)
            group.frame.size.height = height
            group.layoutIfNeeded()
        }
        group.frame = CGRect(x: 20, y: 20, width: width, height: 0)
        group.showPlaceholder(rows: 1, animated: false)
        heights.removeAll()
        group.layoutIfNeeded()
        let skeletons = group.items.map(\.view)
        let studio = row("Studio"), kitchen = row("Kitchen"), living = row("Living room")

        group.setItems([.init(id: "s", view: studio), .init(id: "k", view: kitchen), .init(id: "l", view: living)], transition: .replace)
        XCTAssertTrue(group.isShowingPlaceholder, "The skeleton stays on screen while it fades out")
        XCTAssertFalse(group.isTargetPlaceholder)
        XCTAssertEqual(group.targetItemIDs, ["s", "k", "l"])
        XCTAssertNil(studio.superview, "New rows are not shown on top of the old state")
        XCTAssertTrue(heights.isEmpty, "The card does not reflow until the old state is gone")
        XCTAssertTrue(skeletons.allSatisfy { $0.alpha == 0 && !$0.isUserInteractionEnabled })

        // A change during the fade-out retargets it instead of overlapping two transitions.
        group.setItems([.init(id: "s", view: studio), .init(id: "k", view: kitchen)], transition: .rows)
        XCTAssertEqual(group.targetItemIDs, ["s", "k"])

        XCTAssertTrue(waitUntil { group.items.map(\.id) == ["s", "k"] })
        XCTAssertFalse(group.isShowingPlaceholder)
        XCTAssertTrue(skeletons.allSatisfy { $0.superview == nil }, "Faded rows leave without a second fade")
        XCTAssertEqual(heights.count, 1, "One reflow, after the fade-out")
        XCTAssertTrue(studio.superview === group.contentView)
        XCTAssertNil(living.superview)
        if !RCMotion.reduceMotion {
            XCTAssertEqual(studio.layer.animation(forKey: "rc.fadeIn")?.duration, RCListGroupView.replaceFadeInDuration)
            XCTAssertEqual(studio.layer.animation(forKey: "rc.fadeIn")?.beginTime ?? 0, studio.layer.convertTime(CACurrentMediaTime(), from: nil), accuracy: 0.1, "Arrivals start fading in right away")
        }
    }

    func testReplaceBackToTheShownRowsRestoresThem() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.isHidden = false
        defer { window.isHidden = true }
        let group = RCListGroupView()
        window.addSubview(group)
        group.frame = CGRect(x: 20, y: 20, width: width, height: 200)
        let notice = row("Looking for devices"), found = row("Kitchen iPad")
        group.setItems([.init(id: "notice", view: notice)], animated: false)

        group.setItems([.init(id: "found", view: found)], transition: .replace)
        group.setItems([.init(id: "notice", view: notice)], transition: .replace)
        XCTAssertTrue(waitUntil { group.targetItemIDs == group.items.map(\.id) && notice.isUserInteractionEnabled })
        XCTAssertEqual(group.items.map(\.id), ["notice"])
        XCTAssertEqual(notice.alpha, 1)
        XCTAssertFalse(notice.accessibilityElementsHidden)
        XCTAssertNil(found.superview)

        // An immediate change cancels a running replacement outright.
        group.setItems([.init(id: "found", view: found)], transition: .replace)
        group.setItems([.init(id: "notice", view: notice)], transition: .none)
        XCTAssertEqual(notice.alpha, 1)
        XCTAssertTrue(notice.isUserInteractionEnabled)
        XCTAssertEqual(group.targetItemIDs, ["notice"])
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(group.items.map(\.id), ["notice"], "The cancelled replacement never completes")
        XCTAssertNil(found.superview)
    }
}
