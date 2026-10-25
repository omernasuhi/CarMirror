import Combine
import Foundation

/// Telefon arayüzünde gösterilen bağlantı durumu.
final class MirrorState: ObservableObject {
    static let shared = MirrorState()

    @Published private(set) var isCarPlayConnected = false
    /// Yayın eklentisi (tüm iPhone ekranı) bağlı.
    @Published private(set) var isBroadcasting = false
    @Published private(set) var isInAppMirroring = false

    private init() {}

    func update(carPlayConnected: Bool) {
        DispatchQueue.main.async { self.isCarPlayConnected = carPlayConnected }
    }

    func update(broadcasting: Bool) {
        DispatchQueue.main.async { self.isBroadcasting = broadcasting }
    }

    func update(inAppMirroring: Bool) {
        DispatchQueue.main.async { self.isInAppMirroring = inAppMirroring }
    }
}
