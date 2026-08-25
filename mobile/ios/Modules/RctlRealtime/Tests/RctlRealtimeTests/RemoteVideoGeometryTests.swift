import CoreGraphics
import Testing
@testable import RctlRealtime

@Suite("Remote video geometry")
struct RemoteVideoGeometryTests {
    @Test("Aspect fit excludes letterboxing")
    func aspectFit() {
        let geometry = RctlRemoteVideoGeometry(
            sourceSize: CGSize(width: 100, height: 200),
            rotation: 0,
            viewportSize: CGSize(width: 300, height: 300)
        )

        #expect(geometry.contentRect == CGRect(x: 75, y: 0, width: 150, height: 300))
        #expect(geometry.normalizedRemotePoint(for: CGPoint(x: 74, y: 150), clamped: false) == nil)
        #expect(geometry.normalizedRemotePoint(for: CGPoint(x: 150, y: 150), clamped: false) == CGPoint(x: 0.5, y: 0.5))
    }

    @Test("Display rotation maps back to fixed device coordinates", arguments: [
        (0, CGPoint(x: 0, y: 0)),
        (90, CGPoint(x: 0, y: 1)),
        (180, CGPoint(x: 1, y: 1)),
        (270, CGPoint(x: 1, y: 0)),
    ])
    func rotation(rotation: Int, expected: CGPoint) {
        let geometry = RctlRemoteVideoGeometry(
            sourceSize: CGSize(width: 100, height: 100),
            rotation: rotation,
            viewportSize: CGSize(width: 100, height: 100)
        )

        #expect(geometry.normalizedRemotePoint(for: .zero, clamped: false) == expected)
    }

    @Test("Dragged touches clamp to the remote edge")
    func clamping() {
        let geometry = RctlRemoteVideoGeometry(
            sourceSize: CGSize(width: 200, height: 100),
            rotation: 0,
            viewportSize: CGSize(width: 200, height: 200)
        )

        #expect(geometry.normalizedRemotePoint(for: CGPoint(x: -20, y: 250), clamped: true) == CGPoint(x: 0, y: 1))
    }
}
