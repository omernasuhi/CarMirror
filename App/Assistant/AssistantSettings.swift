import Combine
import Foundation

enum AssistantModel: String, CaseIterable, Identifiable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opus: return "Claude Opus 5.5 (en yetenekli)"
        case .sonnet: return "Claude Sonnet 5.5 (hızlı)"
        case .haiku: return "Claude Haiku 5.5 (en hızlı, en ucuz)"
        }
    }

    /// Güvenlik sınıflandırıcısı bir isteği reddederse sunucunun başka bir
    /// modelle yeniden denemesi (`fallbacks: "default"`); Haiku'da yok.
    var supportsServerFallback: Bool { self != .haiku }
}

enum VoiceProvider: String, CaseIterable, Identifiable {
    case apple
    case elevenLabs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple (cihaz içi, ücretsiz)"
        case .elevenLabs: return "ElevenLabs (doğal ses)"
        }
    }
}

/// Asistan ayarları. Gizli anahtarlar anahtar zincirinde, diğerleri UserDefaults'ta.
final class AssistantSettings: ObservableObject {
    static let shared = AssistantSettings()

    private enum Keys {
        static let anthropicAPIKey = "assistant.anthropicAPIKey"
        static let elevenLabsAPIKey = "assistant.elevenLabsAPIKey"
        static let elevenLabsVoiceID = "assistant.elevenLabsVoiceID"
        static let model = "assistant.model"
        static let voiceProvider = "assistant.voiceProvider"
        static let assistantName = "assistant.name"
        static let honorific = "assistant.honorific"
        static let userName = "assistant.userName"
        static let startsAtLaunch = "assistant.startsAtLaunch"
        static let autoListen = "assistant.autoListen"
    }

    static let defaultAssistantName = "Alfred"
    static let defaultHonorific = "efendim"

    private let defaults: UserDefaults
    private let secrets: SecretStore

    @Published var anthropicAPIKey: String {
        didSet { secrets.set(anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Keys.anthropicAPIKey) }
    }
    @Published var elevenLabsAPIKey: String {
        didSet { secrets.set(elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Keys.elevenLabsAPIKey) }
    }
    @Published var elevenLabsVoiceID: String {
        didSet { defaults.set(elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.elevenLabsVoiceID) }
    }
    @Published var model: AssistantModel {
        didSet { defaults.set(model.rawValue, forKey: Keys.model) }
    }
    @Published var voiceProvider: VoiceProvider {
        didSet { defaults.set(voiceProvider.rawValue, forKey: Keys.voiceProvider) }
    }
    @Published var assistantName: String {
        didSet { defaults.set(assistantName, forKey: Keys.assistantName) }
    }
    @Published var honorific: String {
        didSet { defaults.set(honorific, forKey: Keys.honorific) }
    }
    @Published var userName: String {
        didSet { defaults.set(userName, forKey: Keys.userName) }
    }
    /// Uygulama açılınca asistan sekmesi gelsin.
    @Published var startsAtLaunch: Bool {
        didSet { defaults.set(startsAtLaunch, forKey: Keys.startsAtLaunch) }
    }
    /// Asistan konuşmasını bitirince tekrar dinlemeye başlasın.
    @Published var autoListen: Bool {
        didSet { defaults.set(autoListen, forKey: Keys.autoListen) }
    }

    init(defaults: UserDefaults = .standard, secrets: SecretStore = KeychainStore.shared) {
        self.defaults = defaults
        self.secrets = secrets
        anthropicAPIKey = secrets.string(for: Keys.anthropicAPIKey) ?? ""
        elevenLabsAPIKey = secrets.string(for: Keys.elevenLabsAPIKey) ?? ""
        elevenLabsVoiceID = defaults.string(forKey: Keys.elevenLabsVoiceID) ?? ""
        model = AssistantModel(rawValue: defaults.string(forKey: Keys.model) ?? "") ?? .opus
        voiceProvider = VoiceProvider(rawValue: defaults.string(forKey: Keys.voiceProvider) ?? "") ?? .apple
        assistantName = defaults.string(forKey: Keys.assistantName) ?? Self.defaultAssistantName
        honorific = defaults.string(forKey: Keys.honorific) ?? Self.defaultHonorific
        userName = defaults.string(forKey: Keys.userName) ?? ""
        startsAtLaunch = defaults.object(forKey: Keys.startsAtLaunch) as? Bool ?? true
        autoListen = defaults.object(forKey: Keys.autoListen) as? Bool ?? true
    }

    // MARK: - Türetilmiş değerler

    /// Geliştirme kolaylığı: Xcode şemasının ortam değişkenleri anahtar
    /// girilmemişse kullanılır (CARMIRROR_ANTHROPIC_API_KEY vb.).
    private static func environmentValue(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var effectiveAnthropicAPIKey: String {
        let stored = anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? Self.environmentValue("CARMIRROR_ANTHROPIC_API_KEY") : stored
    }

    var effectiveElevenLabsAPIKey: String {
        let stored = elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? Self.environmentValue("CARMIRROR_ELEVENLABS_API_KEY") : stored
    }

    var effectiveElevenLabsVoiceID: String {
        let stored = elevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.isEmpty ? Self.environmentValue("CARMIRROR_ELEVENLABS_VOICE_ID") : stored
    }

    var isAIConfigured: Bool { !effectiveAnthropicAPIKey.isEmpty }

    var isElevenLabsConfigured: Bool {
        !effectiveElevenLabsAPIKey.isEmpty && !effectiveElevenLabsVoiceID.isEmpty
    }

    /// Seçilen sağlayıcı kullanılamıyorsa Apple'a düşer.
    var effectiveVoiceProvider: VoiceProvider {
        voiceProvider == .elevenLabs && isElevenLabsConfigured ? .elevenLabs : .apple
    }

    var effectiveAssistantName: String {
        let trimmed = assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultAssistantName : trimmed
    }

    var effectiveHonorific: String {
        let trimmed = honorific.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultHonorific : trimmed
    }

    var persona: AssistantPersona {
        AssistantPersona(
            assistantName: effectiveAssistantName,
            honorific: effectiveHonorific,
            userName: userName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
