import UIKit
import XCTest
@testable import RctlUIKit

/// Solid top bar opacity and alignment of bar items with the page column.
@MainActor
final class RCTopBarColumnTests: XCTestCase {
    private func iconButton(_ glyph: RCIconGlyph) -> RCIconButton {
        RCIconButton(icon: glyph, accessibilityLabel: glyph.rawValue)
    }

    func testSolidBarIsFullyOpaque() {
        let bar = RCTopBar(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
        bar.setScrollProgress(1)
        let layer = bar.backgroundLayerForTesting
        XCTAssertEqual(layer.opacity, 1)
        XCTAssertEqual(layer.backgroundColor?.alpha, 1, "no translucency: scrolled text must not ghost through")
        bar.setScrollProgress(0.5)
        XCTAssertEqual(layer.opacity, 0.5, accuracy: 0.001, "the progress-driven fade in is kept")
        bar.setScrollProgress(0)
        XCTAssertEqual(layer.opacity, 0)
    }

    func testItemsHugTheScreenEdgesWithoutAColumn() {
        let bar = RCTopBar(frame: CGRect(x: 0, y: 0, width: 1024, height: RCLayout.topBarHeight))
        bar.showsBackButton = true
        let more = iconButton(.ellipsis)
        bar.trailingViews = [more]
        bar.layoutIfNeeded()
        XCTAssertNil(bar.contentColumnWidth)
        XCTAssertEqual(bar.backButton.frame.minX, RCTopBar.edgeInset, accuracy: 0.5)
        XCTAssertEqual(more.frame.maxX, 1024 - RCTopBar.edgeInset, accuracy: 0.5)
    }

    func testItemsAlignWithTheContentColumnOnWideScreens() {
        let width: CGFloat = 1024
        let bar = RCTopBar(frame: CGRect(x: 0, y: 0, width: width, height: RCLayout.topBarHeight))
        bar.showsBackButton = true
        let mark = RCBrandMark(side: 28)
        bar.leadingViews = [mark]
        let refresh = iconButton(.refreshCw), more = iconButton(.ellipsis)
        bar.trailingViews = [refresh, more]
        bar.contentColumnWidth = RCLayout.maxContentWidth
        bar.layoutIfNeeded()

        let column = RCLayout.columnInset(width: width, safeArea: .zero, maxWidth: RCLayout.maxContentWidth)
        let outset = RCLayout.gutter - RCTopBar.edgeInset
        XCTAssertEqual(bar.backButton.frame.minX, column.left - outset, accuracy: 0.5, "glyph lines up with the column like on a phone")
        XCTAssertEqual(more.frame.maxX, width - column.right + outset, accuracy: 0.5)
        XCTAssertEqual(mark.frame.minX - bar.backButton.frame.maxX, RCTopBar.itemSpacing, accuracy: 0.5)
        XCTAssertEqual(more.frame.minX - refresh.frame.maxX, RCTopBar.itemSpacing, accuracy: 0.5)
        XCTAssertGreaterThan(bar.backButton.frame.minX, 150, "not at the screen edge on iPad")

        bar.contentColumnWidth = RCLayout.maxFormWidth
        bar.layoutIfNeeded()
        let form = RCLayout.columnInset(width: width, safeArea: .zero, maxWidth: RCLayout.maxFormWidth)
        XCTAssertEqual(bar.backButton.frame.minX, form.left - outset, accuracy: 0.5)
    }

    func testColumnMatchesPhoneLayoutWhenTheScreenIsNarrow() {
        let bar = RCTopBar(frame: CGRect(x: 0, y: 0, width: 390, height: RCLayout.topBarHeight))
        bar.showsBackButton = true
        bar.contentColumnWidth = RCLayout.maxContentWidth
        bar.layoutIfNeeded()
        XCTAssertEqual(bar.backButton.frame.minX, RCTopBar.edgeInset, accuracy: 0.5)
    }

    func testColumnAlignmentMirrorsInRightToLeft() {
        let width: CGFloat = 1024
        let bar = RCTopBar(frame: CGRect(x: 0, y: 0, width: width, height: RCLayout.topBarHeight))
        bar.semanticContentAttribute = .forceRightToLeft
        bar.showsBackButton = true
        let more = iconButton(.ellipsis)
        bar.trailingViews = [more]
        bar.contentColumnWidth = RCLayout.maxContentWidth
        bar.layoutIfNeeded()
        let column = RCLayout.columnInset(width: width, safeArea: .zero, maxWidth: RCLayout.maxContentWidth)
        let outset = RCLayout.gutter - RCTopBar.edgeInset
        XCTAssertEqual(bar.backButton.frame.maxX, width - column.right + outset, accuracy: 0.5)
        XCTAssertEqual(more.frame.minX, column.left - outset, accuracy: 0.5)
    }

    func testItemEdgesIncludeSafeAreaInsets() {
        let safe = UIEdgeInsets(top: 0, left: 59, bottom: 0, right: 59)
        let plain = RCTopBar.itemEdges(width: 932, safeArea: safe, contentColumnWidth: nil, isRightToLeft: false)
        XCTAssertEqual(plain.leading, 59 + RCTopBar.edgeInset, accuracy: 0.001)
        let column = RCTopBar.itemEdges(width: 932, safeArea: safe, contentColumnWidth: RCLayout.maxContentWidth, isRightToLeft: false)
        let inset = RCLayout.columnInset(width: 932, safeArea: safe)
        XCTAssertEqual(column.leading, inset.left - (RCLayout.gutter - RCTopBar.edgeInset), accuracy: 0.001)
        XCTAssertEqual(column.trailing, inset.right - (RCLayout.gutter - RCTopBar.edgeInset), accuracy: 0.001)
    }
}
