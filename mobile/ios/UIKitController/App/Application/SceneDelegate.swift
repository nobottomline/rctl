import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var environment: AppEnvironment?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let environment = AppEnvironment()
        self.environment = environment
        environment.appearance.attach(to: window)
        window.tintColor = RCColor.accent
        window.rootViewController = environment.router.makeRootNavigationController()
        self.window = window
        window.makeKeyAndVisible()
        environment.start(in: window)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        environment?.lifecycle.setActive(true)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        environment?.lifecycle.setActive(false)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        environment?.lifecycle.setActive(false)
    }
}
