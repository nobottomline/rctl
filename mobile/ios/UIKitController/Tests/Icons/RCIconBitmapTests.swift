import XCTest
@testable import RctlUIKit

/// The cached bitmap must look like the shape layer it replaces.
@MainActor
final class RCIconBitmapRenderingTests: XCTestCase {
    private let glyphs: [RCIconGlyph] = [.plus, .chevronRight, .settings, .refreshCw, .qrCode, .x, .circleAlert]
    private let tints: [UIColor] = [
        RCColor.accent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)),
        RCColor.textTertiary.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)),
        UIColor(white: 0, alpha: 0.5),
    ]

    /// Reference: a CAShapeLayer configured the way RCIconView configures it.
    private func shapeReference(_ glyph: RCIconGlyph, pointSize: CGFloat, strokeWidth: CGFloat, scale: CGFloat, tint: UIColor) -> TestPixels {
        let shape = CAShapeLayer()
        shape.bounds = CGRect(x: 0, y: 0, width: pointSize, height: pointSize)
        shape.contentsScale = scale
        shape.path = RCIcon.path(glyph, pointSize: pointSize)
        shape.fillColor = nil
        shape.lineCap = .round
        shape.lineJoin = .round
        shape.lineWidth = strokeWidth * pointSize / 24
        shape.strokeColor = tint.cgColor
        return TestPixels.render(size: shape.bounds.size, scale: scale) { shape.render(in: $0) }
    }

    func testBitmapMatchesShapeLayerAt1x2x3x() throws {
        for scale: CGFloat in [1, 2, 3] {
            for (index, glyph) in glyphs.enumerated() {
                let pointSize: CGFloat = [12, 16, 18, 20, 24, 52][index % 6]
                let strokeWidth: CGFloat = [2, 2.25, 1.75, 3][index % 4]
                let tint = tints[index % tints.count]
                let color = try XCTUnwrap(RCIconColor(tint))
                let image = try XCTUnwrap(RCIcon.bitmap(glyph, pointSize: pointSize, strokeWidth: strokeWidth, scale: scale, color: color))
                XCTAssertEqual(image.width, Int((pointSize * scale).rounded(.up)))
                let bitmap = TestPixels.of(image)
                let reference = shapeReference(glyph, pointSize: pointSize, strokeWidth: strokeWidth, scale: scale, tint: tint)
                let difference = try XCTUnwrap(bitmap.difference(from: reference))
                let context = "\(glyph) \(pointSize)pt stroke \(strokeWidth) @\(scale)x: \(difference)"
                XCTAssertGreaterThan(difference.coverage.0, pointSize * scale * 0.5, context)
                // Anti-aliasing tolerance: both are Core Graphics strokes of the same geometry.
                XCTAssertLessThanOrEqual(difference.mean, 1.0, context)
                XCTAssertLessThanOrEqual(difference.strongShare, 0.01, context)
            }
        }
    }

    func testViewBitmapMatchesVectorRenderingIncludingPixelSnapping() throws {
        // Odd bounds put the glyph origin on a half point; both modes must snap it the same way.
        for scale: CGFloat in [1, 2, 3] {
            for bounds in [CGSize(width: 20, height: 20), CGSize(width: 45, height: 45), CGSize(width: 37, height: 29)] {
                func render(vector: Bool) -> TestPixels {
                    let icon = RCIconView(.settings, pointSize: 20, strokeWidth: 2)
                    icon.tintColor = tints[0]
                    icon.frame = CGRect(origin: .zero, size: bounds)
                    icon.contentScaleFactor = scale
                    icon.testDisplayScale = scale
                    icon.prefersVectorRendering = vector
                    icon.setNeedsLayout()
                    icon.layoutIfNeeded()
                    XCTAssertEqual(icon.isShowingBitmap, !vector)
                    return TestPixels.render(size: bounds, scale: scale) { icon.layer.render(in: $0) }
                }
                let difference = try XCTUnwrap(render(vector: false).difference(from: render(vector: true)))
                let context = "\(bounds) @\(scale)x: \(difference)"
                XCTAssertGreaterThan(difference.coverage.0, 10, context)
                XCTAssertLessThanOrEqual(difference.mean, 1.0, context)
                XCTAssertLessThanOrEqual(difference.strongShare, 0.01, context)
            }
        }
    }

    func testOnScreenBitmapMatchesRenderServerShapeLayer() async throws {
        let host = PrimitiveTestHost()
        defer { host.tearDown() }
        for (glyph, pointSize) in [(RCIconGlyph.refreshCw, CGFloat(20)), (.qrCode, 52), (.chevronRight, 16)] {
            let bitmapIcon = RCIconView(glyph, pointSize: pointSize)
            let vectorIcon = RCIconView(glyph, pointSize: pointSize)
            vectorIcon.prefersVectorRendering = true
            for icon in [bitmapIcon, vectorIcon] {
                icon.tintColor = RCColor.text
                host.add(icon, frame: CGRect(x: 10, y: 100, width: pointSize + 4, height: pointSize + 4))
            }
            XCTAssertTrue(bitmapIcon.isShowingBitmap)
            XCTAssertFalse(vectorIcon.isShowingBitmap)
            XCTAssertEqual(bitmapIcon.layer.sublayers?.first?.contentsScale, host.window.screen.scale, "bitmap at the screen's resolution")
            let bitmap = try XCTUnwrap(TestPixels.snapshot(bitmapIcon))
            let vector = try XCTUnwrap(TestPixels.snapshot(vectorIcon))
            let difference = try XCTUnwrap(bitmap.difference(from: vector))
            let context = "\(glyph) \(pointSize)pt on screen: \(difference)"
            XCTAssertGreaterThan(difference.coverage.1, pointSize, context)
            // Core Animation rasterizes shapes itself; only edge anti-aliasing may differ.
            XCTAssertLessThanOrEqual(difference.mean, 1.0, context)
            XCTAssertLessThanOrEqual(difference.strongShare, 0.01, context)
            bitmapIcon.removeFromSuperview()
            vectorIcon.removeFromSuperview()
        }
    }

    func testIdenticalInputsShareOneCachedBitmap() throws {
        let color = try XCTUnwrap(RCIconColor(tints[0]))
        let first = RCIcon.bitmap(.plus, pointSize: 20, strokeWidth: 2, scale: 3, color: color)
        let second = RCIcon.bitmap(.plus, pointSize: 20, strokeWidth: 2, scale: 3, color: color)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
        let other = try XCTUnwrap(RCIconColor(tints[1]))
        XCTAssertFalse(first === RCIcon.bitmap(.plus, pointSize: 20, strokeWidth: 2, scale: 3, color: other))
        XCTAssertNil(RCIcon.bitmap(.plus, pointSize: 0, strokeWidth: 2, scale: 3, color: color))
        XCTAssertGreaterThan(RCIcon.bitmapCacheCountLimit, 0)
        XCTAssertLessThanOrEqual(RCIcon.bitmapCacheCostLimit, 16 * 1024 * 1024)
    }
}

