import UIKit

/// Navigation container with the system bar hidden (screens draw `RCTopBar`)
/// and the edge-swipe back gesture kept working. Status bar style, home
/// indicator, deferred screen edges and orientations follow the top screen.
@MainActor
final class RCNavigationController: UINavigationController, UIGestureRecognizerDelegate, UINavigationControllerDelegate {
    override init(rootViewController: UIViewController) {
        super.init(rootViewController: rootViewController)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setNavigationBarHidden(true, animated: false)
        interactivePopGestureRecognizer?.delegate = self
        delegate = self
        view.backgroundColor = RCColor.background
    }

    override var childForStatusBarStyle: UIViewController? { topViewController }
    override var childForStatusBarHidden: UIViewController? { topViewController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { topViewController }
    override var childForScreenEdgesDeferringSystemGestures: UIViewController? { topViewController }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        topViewController?.supportedInterfaceOrientations ?? .allButUpsideDown
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === interactivePopGestureRecognizer else { return true }
        guard viewControllers.count > 1, transitionCoordinator == nil else { return false }
        return (topViewController as? RCViewController)?.allowsInteractivePop ?? true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Horizontal scrollers inside a screen must not steal the edge swipe.
        gestureRecognizer === interactivePopGestureRecognizer
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }
}

/// Base screen. Front-door screens use `.adaptive` chrome (follow the
/// appearance setting); media screens use `.stage` and are always dark.
@MainActor
class RCViewController: UIViewController {
    enum Chrome { case adaptive, stage }

    let chrome: Chrome

    /// Override to block the edge-swipe back gesture (e.g. while in Control mode or a request is in flight).
    var allowsInteractivePop: Bool { true }

    init(chrome: Chrome = .adaptive) {
        self.chrome = chrome
        super.init(nibName: nil, bundle: nil)
        if chrome == .stage {
            overrideUserInterfaceStyle = .dark
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = chrome == .stage ? RCColor.stage : RCColor.background
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        if chrome == .stage { return .lightContent }
        return traitCollection.userInterfaceStyle == .dark ? .lightContent : .darkContent
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            setNeedsStatusBarAppearanceUpdate()
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        traitCollection.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }
}
