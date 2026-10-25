import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        MirrorReceiver.shared.onBroadcastClientChange = { connected in
            MirrorState.shared.update(broadcasting: connected)
            if connected {
                // Tüm ekran yayını uygulama içi yansıtmayı da kapsar.
                DispatchQueue.main.async { InAppMirror.shared.stop() }
            }
        }
        // CarPlay uygulamayı arka planda başlatsa da yayın eklentisi bağlanabilsin.
        MirrorReceiver.shared.start()
        return true
    }
}
