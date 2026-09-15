import XCTest
@testable import RctlUIKit

final class RCDialogLayoutTests: XCTestCase {
    typealias Layout = RCDialogActionLayout

    func testSingleActionIsFullWidth() {
        XCTAssertEqual(Layout.arrangement(styles: [.primary], titlesFitSideBySide: true), .init(axis: .vertical, order: [0]))
    }

    func testTwoFittingActionsSitSideBySideWithConfirmTrailing() {
        XCTAssertEqual(Layout.arrangement(styles: [.destructive, .cancel], titlesFitSideBySide: true), .init(axis: .horizontal, order: [1, 0]))
        XCTAssertEqual(Layout.arrangement(styles: [.cancel, .primary], titlesFitSideBySide: true), .init(axis: .horizontal, order: [0, 1]))
        XCTAssertEqual(Layout.arrangement(styles: [.primary, .secondary], titlesFitSideBySide: true), .init(axis: .horizontal, order: [1, 0]))
        XCTAssertEqual(Layout.arrangement(styles: [.secondary, .secondary], titlesFitSideBySide: true), .init(axis: .horizontal, order: [0, 1]), "Equal rank keeps the given order")
    }

    func testTwoLongActionsStackWithConfirmFirst() {
        XCTAssertEqual(Layout.arrangement(styles: [.cancel, .destructive], titlesFitSideBySide: false), .init(axis: .vertical, order: [1, 0]))
    }

    func testThreeActionsAlwaysStack() {
        XCTAssertEqual(
            Layout.arrangement(styles: [.cancel, .secondary, .destructive], titlesFitSideBySide: true),
            .init(axis: .vertical, order: [2, 1, 0])
        )
    }

    @MainActor
    func testStyleMapping() {
        XCTAssertEqual(Layout.buttonVariant(for: .primary), .primary)
        XCTAssertEqual(Layout.buttonVariant(for: .secondary), .secondary)
        XCTAssertEqual(Layout.buttonVariant(for: .destructive), .destructive)
        XCTAssertEqual(Layout.buttonVariant(for: .cancel), .secondary)
    }
}
