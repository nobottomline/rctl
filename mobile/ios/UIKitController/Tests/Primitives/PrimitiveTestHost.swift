import UIKit
@testable import RctlUIKit

/// Hosts views in a real window under a content size category override, so
/// trait propagation, `didMoveToWindow` and layout run as in the app.
@MainActor
final class PrimitiveTestHost {
    let window: UIWindow
    private let parent = UIViewController()
    private let child = UIViewController()

    init(category: UIContentSizeCategory = .large, size: CGSize = CGSize(width: 390, height: 844)) {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
        }
        parent.addChild(child)
        parent.view.addSubview(child.view)
        child.didMove(toParent: parent)
        window.rootViewController = parent
        window.isHidden = false
        setCategory(category)
    }

    var container: UIView { child.view }

    func setCategory(_ category: UIContentSizeCategory) {
        parent.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: child)
        child.view.frame = parent.view.bounds
        window.layoutIfNeeded()
    }

    func add(_ view: UIView, frame: CGRect? = nil) {
        container.addSubview(view)
        if let frame { view.frame = frame }
        window.layoutIfNeeded()
    }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }
}
