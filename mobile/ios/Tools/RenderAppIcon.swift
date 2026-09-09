// Renders the 1024x1024 app icon deterministically with CoreGraphics so the
// artwork is reproducible without a design tool:
//
//   swiftc -O -o /tmp/render-icon mobile/ios/Tools/RenderAppIcon.swift
//   /tmp/render-icon mobile/ios/Controller/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
//
// The motif (tablet outline, touch point, ripple rings on ink with a terracotta
// wash) matches `BrandMark` in the app.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// Ink background with a diagonal warm-to-deep gradient.
let bg = CGGradient(colorsSpace: space,
                    colors: [rgb(0.27, 0.215, 0.15), rgb(0.176, 0.141, 0.09), rgb(0.12, 0.095, 0.06)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Terracotta glow in the upper-right, echoing the app's ambient wash.
let glow = CGGradient(colorsSpace: space,
                      colors: [rgb(0.831, 0.451, 0.298, 0.42), rgb(0.831, 0.451, 0.298, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size * 0.82, y: size * 0.82), startRadius: 0,
                       endCenter: CGPoint(x: size * 0.82, y: size * 0.82), endRadius: size * 0.75, options: [])
// Sage glow bottom-left, very faint.
let glow2 = CGGradient(colorsSpace: space,
                       colors: [rgb(0.31, 0.604, 0.408, 0.16), rgb(0.31, 0.604, 0.408, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawRadialGradient(glow2, startCenter: CGPoint(x: size * 0.15, y: size * 0.12), startRadius: 0,
                       endCenter: CGPoint(x: size * 0.15, y: size * 0.12), endRadius: size * 0.6, options: [])

// Tablet outline with a touch point and two ripple rings: "remote touch".
let unit = size
func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * unit, y: (1 - y) * unit) }
let tablet = CGRect(x: 0.25 * unit, y: (1 - 0.86) * unit, width: 0.50 * unit, height: 0.72 * unit)
let tabletPath = CGPath(roundedRect: tablet, cornerWidth: 0.09 * unit, cornerHeight: 0.09 * unit, transform: nil)
// Soft drop shadow behind the tablet.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -unit * 0.02), blur: unit * 0.06, color: rgb(0, 0, 0, 0.35))
ctx.setStrokeColor(rgb(0.992, 0.965, 0.918, 0.94))
ctx.setLineWidth(unit * 0.05)
ctx.addPath(tabletPath)
ctx.strokePath()
ctx.restoreGState()
// Screen tint inside the tablet.
ctx.saveGState()
ctx.addPath(tabletPath)
ctx.clip()
let screen = CGGradient(colorsSpace: space,
                        colors: [rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0.02)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(screen, start: pt(0.3, 0.86), end: pt(0.7, 0.14), options: [])
ctx.restoreGState()
// Ripple rings around the touch point.
let touch = pt(0.5, 0.53)
ctx.setLineCap(.round)
for (radius, alpha, width) in [(0.135, 0.9, 0.036), (0.215, 0.45, 0.026)] {
    ctx.setStrokeColor(rgb(0.831, 0.451, 0.298, alpha))
    ctx.setLineWidth(unit * width)
    ctx.addEllipse(in: CGRect(x: touch.x - radius * unit, y: touch.y - radius * unit,
                              width: radius * unit * 2, height: radius * unit * 2))
    ctx.strokePath()
}
// Touch point.
ctx.setFillColor(rgb(0.831, 0.451, 0.298))
let dot = 0.065 * unit
ctx.fillEllipse(in: CGRect(x: touch.x - dot, y: touch.y - dot, width: dot * 2, height: dot * 2))
ctx.setFillColor(rgb(0.992, 0.965, 0.918))
let core = 0.026 * unit
ctx.fillEllipse(in: CGRect(x: touch.x - core, y: touch.y - core, width: core * 2, height: core * 2))

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote", url.path)
