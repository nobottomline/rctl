import XCTest
@testable import RctlUIKit

@MainActor
final class RCTopBarTests: XCTestCase {
    private func makeBar(width: CGFloat = 375) -> RCTopBar {
        let bar = RCTopBar(frame: CGRect(x: 0, y: 0, width: width, height: RCLayout.topBarHeight))
        return bar
    }

    private func button(_ glyph: RCIconGlyph) -> RCIconButton {
        RCIconButton(icon: glyph, accessibilityLabel: glyph.rawValue)
    }

    func testPreferredHeightExtendsUnderStatusBar() {
        XCTAssertEqual(makeBar().preferredHeight(safeAreaTop: 59), 59 + 52)
    }

    func testLongTitleNeverOverlapsSideItems() {
        let bar = makeBar(width: 320)
        bar.showsBackButton = true
        bar.title = "A remarkably long device name that cannot possibly fit in the bar"
        let trailing = [button(.keyboard), button(.settings), button(.ellipsis)]
        bar.trailingViews = trailing
        bar.setScrollProgress(1)
        bar.layoutIfNeeded()
        let title = bar.titleLabel.frame
        XCTAssertGreaterThan(title.width, 0)
        for item in [bar.backButton] + trailing {
            XCTAssertFalse(title.intersects(item.frame), "title \(title) overlaps \(item.frame)")
            XCTAssertGreaterThanOrEqual(min(abs(title.minX - item.frame.maxX), abs(item.frame.minX - title.maxX)), RCTopBar.titleSpacing - 0.5)
        }
    }

    func testShortTitleIsCenteredOnTheBar() {
        let bar = makeBar(width: 390)
        bar.showsBackButton = true
        bar.title = "Devices"
        bar.trailingViews = [button(.plus), button(.ellipsis)]
        bar.layoutIfNeeded()
        XCTAssertEqual(bar.titleLabel.frame.midX, 195, accuracy: 0.5)
    }

    func testItemsKeepSpacingAndOrder() {
        let bar = makeBar(width: 390)
        bar.showsBackButton = true
        let mark = RCBrandMark(side: 28)
        bar.leadingViews = [mark]
        let first = button(.refreshCw), second = button(.plus)
        bar.trailingViews = [first, second]
        bar.layoutIfNeeded()
        XCTAssertEqual(bar.backButton.frame.minX, RCTopBar.edgeInset, accuracy: 0.5)
        XCTAssertEqual(bar.backButton.frame.size, CGSize(width: 40, height: 40))
        XCTAssertEqual(mark.frame.minX - bar.backButton.frame.maxX, RCTopBar.itemSpacing, accuracy: 0.5)
        XCTAssertEqual(second.frame.maxX, 390 - RCTopBar.edgeInset, accuracy: 0.5)
        XCTAssertEqual(second.frame.minX - first.frame.maxX, RCTopBar.itemSpacing, accuracy: 0.5)
        XCTAssertEqual(bar.backButton.frame.midY, RCLayout.topBarHeight / 2, accuracy: 0.5)
    }

    func testRightToLeftMirrorsItemsAndFlipsChevron() {
        let bar = makeBar(width: 390)
        bar.semanticContentAttribute = .forceRightToLeft
        bar.showsBackButton = true
        let trailing = button(.ellipsis)
        bar.trailingViews = [trailing]
        bar.layoutIfNeeded()
        XCTAssertEqual(bar.backButton.frame.maxX, 390 - RCTopBar.edgeInset, accuracy: 0.5)
        XCTAssertEqual(trailing.frame.minX, RCTopBar.edgeInset, accuracy: 0.5)
        XCTAssertEqual(bar.backButton.icon, .chevronRight)
        bar.semanticContentAttribute = .forceLeftToRight
        bar.layoutIfNeeded()
        XCTAssertEqual(bar.backButton.icon, .chevronLeft)
    }

    func testTransparentAreasPassTouchesThroughOnlyAtRest() {
        let bar = makeBar(width: 390)
        bar.showsBackButton = true
        bar.layoutIfNeeded()
        let empty = CGPoint(x: 195, y: 26)
        XCTAssertNil(bar.hitTest(empty, with: nil))
        XCTAssertTrue(bar.hitTest(CGPoint(x: bar.backButton.frame.midX, y: bar.backButton.frame.midY), with: nil) === bar.backButton)
        // 44 pt hit target around the 40 pt circle.
        XCTAssertTrue(bar.hitTest(CGPoint(x: bar.backButton.frame.minX - 1.5, y: bar.backButton.frame.midY), with: nil) === bar.backButton)
        bar.setScrollProgress(1)
        XCTAssertTrue(bar.hitTest(empty, with: nil) === bar)
        bar.isOverlayStyle = true
        XCTAssertNil(bar.hitTest(empty, with: nil))
    }

