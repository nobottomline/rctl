import UIKit
import XCTest
@testable import RctlUIKit

final class RemoteSessionLayoutTests: XCTestCase {
    private struct Screen {
        let name: String
        let size: CGSize
        let safeArea: UIEdgeInsets
    }

    private let screens = [
        Screen(name: "iPhone SE 1st gen", size: CGSize(width: 320, height: 568), safeArea: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0)),
        Screen(name: "iPhone SE landscape", size: CGSize(width: 667, height: 375), safeArea: .zero),
        Screen(name: "iPhone 16 Pro", size: CGSize(width: 402, height: 874), safeArea: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)),
        Screen(name: "iPhone 16 Pro landscape", size: CGSize(width: 874, height: 402), safeArea: UIEdgeInsets(top: 0, left: 62, bottom: 21, right: 62)),
        Screen(name: "iPad Air 11", size: CGSize(width: 820, height: 1180), safeArea: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)),
        Screen(name: "iPad Air 11 landscape", size: CGSize(width: 1180, height: 820), safeArea: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0)),
    ]

    private func layout(_ screen: Screen, panelHeight: CGFloat? = nil, keyboard: CGFloat = 0) -> RemoteSessionLayout {
        let style = RemoteSessionLayout.style(for: screen.size)
        let dockSize = style == .rail
            ? CGSize(width: 60, height: 326)
            : CGSize(width: min(574, RemoteSessionLayout.dockAvailableWidth(size: screen.size, safeArea: screen.safeArea)), height: 60)
        return RemoteSessionLayout(.init(
            size: screen.size,
            safeArea: screen.safeArea,
            style: style,
            headerHeight: style == .rail ? 159 : 56,
            headerWidth: style == .rail ? 52 : 0,
            dockSize: dockSize,
            keyboardPanelHeight: panelHeight,
            keyboardOverlap: keyboard
        ))
    }

    func testStyleFollowsContainerShape() {
        XCTAssertEqual(layout(screens[0]).style, .bars)
        XCTAssertEqual(layout(screens[1]).style, .rail)
        XCTAssertEqual(layout(screens[3]).style, .rail)
        XCTAssertEqual(layout(screens[5]).style, .bars, "iPad keeps header and dock bars in landscape")
        XCTAssertEqual(RemoteSessionLayout.style(for: CGSize(width: 932, height: 430)), .rail, "Largest phone in landscape")
        XCTAssertEqual(RemoteSessionLayout.style(for: CGSize(width: 1133, height: 744)), .bars, "iPad mini in landscape")
    }

    func testChromeNeverOverlapsTheViewport() {
        for screen in screens {
            for (panel, keyboard) in [(nil, 0), (118, 0), (118, screen.size.height * 0.42)] as [(CGFloat?, CGFloat)] {
                let result = layout(screen, panelHeight: panel, keyboard: keyboard)
                let context = "\(screen.name) panel=\(String(describing: panel)) keyboard=\(keyboard)"
                let bounds = CGRect(origin: .zero, size: screen.size)
                XCTAssertGreaterThan(result.viewport.width, 0, context)
                XCTAssertGreaterThan(result.viewport.height, 0, context)
                XCTAssertTrue(bounds.contains(result.viewport), context)
                XCTAssertTrue(result.viewport.intersection(result.header).isNull || result.viewport.intersection(result.header).isEmpty, context)
                XCTAssertTrue(result.viewport.intersection(result.dock).isNull || result.viewport.intersection(result.dock).isEmpty, context)
                XCTAssertTrue(bounds.contains(result.dock), context)
                if result.style == .bars {
                    XCTAssertLessThanOrEqual(result.dock.width, RemoteSessionLayout.maximumDockWidth, context)
                }
                if keyboard > 0 {
                    XCTAssertLessThanOrEqual(result.dock.maxY, screen.size.height - keyboard, "\(context): the panel rides above the keyboard")
                }
            }
        }
    }

    func testBarsKeepDockCenteredInsideSafeArea() {
        let phone = layout(screens[2])
        XCTAssertEqual(phone.header.minY, 0)
        XCTAssertEqual(phone.header.height, 62 + 56, "The header extends under the status bar")
        XCTAssertEqual(phone.dock.midX, 201, accuracy: 0.5)
        XCTAssertLessThanOrEqual(phone.dock.maxY, 874 - 28)

        let pad = layout(screens[4])
        XCTAssertEqual(pad.dock.width, 574)
        XCTAssertEqual(pad.dock.midX, 410, accuracy: 0.5)
    }

    func testRailKeepsFullVideoHeight() {
        let landscape = layout(screens[3])
        XCTAssertEqual(landscape.viewport.minY, 0)
        XCTAssertEqual(landscape.viewport.height, 402, "Landscape phones keep the full height for video")
        XCTAssertGreaterThanOrEqual(landscape.header.minX, 62, "Chrome stays out of the sensor housing")
        XCTAssertLessThanOrEqual(landscape.dock.maxX, 874 - 62)
    }
}
