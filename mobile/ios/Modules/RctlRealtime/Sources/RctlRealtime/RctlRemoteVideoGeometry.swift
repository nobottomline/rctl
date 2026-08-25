import CoreGraphics

struct RctlRemoteVideoGeometry: Equatable {
    let sourceSize: CGSize
    let rotation: Int
    let viewportSize: CGSize

    var contentRect: CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else {
            return .zero
        }
        let oriented = normalizedRotation == 90 || normalizedRotation == 270
            ? CGSize(width: sourceSize.height, height: sourceSize.width)
            : sourceSize
        let scale = min(viewportSize.width / oriented.width, viewportSize.height / oriented.height)
        let size = CGSize(width: oriented.width * scale, height: oriented.height * scale)
        return CGRect(
            x: (viewportSize.width - size.width) / 2,
            y: (viewportSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    func normalizedRemotePoint(for point: CGPoint, clamped: Bool) -> CGPoint? {
        let rect = contentRect
        guard !rect.isEmpty else { return nil }
        if !clamped, !rect.contains(point) { return nil }

        let displayX = clamp((point.x - rect.minX) / rect.width)
        let displayY = clamp((point.y - rect.minY) / rect.height)
        switch normalizedRotation {
        case 90:
            return CGPoint(x: displayY, y: 1 - displayX)
        case 180:
            return CGPoint(x: 1 - displayX, y: 1 - displayY)
        case 270:
            return CGPoint(x: 1 - displayY, y: displayX)
        default:
            return CGPoint(x: displayX, y: displayY)
        }
    }

    private var normalizedRotation: Int {
        let value = rotation % 360
        return value >= 0 ? value : value + 360
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}
