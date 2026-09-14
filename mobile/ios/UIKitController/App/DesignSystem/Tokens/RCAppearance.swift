import Combine
import UIKit

/// Appearance preference for the front-door screens. The remote stage and the
/// camera scanner are always dark regardless of this setting.
enum RCAppearance: String, CaseIterable, Sendable {
    /// Follow iOS: light → warm parchment, dark → operator console.
    case system
    /// Always the warm parchment palette.
    case warm
    /// Always the dark operator-console palette.
    case console

    var title: String {
        switch self {
        case .system: "Match system"
        case .warm: "Warm"
        case .console: "Console"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .warm: .light
        case .console: .dark
        }
    }
}

@MainActor
final class RCAppearanceStore: ObservableObject {
    @Published private(set) var appearance: RCAppearance
    private let defaults: UserDefaults
    private static let key = "rctl.uikit.appearance.v1"
    private weak var window: UIWindow?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Self.key).flatMap(RCAppearance.init(rawValue:)) ?? .system
    }

    func attach(to window: UIWindow) {
        self.window = window
        window.overrideUserInterfaceStyle = appearance.interfaceStyle
    }

    func set(_ value: RCAppearance) {
        guard value != appearance else { return }
        appearance = value
        defaults.set(value.rawValue, forKey: Self.key)
        guard let window else { return }
        // Crossfade the whole window instead of letting every layer snap.
        UIView.transition(with: window, duration: RCMotion.reduceMotion ? 0 : 0.28, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            window.overrideUserInterfaceStyle = value.interfaceStyle
        }
    }
}