    func testProgressDrivesTitleAndIsClamped() {
        let bar = makeBar()
        bar.title = "Devices"
        bar.setScrollProgress(0)
        XCTAssertEqual(bar.titleLabel.alpha, 0)
        bar.setScrollProgress(4)
        XCTAssertEqual(bar.scrollProgress, 1)
        XCTAssertEqual(bar.titleLabel.alpha, 1)
        bar.setScrollProgress(.nan)
        XCTAssertEqual(bar.scrollProgress, 0)
        bar.showsTitleAtRest = true
        XCTAssertEqual(bar.titleLabel.alpha, 1)
    }

    func testTrackUsesAdjustedInset() {
        let bar = makeBar()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 600))
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentInset.top = 100
        scrollView.contentOffset.y = -100 + 22
        bar.track(scrollView, distance: 44)
        XCTAssertEqual(bar.scrollProgress, 0.5, accuracy: 0.001)
    }

    func testReplacingItemsKeepsReusedViews() {
        let bar = makeBar()
        let kept = button(.plus), dropped = button(.ellipsis)
        bar.trailingViews = [kept, dropped]
        bar.trailingViews = [kept]
        XCTAssertTrue(kept.superview === bar)
        XCTAssertNil(dropped.superview)
    }
}

@MainActor
final class RCLargeTitleViewTests: XCTestCase {
    func testSizeIncludesSubtitleOnlyWhenPresent() {
        let view = RCLargeTitleView(title: "Devices")
        let titleOnly = view.sizeThatFits(CGSize(width: 335, height: CGFloat.greatestFiniteMagnitude)).height
        view.subtitle = "2 nearby"
        let withSubtitle = view.sizeThatFits(CGSize(width: 335, height: CGFloat.greatestFiniteMagnitude)).height
        XCTAssertGreaterThan(withSubtitle, titleOnly + RCLargeTitleView.subtitleSpacing)
        view.subtitle = nil
        XCTAssertEqual(view.sizeThatFits(CGSize(width: 335, height: CGFloat.greatestFiniteMagnitude)).height, titleOnly)
    }

    func testCollapseProgressTracksTitlePassingUnderBar() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 700))
        let title = RCLargeTitleView(title: "Devices", subtitle: "Subtitle")
        scrollView.addSubview(title)
        let height = title.sizeThatFits(CGSize(width: 335, height: CGFloat.greatestFiniteMagnitude)).height
        title.frame = CGRect(x: 20, y: 120, width: 335, height: height)
        title.layoutIfNeeded()
        let titleHeight = title.titleLabel.frame.height
        let barBottom: CGFloat = 111

        scrollView.contentOffset.y = 0
        XCTAssertEqual(title.collapseProgress(in: scrollView, topBarHeight: barBottom), 0)
        scrollView.contentOffset.y = 120 - barBottom
        XCTAssertEqual(title.collapseProgress(in: scrollView, topBarHeight: barBottom), 0, accuracy: 0.001)
        scrollView.contentOffset.y = 120 - barBottom + titleHeight / 2
        XCTAssertEqual(title.collapseProgress(in: scrollView, topBarHeight: barBottom), 0.5, accuracy: 0.001)
        scrollView.contentOffset.y = 120 - barBottom + titleHeight
        XCTAssertEqual(title.collapseProgress(in: scrollView, topBarHeight: barBottom), 1, accuracy: 0.001)
        scrollView.contentOffset.y = -80
        XCTAssertEqual(title.collapseProgress(in: scrollView, topBarHeight: barBottom), 0)
    }

    func testCollapseProgressIsZeroOutsideTheScrollView() {
        let title = RCLargeTitleView(title: "Devices")
        title.frame = CGRect(x: 0, y: 0, width: 300, height: 40)
        XCTAssertEqual(title.collapseProgress(in: UIScrollView(), topBarHeight: 100), 0)
    }
}
