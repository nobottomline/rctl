import CoreGraphics

/// Reticle geometry in stage coordinates (the full-bleed preview space that
/// detection bounds are reported in). UIKit-free so it can be unit tested.
enum ScannerGeometry {
    static let windowCornerRadius: CGFloat = 24
    static let minimumRestingSide: CGFloat = 220
    static let maximumRestingSide: CGFloat = 300
    /// Resting window center, as a fraction of the safe height.
    static let restingCenterFraction: CGFloat = 0.44
    /// Space between a detected code and the window.
    static let detectionPadding: CGFloat = 16
    static let minimumTargetSide: CGFloat = 120
    /// Detections smaller than this are treated as unmapped.
    static let minimumDetectionSide: CGFloat = 24
    /// Edge movement below this keeps the current target (hand jitter).
    static let retargetTolerance: CGFloat = 4

    /// Square window centered horizontally in `safeFrame`, slightly above its
    /// middle. `minimumTop` keeps it below tall copy (large Dynamic Type)
    /// unless that would push it past `maximumBottom` (the controls).
    static func restingRect(safeFrame: CGRect, minimumTop: CGFloat = -.greatestFiniteMagnitude, maximumBottom: CGFloat = .greatestFiniteMagnitude) -> CGRect {
        let side = min(max(min(safeFrame.width, safeFrame.height) * 0.62, minimumRestingSide), maximumRestingSide)
        var y = safeFrame.minY + safeFrame.height * restingCenterFraction - side / 2
        y = max(y, minimumTop)
        y = min(y, maximumBottom - side)
        return CGRect(x: safeFrame.minX + (safeFrame.width - side) / 2, y: y, width: side, height: side)
    }

    /// The detected code's padded square bounds, or the resting rect when
    /// there is no usable detection.
    static func targetRect(detectionBounds: CGRect?, resting: CGRect) -> CGRect {
        guard let bounds = detectionBounds, !bounds.isNull, !bounds.isInfinite,
              bounds.width > minimumDetectionSide, bounds.height > minimumDetectionSide else {
            return resting
        }
        let padded = bounds.insetBy(dx: -detectionPadding, dy: -detectionPadding)
        let side = max(padded.width, padded.height, minimumTargetSide)
        return CGRect(x: padded.midX - side / 2, y: padded.midY - side / 2, width: side, height: side)
    }

    /// Whether `next` differs enough from the displayed `current` target to
    /// restart the spring. Small per-frame jitter of a held phone is ignored.
    static func shouldRetarget(from current: CGRect?, to next: CGRect, tolerance: CGFloat = retargetTolerance) -> Bool {
        guard let current else { return true }
        return abs(current.minX - next.minX) > tolerance
            || abs(current.minY - next.minY) > tolerance
            || abs(current.maxX - next.maxX) > tolerance
            || abs(current.maxY - next.maxY) > tolerance
    }

    static func bracketLength(forWindowWidth width: CGFloat) -> CGFloat {
        min(34, width * 0.2)
    }

    /// Vertical center of a caption shown with the window: below it, unless
    /// that would reach `bottomLimit` (the top of the bottom controls); then
    /// above it, never above `topLimit`.
    static func captionCenterY(window: CGRect, captionHeight: CGFloat, spacing: CGFloat = 18, topLimit: CGFloat, bottomLimit: CGFloat) -> CGFloat {
        let below = window.maxY + spacing + captionHeight / 2
        if below + captionHeight / 2 <= bottomLimit { return below }
        let above = window.minY - spacing - captionHeight / 2
        return max(above, topLimit + captionHeight / 2)
    }
}

/// Paths for the reticle and the pairing emblem. Every builder emits the same
/// element sequence for any rect, so Core Animation can interpolate between
/// two paths smoothly (a changed element count makes path animations jump).
enum ScannerReticlePaths {
    enum Corner: CaseIterable, Sendable {
        case topLeft, topRight, bottomRight, bottomLeft
    }

    /// Cubic Bézier handle length for a quarter circle.
    private static let kappa: CGFloat = 0.552_284_75

    /// Four corner brackets hugging a rounded rect.
    static func brackets(in rect: CGRect, cornerRadius: CGFloat, length: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for corner in Corner.allCases {
            appendBracket(corner, to: path, in: rect, cornerRadius: cornerRadius, length: length)
        }
        return path
    }

    /// One bracket drawn end → corner → end, so its stroke midpoint is the corner apex.
    static func bracket(_ corner: Corner, in rect: CGRect, cornerRadius: CGFloat, length: CGFloat) -> CGPath {
        let path = CGMutablePath()
        appendBracket(corner, to: path, in: rect, cornerRadius: cornerRadius, length: length)
        return path
    }

    /// Everything in `bounds` except a rounded `window`; fill with the even-odd rule.
    static func scrim(bounds: CGRect, window: CGRect, cornerRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        appendRoundedRect(to: path, rect: window, cornerRadius: cornerRadius)
        return path
    }

    static func roundedRect(_ rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        appendRoundedRect(to: path, rect: rect, cornerRadius: cornerRadius)
        return path
    }

    private static func appendRoundedRect(to path: CGMutablePath, rect: CGRect, cornerRadius: CGFloat) {
        let r = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
        let k = r * kappa
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r),
                      control1: CGPoint(x: rect.maxX - r + k, y: rect.minY),
                      control2: CGPoint(x: rect.maxX, y: rect.minY + r - k))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                      control1: CGPoint(x: rect.maxX, y: rect.maxY - r + k),
                      control2: CGPoint(x: rect.maxX - r + k, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                      control1: CGPoint(x: rect.minX + r - k, y: rect.maxY),
                      control2: CGPoint(x: rect.minX, y: rect.maxY - r + k))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                      control1: CGPoint(x: rect.minX, y: rect.minY + r - k),
                      control2: CGPoint(x: rect.minX + r - k, y: rect.minY))
        path.closeSubpath()
    }

    private static func appendBracket(_ corner: Corner, to path: CGMutablePath, in rect: CGRect, cornerRadius: CGFloat, length: CGFloat) {
        let shortest = min(rect.width, rect.height)
        let r = max(0, min(cornerRadius, shortest / 2))
        let l = max(0, min(length, shortest / 2 - r))
        let k = r * kappa
        // Corner origin and the unit directions of its two arms.
        let origin: CGPoint
        let horizontal: CGFloat
        let vertical: CGFloat
        switch corner {
        case .topLeft: origin = CGPoint(x: rect.minX, y: rect.minY); horizontal = 1; vertical = 1
        case .topRight: origin = CGPoint(x: rect.maxX, y: rect.minY); horizontal = -1; vertical = 1
        case .bottomRight: origin = CGPoint(x: rect.maxX, y: rect.maxY); horizontal = -1; vertical = -1
        case .bottomLeft: origin = CGPoint(x: rect.minX, y: rect.maxY); horizontal = 1; vertical = -1
        }
        func point(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + dx * horizontal, y: origin.y + dy * vertical)
        }
        path.move(to: point(0, r + l))
        path.addLine(to: point(0, r))
        path.addCurve(to: point(r, 0), control1: point(0, r - k), control2: point(r - k, 0))
        path.addLine(to: point(r + l, 0))
    }
}
