import CarPlay
import UIKit

/// CarPlay sahnesi. Özel bir pencereye (CPWindow) çizim yapabilmek için
/// uygulamanın navigasyon uygulaması olarak (`com.apple.developer.carplay-maps`)
/// tanımlanması gerekir; bu yüzden kök şablon bir `CPMapTemplate`'tir ve
/// "harita" yerine telefonun ekranı çizilir.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var carWindow: CPWindow?
    private var mirrorViewController: CarPlayMirrorViewController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController
        carWindow = window

        let viewController = CarPlayMirrorViewController()
        window.rootViewController = viewController
        mirrorViewController = viewController

        let mapTemplate = CPMapTemplate()
        mapTemplate.automaticallyHidesNavigationBar = true
        mapTemplate.hidesButtonsWithNavigationBar = true
        mapTemplate.trailingNavigationBarButtons = [makeFillButton(for: viewController)]
        interfaceController.setRootTemplate(mapTemplate, animated: false, completion: nil)

        MirrorReceiver.shared.restartListener()
        MirrorReceiver.shared.setSink(viewController.sink)
        MirrorState.shared.update(carPlayConnected: true)

        #if targetEnvironment(simulator)
        // Simülatörde iOS ekran yayını çalışmadığından CarPlay ekranı açılınca
        // uygulamanın kendi ekranı yansıtılmaya başlar.
        InAppMirror.shared.autoStartWhenPossible = true
        InAppMirror.shared.startOnPhoneWindow()
        #endif
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        MirrorReceiver.shared.setSink(nil)
        MirrorState.shared.update(carPlayConnected: false)
        mirrorViewController = nil
        carWindow = nil
        self.interfaceController = nil

        #if targetEnvironment(simulator)
        InAppMirror.shared.autoStartWhenPossible = false
        InAppMirror.shared.stop()
        #endif
    }

    private func makeFillButton(for viewController: CarPlayMirrorViewController) -> CPBarButton {
        CPBarButton(title: Self.fillButtonTitle(fillsScreen: viewController.fillsScreen)) { [weak viewController] button in
            guard let viewController else { return }
            viewController.fillsScreen.toggle()
            button.title = Self.fillButtonTitle(fillsScreen: viewController.fillsScreen)
        }
    }

    private static func fillButtonTitle(fillsScreen: Bool) -> String {
        fillsScreen ? "Sığdır" : "Doldur"
    }
}
