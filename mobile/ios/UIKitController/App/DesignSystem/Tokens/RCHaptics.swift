import UIKit

/// Haptic vocabulary. Generators are created lazily and reused; call
/// `prepare(_:)` on touch-down for latency-sensitive feedback.
@MainActor
enum RCHaptics {
    enum Kind: Sendable {
        /// Segment, menu highlight, picker changes.
        case selection
        /// Primary taps.
        case light
        /// Lift of a context menu, lock-on.
        case medium
        /// Informational nudge that is not an error.
        case soft
        case success
        case warning
        case error
    }

    private static var selectionGenerator: UISelectionFeedbackGenerator?
    private static var impactGenerators: [Int: UIImpactFeedbackGenerator] = [:]
    private static var notificationGenerator: UINotificationFeedbackGenerator?

    static func play(_ kind: Kind) {
        switch kind {
        case .selection:
            selection().selectionChanged()
        case .light:
            impact(.light).impactOccurred()
        case .medium:
            impact(.medium).impactOccurred()
        case .soft:
            impact(.soft).impactOccurred(intensity: 0.7)
        case .success:
            notification().notificationOccurred(.success)
        case .warning:
            notification().notificationOccurred(.warning)
        case .error:
            notification().notificationOccurred(.error)
        }
    }

    static func prepare(_ kind: Kind) {
        switch kind {
        case .selection: selection().prepare()
        case .light: impact(.light).prepare()
        case .medium: impact(.medium).prepare()
        case .soft: impact(.soft).prepare()
        case .success, .warning, .error: notification().prepare()
        }
    }

    private static func selection() -> UISelectionFeedbackGenerator {
        if let selectionGenerator { return selectionGenerator }
        let generator = UISelectionFeedbackGenerator()
        selectionGenerator = generator
        return generator
    }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        if let generator = impactGenerators[style.rawValue] { return generator }
        let generator = UIImpactFeedbackGenerator(style: style)
        impactGenerators[style.rawValue] = generator
        return generator
    }

    private static func notification() -> UINotificationFeedbackGenerator {
        if let notificationGenerator { return notificationGenerator }
        let generator = UINotificationFeedbackGenerator()
        notificationGenerator = generator
        return generator
    }
}