/// When the view draws with the bitmap and when with the shape layer.
@MainActor
final class RCIconViewRenderingModeTests: XCTestCase {
    private var host: PrimitiveTestHost!

    override func setUp() async throws {
        host = PrimitiveTestHost()
    }

    override func tearDown() async throws {
        host.tearDown()
        host = nil
    }

    private func makeIcon(_ glyph: RCIconGlyph = .refreshCw) -> RCIconView {
        let icon = RCIconView(glyph, pointSize: 20)
        icon.tintColor = RCColor.accent
        host.add(icon, frame: CGRect(x: 20, y: 120, width: 44, height: 44))
        return icon
    }

    private func shape(_ icon: RCIconView) -> CAShapeLayer {
        icon.layer as! CAShapeLayer
    }

    private func bitmapContents(_ icon: RCIconView) -> AnyObject? {
        icon.layer.sublayers?.first.flatMap { $0.contents as AnyObject? }
    }

    func testRestsOnTheCachedBitmapAndKeepsShapeLayerProperties() {
        let icon = makeIcon()
        XCTAssertTrue(icon.isShowingBitmap)
        XCTAssertNil(shape(icon).path, "no vector rasterization at rest")
        XCTAssertNotNil(bitmapContents(icon))
        XCTAssertNotNil(shape(icon).strokeColor, "callers still read the resolved tint from the layer")
        XCTAssertEqual(shape(icon).lineWidth, 2 * 20 / 24, accuracy: 0.001)

        let twin = makeIcon()
        XCTAssertTrue(bitmapContents(icon) === bitmapContents(twin), "same inputs share one bitmap")
    }

