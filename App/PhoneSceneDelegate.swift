import SwiftUI
import UIKit

final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: ContentView())
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        if InAppMirror.shared.autoStartWhenPossible {
            InAppMirror.shared.startOnPhoneWindow()
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        MirrorReceiver.shared.restartListener()
    }
}
