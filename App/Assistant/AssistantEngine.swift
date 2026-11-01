import Combine
import Foundation

/// Asistanın beyni ile sesi arasındaki akışı yönetir:
/// karşılama → dinleme → düşünme (Claude) → konuşma → (isteğe bağlı) tekrar dinleme.
/// Telefon ve CarPlay ekranları aynı motoru gösterir.
///
/// Tüm yöntemler ana iş parçacığından çağrılır; arka plandaki işler
/// `Task { @MainActor in }` ile ana aktöre bağlanır.
final class AssistantEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case greeting
        case listening
        case thinking
        case speaking
    }

    enum Surface: Hashable {
        case phone
        case car
    }

    struct Entry: Identifiable, Equatable {
        enum Role: Equatable {
            case user
            case assistant
        }

        let id = UUID()
        var role: Role
        var text: String
    }

    static let shared = AssistantEngine(
        settings: .shared,
        listener: SpeechListener(),
        brainFactory: AssistantEngine.makeBrain,
        voiceFactory: AssistantEngine.makeVoice
    )

    @Published private(set) var state: State = .idle
    /// Dinlerken canlı yazıya dökülen konuşma; sonra son kullanıcı cümlesi.
    @Published private(set) var transcript = ""
    /// Asistanın o anki (akış halinde gelen) cevabı.
    @Published private(set) var reply = ""
    /// Ses seviyesi (0...1): dinlerken mikrofon, konuşurken çıkış.
    @Published private(set) var level: Float = 0
    @Published private(set) var entries: [Entry] = []
    /// Hata ya da ipucu metni.
    @Published private(set) var statusMessage: String?
    @Published private(set) var isAuthorized: Bool?

    let settings: AssistantSettings
    /// Demo: karşılama yapılır ama mikrofon açılmaz (CI ekran görüntüleri için).
    var isDemoMode: Bool
    /// Sessiz: hiç ses çalınmaz (birim testleri).
    var isSilent = false
    var activatesAudioSession = true
    var navigationHandler: (String) -> Void = { destination in NavigationLauncher.startDirections(to: destination) }
    var placesHandler: (String) -> Void = { query in NavigationLauncher.searchPlaces(query) }
    var now: () -> Date = { Date() }
    /// Karşılamanın tekrarlanması için geçmesi gereken süre (ör. CarPlay'e sonradan bağlanınca).
    var greetingInterval: TimeInterval = 180
    var silenceTimeout: TimeInterval = 1.3
    var maxListenDuration: TimeInterval = 20

    private let listener: SpeechInput
    private let brainFactory: (AssistantSettings) -> AssistantBrain?
    private let voiceFactory: (AssistantSettings) -> VoiceOutput
    private let speechQueue: SpeechQueue
    private var voiceCacheKey = ""
    private var apiMessages: [ClaudeMessage] = []
    private var lastGreeting: Date?
    private var visibleSurfaces: Set<Surface> = []
    private var currentTask: Task<Void, Never>?
    private var generation = 0
    private var audioSessionActivated = false

    init(
        settings: AssistantSettings,
        listener: SpeechInput,
        brainFactory: @escaping (AssistantSettings) -> AssistantBrain?,
        voiceFactory: @escaping (AssistantSettings) -> VoiceOutput
    ) {
        self.settings = settings
        self.listener = listener
        self.brainFactory = brainFactory
        self.voiceFactory = voiceFactory
        let voice = voiceFactory(settings)
        speechQueue = SpeechQueue(voice: voice)
        let underTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        isDemoMode = UserDefaults.standard.bool(forKey: "CarMirrorAssistantDemo") || underTests
        isSilent = underTests
        voice.onLevel = { [weak self] value in self?.updateLevel(value) }
    }

    static func makeBrain(settings: AssistantSettings) -> AssistantBrain? {
        let key = settings.effectiveAnthropicAPIKey
        guard !key.isEmpty else { return nil }
        return ClaudeClient(apiKey: key, model: settings.model)
    }

    static func makeVoice(settings: AssistantSettings) -> VoiceOutput {
        switch settings.effectiveVoiceProvider {
        case .elevenLabs:
            return ElevenLabsVoice(apiKey: settings.effectiveElevenLabsAPIKey, voiceID: settings.effectiveElevenLabsVoiceID)
        case .apple:
            return AppleVoice()
        }
    }

    /// API'ye gönderilen geçmiş (testler için).
    var conversation: [ClaudeMessage] { apiMessages }

    var persona: AssistantPersona { settings.persona }

    // MARK: - Görünürlük

    func surfaceDidAppear(_ surface: Surface) {
        visibleSurfaces.insert(surface)
        let due = lastGreeting.map { now().timeIntervalSince($0) >= greetingInterval } ?? true
        if due, state == .idle {
            greet()
        }
    }

    func surfaceDidDisappear(_ surface: Surface) {
        visibleSurfaces.remove(surface)
        if visibleSurfaces.isEmpty, state == .listening {
            interrupt()
        }
    }

    // MARK: - Kullanıcı eylemleri

    func greet() {
        let text = persona.greeting(at: now())
        lastGreeting = now()
        runSession {
            try await self.speak(text)
            try await self.listenLoopIfWanted()
        }
        state = .greeting
        reply = text
        entries.append(Entry(role: .assistant, text: text))
    }

    /// Dinlemeyi başlatır; demo modunda hiçbir şey yapmaz.
    func startListening() {
        guard !isDemoMode else { return }
        runSession {
            try await self.listenLoop()
        }
        state = .listening
        transcript = ""
    }

    /// Orb'a dokunma: dinliyorsa durdurur, konuşuyorsa keser ve dinler, boştaysa dinler.
    func toggleListening() {
        if state == .listening {
            interrupt()
        } else {
            interrupt()
            startListening()
        }
    }

    /// Yazarak gönderilen mesaj (simülatörde mikrofon yokken de çalışır).
    func submit(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runSession {
            try await self.respond(to: trimmed)
            try await self.listenLoopIfWanted()
        }
        state = .thinking
        transcript = trimmed
    }

    /// Konuşmayı ve dinlemeyi keser.
    func interrupt() {
        generation += 1
        currentTask?.cancel()
        currentTask = nil
        listener.cancel()
        speechQueue.cancel()
        state = .idle
        level = 0
    }

    func reset() {
        interrupt()
        apiMessages.removeAll()
        entries.removeAll()
        reply = ""
        transcript = ""
        statusMessage = nil
        lastGreeting = nil
    }

    func speakSample() {
        let text = "Sesim böyle \(persona.honorific). Yolculuk boyunca emrinizdeyim."
        runSession {
            try await self.speakStatement(text)
        }
        state = .speaking
    }

    // MARK: - Oturum

    private func runSession(_ body: @escaping () async throws -> Void) {
        interrupt()
        let generation = self.generation
        statusMessage = nil
        currentTask = Task { @MainActor [weak self] in
            do {
                try await body()
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.generation else { return }
                self.statusMessage = error.localizedDescription
                self.reply = ""
                try? await self.speakStatement("Üzgünüm \(self.persona.honorific), bir sorun oldu.")
            }
            guard let self, generation == self.generation else { return }
            self.state = .idle
            self.level = 0
        }
    }

    @MainActor
    private func listenLoopIfWanted() async throws {
        guard settings.autoListen, !isDemoMode, !visibleSurfaces.isEmpty else { return }
        try await listenLoop()
    }

    @MainActor
    private func listenLoop() async throws {
        while true {
            let text = try await listenOnce()
            try Task.checkCancellation()
            guard !text.isEmpty else { return }
            try await respond(to: text)
            try Task.checkCancellation()
            guard settings.autoListen, !visibleSurfaces.isEmpty else { return }
        }
    }

    @MainActor
    private func listenOnce() async throws -> String {
        if isAuthorized != true {
            let granted = await listener.requestAuthorization()
            try Task.checkCancellation()
            isAuthorized = granted
            guard granted else {
                statusMessage = "Mikrofon ve konuşma tanıma izni gerekli. Ayarlar → CarMirror bölümünden izin verebilirsiniz."
                return ""
            }
        }
        ensureAudioSession()
        state = .listening
        transcript = ""
        statusMessage = nil
        listener.onPartial = { [weak self] text in self?.transcript = text }
        listener.onLevel = { [weak self] value in self?.updateLevel(value) }
        do {
            return try await listener.listen(silenceTimeout: silenceTimeout, maxDuration: maxListenDuration)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            statusMessage = error.localizedDescription
            return ""
        }
    }

    @MainActor
    private func respond(to userText: String) async throws {
        transcript = userText
        entries.append(Entry(role: .user, text: userText))
        reply = ""
        level = 0
        state = .thinking
        statusMessage = nil

        guard let brain = brainFactory(settings) else {
            try await speakStatement("Henüz bir API anahtarım yok \(persona.honorific). Ayarlardan Claude anahtarını girerseniz hemen konuşmaya başlarız.")
            return
        }

        apiMessages.append(.user(text: AssistantPersona.userMessage(userText, at: now())))
        trimHistoryIfNeeded()
        prepareVoice()

        var chunker = SentenceChunker()
        var fullReply = ""
        var rounds = 0
        let system = persona.systemPrompt()

        while rounds < 4 {
            rounds += 1
            var toolResults: [(toolUseID: String, content: String)] = []
            var turn: ClaudeTurn?

            for try await event in brain.stream(system: system, messages: apiMessages, tools: AssistantTools.definitions) {
                try Task.checkCancellation()
                switch event {
                case let .text(piece):
                    fullReply += piece
                    reply = fullReply
                    for sentence in chunker.append(piece) {
                        state = .speaking
                        speechQueue.enqueue(sentence)
                    }
                case let .toolCall(call):
                    toolResults.append((toolUseID: call.id, content: handle(call)))
                case let .done(finished):
                    turn = finished
                case let .failure(message):
                    throw ClaudeError.stream(message)
                }
            }

            guard let turn else { throw ClaudeError.invalidResponse }
            if turn.blocks.isEmpty {
                // Model hiçbir şey üretmediyse (ör. ret) bu alışverişi geçmişe yazma.
                apiMessages.removeLast()
            } else {
                apiMessages.append(turn.assistantMessage)
            }

            if turn.stopReason == "tool_use", !toolResults.isEmpty, !turn.blocks.isEmpty {
                apiMessages.append(.toolResults(toolResults))
                continue
            }
            if turn.stopReason == "refusal" {
                let refusal = "Bu konuda yardımcı olamıyorum \(persona.honorific)."
                fullReply = refusal
                reply = refusal
                state = .speaking
                speechQueue.enqueue(refusal)
            }
            break
        }

        if let remainder = chunker.flush() {
            state = .speaking
            speechQueue.enqueue(remainder)
        }
        if fullReply.isEmpty {
            fullReply = "Sizi dinliyorum \(persona.honorific)."
            reply = fullReply
            state = .speaking
            speechQueue.enqueue(fullReply)
        }
        entries.append(Entry(role: .assistant, text: fullReply))
        await speechQueue.waitUntilIdle()
        try Task.checkCancellation()
    }

    /// Karşılama gibi hazır metni okur (geçmişe eklemez; arayüz zaten güncellendi).
    @MainActor
    private func speak(_ text: String) async throws {
        prepareVoice()
        speechQueue.enqueue(text)
        await speechQueue.waitUntilIdle()
        try Task.checkCancellation()
    }

    @MainActor
    private func speakStatement(_ text: String) async throws {
        reply = text
        entries.append(Entry(role: .assistant, text: text))
        state = .speaking
        try await speak(text)
    }

    private func handle(_ call: ClaudeToolCall) -> String {
        let input = call.input
        switch call.name {
        case AssistantTools.startNavigation:
            let destination = (input["destination"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !destination.isEmpty else { return "Hata: hedef belirtilmedi." }
            navigationHandler(destination)
            return "Apple Haritalar'da \(destination) için araç rotası başlatıldı."
        case AssistantTools.searchPlaces:
            let query = (input["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return "Hata: arama metni belirtilmedi." }
            placesHandler(query)
            return "Apple Haritalar'da \"\(query)\" araması açıldı; sonuçlar araç ekranında."
        default:
            return "Hata: bilinmeyen araç \(call.name)."
        }
    }

    /// Geçmişi sınırlar; yalnızca baştan ve düz bir kullanıcı mesajından
    /// itibaren keser ki araç çağrısı/sonucu çiftleri bozulmasın.
    private func trimHistoryIfNeeded(maxMessages: Int = 30) {
        guard apiMessages.count > maxMessages else { return }
        let earliest = apiMessages.count - maxMessages
        for index in earliest..<apiMessages.count {
            let message = apiMessages[index]
            if message.role == "user", message.content.first?["type"] as? String == "text" {
                apiMessages.removeFirst(index)
                return
            }
        }
    }

    private func prepareVoice() {
        ensureAudioSession()
        let key = "\(settings.effectiveVoiceProvider.rawValue)|\(settings.effectiveElevenLabsAPIKey.count)|\(settings.effectiveElevenLabsVoiceID)|\(isSilent)"
        guard key != voiceCacheKey, speechQueue.isIdle else { return }
        voiceCacheKey = key
        let voice: VoiceOutput = isSilent ? SilentVoice() : voiceFactory(settings)
        voice.onLevel = { [weak self] value in self?.updateLevel(value) }
        speechQueue.voice = voice
    }

    private func ensureAudioSession() {
        guard activatesAudioSession, !isSilent, !audioSessionActivated else { return }
        audioSessionActivated = true
        AudioSessionController.activate()
    }

    private func updateLevel(_ value: Float) {
        level = level * 0.5 + value * 0.5
    }
}

/// Hiç ses çalmayan çıkış (testler).
final class SilentVoice: VoiceOutput {
    var onLevel: ((Float) -> Void)?
    private(set) var spoken: [String] = []

    func speak(_ text: String) async throws {
        spoken.append(text)
    }

    func stop() {}
}