    func testTintSizeAndAppearanceChangesRerenderOnlyWhenTheyChangePixels() {
        let icon = makeIcon()
        let original = bitmapContents(icon)
        icon.tintColor = RCColor.accent
        XCTAssertTrue(bitmapContents(icon) === original, "same tint keeps the bitmap")
        icon.tintColor = RCColor.danger
        XCTAssertFalse(bitmapContents(icon) === original)
        icon.tintColor = RCColor.accent
        XCTAssertTrue(bitmapContents(icon) === original, "back to a cached bitmap")

        icon.overrideUserInterfaceStyle = .dark
        icon.layoutIfNeeded()
        XCTAssertFalse(bitmapContents(icon) === original, "dark accent resolves to another color")
        icon.overrideUserInterfaceStyle = .light
        icon.layoutIfNeeded()
        XCTAssertTrue(bitmapContents(icon) === original)

        icon.pointSize = 24
        icon.layoutIfNeeded()
        XCTAssertFalse(bitmapContents(icon) === original)
        XCTAssertEqual(icon.layer.sublayers?.first?.frame.size, CGSize(width: 24, height: 24))
        icon.strokeWidth = 1.5
        XCTAssertTrue(icon.isShowingBitmap)
    }

    func testDrawInUsesTheShapeLayerOnlyWhileItRuns() async {
        let icon = makeIcon()
        icon.drawIn(duration: 0.2)
        XCTAssertFalse(icon.isShowingBitmap)
        XCTAssertNotNil(shape(icon).path)
        XCTAssertTrue(icon.layer.sublayers?.first?.isHidden ?? false)
        let settled = await pollUntil(timeout: 2) { icon.isShowingBitmap }
        XCTAssertTrue(settled, "returns to the bitmap after the draw-in")
        XCTAssertNil(shape(icon).path)
    }

    func testAnimatedGlyphSwapUsesTheShapeLayerThenReturns() async {
        let icon = makeIcon(.plus)
        icon.setGlyph(.check, animated: true)
        XCTAssertFalse(icon.isShowingBitmap)
        XCTAssertNotNil(icon.layer.animation(forKey: "rc.icon.glyphIn.path"))
        let settled = await pollUntil(timeout: 2) { icon.isShowingBitmap }
        XCTAssertTrue(settled)
        XCTAssertEqual(icon.glyph, .check)

        icon.setGlyph(.x, animated: false)
        XCTAssertTrue(icon.isShowingBitmap, "an instant swap stays on bitmaps")
    }

    func testCallerStrokeColorFadeOnTheLayerIsHonored() async {
        // What text fields and icon buttons do to crossfade an icon's tint.
        let icon = makeIcon()
        let from = shape(icon).strokeColor
        icon.tintColor = RCColor.danger
        let fade = CABasicAnimation(keyPath: "strokeColor")
        fade.fromValue = from
        fade.duration = 0.18
        icon.layer.add(fade, forKey: "rc.tint")
        XCTAssertFalse(icon.isShowingBitmap)
        let settled = await pollUntil(timeout: 2) { icon.isShowingBitmap }
        XCTAssertTrue(settled)
    }

    func testTransformAndOpacityAnimationsKeepTheBitmap() {
        let icon = makeIcon()
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.toValue = CGFloat.pi * 2
        spin.repeatCount = .infinity
        icon.layer.add(spin, forKey: "spin")
        XCTAssertTrue(icon.isShowingBitmap, "rotating a texture needs no re-rasterization")
        icon.layer.removeAnimation(forKey: "spin")
    }

    func testPartialStrokeAndOpenEndedStrokeAnimationsStayVector() {
        let icon = makeIcon()
        icon.strokeEnd = 0.5
        XCTAssertFalse(icon.isShowingBitmap)
        icon.strokeEnd = 1
        XCTAssertTrue(icon.isShowingBitmap)

        let dash = CABasicAnimation(keyPath: "lineDashPhase")
        dash.toValue = 10
        dash.repeatCount = .infinity
        icon.layer.add(dash, forKey: "dash")
        XCTAssertFalse(icon.isShowingBitmap)
        icon.layer.removeAnimation(forKey: "dash")
        XCTAssertTrue(icon.isShowingBitmap)

        icon.layer.add(dash, forKey: nil)
        XCTAssertFalse(icon.isShowingBitmap)
        icon.layer.removeAllAnimations()
        XCTAssertTrue(icon.isShowingBitmap)
    }

    func testRemovedGlyphShowsNothing() {
        let icon = makeIcon()
        icon.glyph = nil
        XCTAssertTrue(icon.layer.sublayers?.first?.isHidden ?? false)
        XCTAssertNil(shape(icon).path)
        icon.glyph = .plus
        XCTAssertFalse(icon.layer.sublayers?.first?.isHidden ?? true)
    }
}
