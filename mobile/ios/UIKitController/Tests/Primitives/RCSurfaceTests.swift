import XCTest
@testable import RctlUIKit

@MainActor
final class RCSurfaceTests: XCTestCase {
    private var host: PrimitiveTestHost!

    override func setUp() async throws {
        host = PrimitiveTestHost()
    }

    override func tearDown() async throws {
        host.tearDown()
        host = nil
    }

    func testCardShadowsUseExplicitPathsUnderTheFillWithoutClipping() {
        let card = RCSurfaceView(style: .card)
        host.add(card, frame: CGRect(x: 20, y: 20, width: 300, height: 120))
        let layers = card.shadowLayersForTesting
        XCTAssertEqual(layers.count, 2)
        for layer in layers {
            XCTAssertNotNil(layer.shadowPath)
            XCTAssertGreaterThan(layer.shadowOpacity, 0)
            XCTAssertFalse(layer.masksToBounds)
        }
        XCTAssertTrue(layers[0] === card.layer, "the contact shadow renders beneath every sublayer")
        XCTAssertNil(card.layer.backgroundColor, "the fill lives above both shadows, not on the root layer")
        let fill = card.fillLayerForTesting
        XCTAssertEqual(fill.shadowOpacity, 0)
        XCTAssertNotNil(fill.backgroundColor)
        let order = card.subviews.map(\.layer)
        XCTAssertLessThan(order.firstIndex(of: layers[1])!, order.firstIndex(of: fill)!)
        XCTAssertLessThan(order.firstIndex(of: fill)!, order.firstIndex(of: card.contentView.layer)!)
    }

    func testShadowPathIsRebuiltOnlyWhenTheSizeChanges() {
        let card = RCSurfaceView(style: .card)
        host.add(card, frame: CGRect(x: 20, y: 20, width: 300, height: 120))
        let path = card.shadowLayersForTesting[1].shadowPath
        card.frame.origin.y = 60
        card.setNeedsLayout()
        card.layoutIfNeeded()
        XCTAssertTrue(card.shadowLayersForTesting[1].shadowPath === path, "moving the card keeps the cached path")
        card.frame.size.height = 160
        card.layoutIfNeeded()
        XCTAssertFalse(card.shadowLayersForTesting[1].shadowPath === path)
        XCTAssertEqual(card.shadowLayersForTesting[1].shadowPath?.boundingBox.height ?? 0, 160, accuracy: 0.5)
    }

    func testShadowPathFollowsAnimatedResize() {
        let card = RCSurfaceView(style: .card)
        host.add(card, frame: CGRect(x: 20, y: 20, width: 300, height: 120))
        UIView.animate(withDuration: 0.3) {
            card.frame.size.height = 200
            card.layoutIfNeeded()
        }
        for layer in card.shadowLayersForTesting {
            let animation = layer.animation(forKey: "shadowPath") as? CABasicAnimation
            XCTAssertNotNil(animation, "contact and ambient shadows follow the resize")
            XCTAssertEqual(animation?.duration ?? 0, 0.3, accuracy: 0.001)
        }

        // Spring property animators (RCMotion) are followed with their own timing.
        RCMotion.animate(RCMotion.snappy) {
            card.frame.size.height = 260
            card.layoutIfNeeded()
        }
        XCTAssertTrue(card.shadowLayersForTesting.allSatisfy { $0.animation(forKey: "shadowPath") != nil })

        // Outside an animation the path changes instantly.
        card.shadowLayersForTesting.forEach { $0.removeAllAnimations() }
        card.frame.size.height = 180
        card.layoutIfNeeded()
        XCTAssertTrue(card.shadowLayersForTesting.allSatisfy { $0.animation(forKey: "shadowPath") == nil })
        XCTAssertEqual(card.shadowLayersForTesting[0].shadowPath?.boundingBox.height ?? 0, 180, accuracy: 0.5)
    }

    func testInsetHasNoShadowAndFloatingUsesConsoleTokens() {
        let inset = RCSurfaceView(style: .inset)
        host.add(inset, frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        XCTAssertTrue(inset.shadowLayersForTesting.allSatisfy { $0.shadowOpacity == 0 })
        XCTAssertNil(inset.layer.shadowPath)

        let floating = RCSurfaceView(style: .floating)
        floating.overrideUserInterfaceStyle = .light
        host.add(floating, frame: CGRect(x: 0, y: 100, width: 200, height: 80))
        let fill = floating.fillLayerForTesting
        let consoleSurface = RCColor.surface.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).cgColor
        XCTAssertEqual(fill.backgroundColor, consoleSurface)
        XCTAssertEqual(fill.backgroundColor?.alpha, 1, "opaque over video")
    }

    func testCalloutSizingAndActionAccessibility() {
        let callout = RCCallout(text: "The relay did not answer. Check the address and try again.", icon: .circleAlert, tone: .danger)
        host.add(callout)
        let narrow = callout.sizeThatFits(CGSize(width: 220, height: CGFloat.greatestFiniteMagnitude)).height
        let wide = callout.sizeThatFits(CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude)).height
        XCTAssertGreaterThan(narrow, wide, "text wraps in narrow columns")
        XCTAssertEqual(callout.sizeThatFits(CGSize(width: 220, height: CGFloat.greatestFiniteMagnitude)).height, narrow)
        XCTAssertTrue(callout.isAccessibilityElement)

        var retried = false
        callout.setAction(title: "Retry") { retried = true }
        XCTAssertFalse(callout.isAccessibilityElement, "the action must stay reachable")
        XCTAssertEqual(callout.accessibilityElements?.count, 2)
        (callout.accessibilityElements?.last as? RCButton)?.sendActions(for: .touchUpInside)
        XCTAssertTrue(retried)
        callout.setAction(title: nil, handler: nil)
        XCTAssertTrue(callout.isAccessibilityElement)

        callout.shake(playsHaptic: false)
        XCTAssertEqual(callout.layer.animation(forKey: "rc.shake") != nil, !RCMotion.reduceMotion)
    }

    func testSectionHeaderStacksSubtitleWhenItDoesNotFit() {
        let header = RCSectionHeader(title: "Nearby", subtitle: "Scanning")
        host.add(header)
        let inline = header.sizeThatFits(CGSize(width: 360, height: CGFloat.greatestFiniteMagnitude)).height
        XCTAssertEqual(inline, 32)
        header.subtitle = "Addresses you added manually stay on this device only"
        let stacked = header.sizeThatFits(CGSize(width: 260, height: CGFloat.greatestFiniteMagnitude)).height
        XCTAssertGreaterThan(stacked, inline)
    }

    func testEmptyStateSizesToContentAndCentersInExtraSpace() {
        let empty = RCEmptyStateView(icon: .tabletSmartphone, title: "No devices yet", message: "Pair with your relay.", actions: [RCButton(title: "Pair", variant: .accent)])
        host.add(empty)
        let fitted = empty.sizeThatFits(CGSize(width: 360, height: CGFloat.greatestFiniteMagnitude)).height
        empty.frame = CGRect(x: 0, y: 0, width: 360, height: fitted + 200)
        empty.layoutIfNeeded()
        let tile = empty.subviews.compactMap { $0 as? RCIconTile }.first
        XCTAssertEqual(tile?.frame.minY ?? 0, 100, accuracy: 0.5)
    }
}
