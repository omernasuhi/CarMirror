import Foundation

/// Ana uygulama ile yayın eklentisinin ortak kullandığı yapılandırma.
/// Değerler her iki hedefin Info.plist dosyasından okunur; Info.plist de
/// bunları proje ayarlarındaki `APP_GROUP_ID` ve `PRODUCT_BUNDLE_IDENTIFIER`
/// değerlerinden alır.
enum MirrorConfig {
    static let appGroupID: String =
        Bundle.main.object(forInfoDictionaryKey: "CarMirrorAppGroup") as? String ?? ""

    /// Yalnızca ana uygulamanın Info.plist dosyasında bulunur.
    static let broadcastExtensionBundleID: String? =
        Bundle.main.object(forInfoDictionaryKey: "CarMirrorBroadcastExtension") as? String

    static let sharedDefaults: UserDefaults =
        appGroupID.isEmpty ? .standard : (UserDefaults(suiteName: appGroupID) ?? .standard)

    /// Yayın eklentisi ile uygulama arasındaki Unix soketinin yolu.
    static var socketPath: String? {
        #if targetEnvironment(simulator)
        // Simülatörde App Group klasörünün yolu, Unix soket adresine sığan
        // 104 baytı aşıyor. Simülatördeki uygulamalar Mac'in dosya sistemini
        // gördüğü için kısa bir /tmp yolu kullanılır.
        let device = ProcessInfo.processInfo.environment["SIMULATOR_UDID"]?.prefix(8) ?? "default"
        return "/tmp/carmirror-\(device).sock"
        #else
        // sockaddr_un.sun_path 104 baytla sınırlı olduğundan dosya adı kısa tutuldu.
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("cm.sock")
            .path
        #endif
    }
}

enum MirrorQuality: String, CaseIterable, Identifiable {
    case saver
    case balanced
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .saver: return "Tasarruf"
        case .balanced: return "Dengeli"
        case .high: return "Yüksek"
        }
    }

    /// Kodlanan görüntünün uzun kenarı (piksel).
    var maxLongSide: Int {
        switch self {
        case .saver: return 1280
        case .balanced: return 1600
        case .high: return 1920
        }
    }

    var bitRate: Int {
        switch self {
        case .saver: return 4_000_000
        case .balanced: return 8_000_000
        case .high: return 12_000_000
        }
    }

    var framesPerSecond: Int {
        switch self {
        case .saver, .balanced: return 30
        case .high: return 60
        }
    }
}

enum MirrorSettings {
    static let qualityKey = "quality"
    static let flipLandscapeKey = "flipLandscape"
    static let fillsCarScreenKey = "fillsCarScreen"

    static var quality: MirrorQuality {
        MirrorQuality(rawValue: MirrorConfig.sharedDefaults.string(forKey: qualityKey) ?? "") ?? .balanced
    }

    static var flipLandscape: Bool {
        MirrorConfig.sharedDefaults.bool(forKey: flipLandscapeKey)
    }

    static var fillsCarScreen: Bool {
        get { MirrorConfig.sharedDefaults.bool(forKey: fillsCarScreenKey) }
        set { MirrorConfig.sharedDefaults.set(newValue, forKey: fillsCarScreenKey) }
    }
}
