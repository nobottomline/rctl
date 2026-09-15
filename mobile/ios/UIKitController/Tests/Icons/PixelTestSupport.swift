import UIKit
import XCTest
@testable import RctlUIKit

/// RGBA8 premultiplied pixels (sRGB), row 0 at the top.
struct TestPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    /// Draws with a UIKit-oriented CTM (points, top-left origin) at `scale`.
    @MainActor
    static func render(size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> TestPixels {
        let width = Int((size.width * scale).rounded(.up))
        let height = Int((size.height * scale).rounded(.up))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            draw(context)
        }
        return TestPixels(width: width, height: height, bytes: bytes)
    }

    /// The image's pixels at its own size.
    static func of(_ image: CGImage) -> TestPixels {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return TestPixels(width: width, height: height, bytes: bytes)
    }

    /// What the render server shows for `view` (it must be in a window).
    @MainActor
    static func snapshot(_ view: UIView) -> TestPixels? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.window?.screen.scale ?? UIScreen.main.scale
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        return image.cgImage.map(TestPixels.of)
    }

    struct Difference: CustomStringConvertible {
        /// Mean absolute channel difference, 0...255.
        let mean: Double
        /// Largest channel difference, 0...255.
        let max: Int
        /// Share of pixels with any channel differing by more than 32.
        let strongShare: Double
        /// Alpha coverage of each image (sum of alpha / 255), to catch empty renders.
        let coverage: (Double, Double)

        var description: String {
            String(format: "mean %.2f, max %d, strong %.2f%%, coverage %.1f vs %.1f", mean, max, strongShare * 100, coverage.0, coverage.1)
        }
    }

    func difference(from other: TestPixels) -> Difference? {
        guard width == other.width, height == other.height else { return nil }
        var total = 0
        var largest = 0
        var strong = 0
        var coverageA = 0
        var coverageB = 0
        for pixel in 0..<(width * height) {
            var pixelMax = 0
            for channel in 0..<4 {
                let index = pixel * 4 + channel
                let delta = abs(Int(bytes[index]) - Int(other.bytes[index]))
                total += delta
                pixelMax = Swift.max(pixelMax, delta)
            }
            coverageA += Int(bytes[pixel * 4 + 3])
            coverageB += Int(other.bytes[pixel * 4 + 3])
            largest = Swift.max(largest, pixelMax)
            if pixelMax > 32 { strong += 1 }
        }
        let count = Double(Swift.max(width * height, 1))
        return Difference(
            mean: Double(total) / (count * 4),
            max: largest,
            strongShare: Double(strong) / count,
            coverage: (Double(coverageA) / 255, Double(coverageB) / 255)
        )
    }
}

/// Spins the main run loop until `condition` holds or `timeout` elapses.
@MainActor
func pollUntil(timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}
