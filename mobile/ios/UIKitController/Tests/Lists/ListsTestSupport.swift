import UIKit

/// Hosts views in a window under a fixed content size category, so text
/// metrics in view tests do not depend on the simulator's Dynamic Type setting.
@MainActor
final class ListsTraitHost {
    let window: UIWindow
    private let child = UIViewController()

    init(category: UIContentSizeCategory = .large) {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        window.rootViewController = root
        root.addChild(child)
        child.view.frame = root.view.bounds
        root.view.addSubview(child.view)
        child.didMove(toParent: root)
        root.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: child)
        window.isHidden = false
        window.layoutIfNeeded()
    }

    /// Adds `view` to the hosted hierarchy and lets traits propagate.
    @discardableResult
    func host<View: UIView>(_ view: View) -> View {
        child.view.addSubview(view)
        window.layoutIfNeeded()
        return view
    }

    var traits: UITraitCollection { child.traitCollection }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }
}
