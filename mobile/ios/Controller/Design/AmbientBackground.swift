import SwiftUI

/// Warm parchment backdrop with two soft color washes and a slowly drifting
/// constellation of particles. Motion is disabled under Reduce Motion, while
/// the app is inactive, and whenever the hosting screen is not visible.
struct AmbientBackground: View {
    var paused = false
    var particleOpacity = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [ControllerPalette.canvasDeep, ControllerPalette.canvas],
                startPoint: .top,
                endPoint: .bottom
            )
            GeometryReader { proxy in
                let size = proxy.size
                ZStack {
                    RadialGradient(
                        colors: [ControllerPalette.signal.opacity(0.12), .clear],
                        center: .center, startRadius: 0, endRadius: size.width * 0.72
                    )
                    .frame(width: size.width * 1.5, height: size.width * 1.1)
                    .position(x: size.width * 0.86, y: -size.width * 0.02)
                    RadialGradient(
                        colors: [ControllerPalette.healthy.opacity(0.07), .clear],
                        center: .center, startRadius: 0, endRadius: size.width * 0.6
                    )
                    .frame(width: size.width * 1.2, height: size.width * 1.0)
                    .position(x: size.width * 0.06, y: size.height * 0.08)
                    RadialGradient(
                        colors: [ControllerPalette.signalHigh.opacity(0.06), .clear],
                        center: .center, startRadius: 0, endRadius: size.width * 0.7
                    )
                    .frame(width: size.width * 1.4, height: size.width * 1.2)
                    .position(x: size.width * 0.3, y: size.height * 1.02)
                }
            }
            ParticleField(paused: paused || reduceMotion || scenePhase != .active, frozen: reduceMotion)
                .opacity(particleOpacity)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ParticleField: View {
    let paused: Bool
    let frozen: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
            Canvas(rendersAsynchronously: true) { canvas, size in
                let time = frozen ? 40.0 : context.date.timeIntervalSinceReferenceDate
                ParticleSystem.draw(in: &canvas, size: size, time: time)
            }
        }
    }
}

/// Stateless particle model: positions are pure functions of time, so the
/// field never accumulates drift and renders identically in previews.
enum ParticleSystem {
    struct Particle {
        let origin: CGPoint      // unit space
        let velocity: CGVector   // unit space per second
        let radius: CGFloat
        let swayPhase: Double
        let swayAmplitude: CGFloat
        let warm: Bool
        let ring: Bool
        let brightness: Double
    }

    private static let cache = ParticleCache()

    static func draw(in canvas: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 0, size.height > 0 else { return }
        let particles = cache.particles(for: size)
        var points: [CGPoint] = []
        points.reserveCapacity(particles.count)
        for particle in particles {
            points.append(position(of: particle, size: size, time: time))
        }

        let linkDistance = min(140, max(96, size.width * 0.3))
        for i in points.indices {
            for j in (i + 1)..<points.count {
                let dx = points[i].x - points[j].x
                let dy = points[i].y - points[j].y
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance < linkDistance else { continue }
                let alpha = (1 - distance / linkDistance)
                var segment = Path()
                segment.move(to: points[i])
                segment.addLine(to: points[j])
                canvas.stroke(
                    segment,
                    with: .color(ControllerPalette.inkDim.opacity(0.16 * alpha)),
                    lineWidth: 0.8
                )
            }
        }

        for (index, particle) in particles.enumerated() {
            let point = points[index]
            let color = particle.warm ? ControllerPalette.signal : ControllerPalette.inkDim
            let rect = CGRect(
                x: point.x - particle.radius, y: point.y - particle.radius,
                width: particle.radius * 2, height: particle.radius * 2
            )
            if particle.ring {
                canvas.stroke(Path(ellipseIn: rect), with: .color(color.opacity(0.55 * particle.brightness)), lineWidth: 1)
            } else {
                let glow = rect.insetBy(dx: -particle.radius * 1.6, dy: -particle.radius * 1.6)
                canvas.fill(
                    Path(ellipseIn: glow),
                    with: .radialGradient(
                        Gradient(colors: [color.opacity(0.22 * particle.brightness), .clear]),
                        center: point, startRadius: 0, endRadius: glow.width / 2
                    )
                )
                canvas.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.75 * particle.brightness)))
            }
        }
    }

    private static func position(of particle: Particle, size: CGSize, time: TimeInterval) -> CGPoint {
        let margin: CGFloat = 0.06
        let span = 1 + margin * 2
        var x = particle.origin.x + particle.velocity.dx * time
        var y = particle.origin.y + particle.velocity.dy * time
        x = x - floor((x + margin) / span) * span
        y = y - floor((y + margin) / span) * span
        let sway = sin(time * 0.35 + particle.swayPhase) * particle.swayAmplitude
        return CGPoint(x: (x + sway) * size.width, y: y * size.height)
    }

    /// Particle sets are seeded per canvas size so rotation and split view keep
    /// a stable field instead of re-rolling positions on every layout pass. A
    /// few sizes are kept because two canvases are alive during a navigation
    /// transition and may differ by the safe area.
    private final class ParticleCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(size: CGSize, particles: [Particle])] = []

        func particles(for size: CGSize) -> [Particle] {
            lock.lock()
            defer { lock.unlock() }
            if let hit = entries.first(where: { $0.size == size }) { return hit.particles }
            let made = ParticleSystem.makeParticles(for: size)
            entries.append((size, made))
            if entries.count > 4 { entries.removeFirst() }
            return made
        }
    }

    private static func makeParticles(for size: CGSize) -> [Particle] {
        let area = Double(size.width * size.height)
        let count = min(88, max(28, Int(area / 8200)))
        var rng = SplitMix64(seed: 0x52_43_54_4C)
        return (0..<count).map { index in
            let speed = 0.004 + rng.nextDouble() * 0.010
            let angle = rng.nextDouble() * .pi * 2
            return Particle(
                origin: CGPoint(x: rng.nextDouble(), y: rng.nextDouble()),
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed - 0.004),
                radius: 1.4 + CGFloat(rng.nextDouble()) * 2.2,
                swayPhase: rng.nextDouble() * .pi * 2,
                swayAmplitude: 0.004 + CGFloat(rng.nextDouble()) * 0.01,
                warm: index % 5 == 0,
                ring: index % 7 == 3,
                brightness: 0.55 + rng.nextDouble() * 0.45
            )
        }
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
