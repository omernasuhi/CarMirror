import XCTest
@testable import CarMirror

// MARK: - Cümle bölücü

final class SentenceChunkerTests: XCTestCase {
    func testSplitsCompletedSentencesAndKeepsRemainder() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("Elbette efendim. Hemen "), ["Elbette efendim."])
        XCTAssertEqual(chunker.append("yola çıkıyoruz! Yol 3.5 km"), ["Hemen yola çıkıyoruz!"])
        XCTAssertEqual(chunker.flush(), "Yol 3.5 km")
        XCTAssertNil(chunker.flush())
    }

    func testDoesNotSplitDecimalsOrInitials() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("Saat 14.30 civarı varırız. Tamam"), ["Saat 14.30 civarı varırız."])
        XCTAssertEqual(chunker.append(" A. Bey aradı. Son"), ["Tamam A. Bey aradı."])
    }

    func testNewlineEndsSentence() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("Birinci satır\nİkinci"), ["Birinci satır"])
        XCTAssertEqual(chunker.flush(), "İkinci")
    }

    func testQuestionWithQuote() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("\"Nereye?\" dedi. Sonra"), ["\"Nereye?\"", "dedi."])
    }
}

// MARK: - Kişilik

final class AssistantPersonaTests: XCTestCase {
    private let persona = AssistantPersona(assistantName: "Alfred", honorific: "efendim", userName: "")

    func testSystemPromptMentionsNameHonorificAndTools() {
        let prompt = persona.systemPrompt()
        XCTAssertTrue(prompt.contains("Alfred"))
        XCTAssertTrue(prompt.contains("\"efendim\""))
        XCTAssertTrue(prompt.contains(AssistantTools.startNavigation))
        XCTAssertTrue(prompt.contains(AssistantTools.searchPlaces))
    }

    func testGreetingFollowsTimeOfDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 8)))
        let evening = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 20)))
        XCTAssertTrue(persona.greeting(at: morning, calendar: calendar, random: false).hasPrefix("Günaydın Efendim"))
        XCTAssertTrue(persona.greeting(at: evening, calendar: calendar, random: false).hasPrefix("İyi akşamlar Efendim"))

        let named = AssistantPersona(assistantName: "Alfred", honorific: "efendim", userName: "Ömer")
        XCTAssertTrue(named.greeting(at: morning, calendar: calendar, random: false).contains("Ömer efendim"))
    }

    func testUserMessageCarriesTime() {
        let message = AssistantPersona.userMessage("Kadıköy'e gidelim", at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(message.hasPrefix("(Zaman: "))
        XCTAssertTrue(message.hasSuffix("Kadıköy'e gidelim"))
    }

    func testNavigationURLs() throws {
        let directions = try XCTUnwrap(NavigationLauncher.directionsURL(to: "Kadıköy, İstanbul"))
        XCTAssertEqual(directions.scheme, "maps")
        XCTAssertTrue(directions.query?.contains("daddr=") == true)
        XCTAssertTrue(directions.query?.contains("dirflg=d") == true)
        let search = try XCTUnwrap(NavigationLauncher.searchURL(for: "benzin istasyonu"))
        XCTAssertTrue(search.query?.contains("q=benzin") == true)
    }
}

// MARK: - Akış ayrıştırıcı

final class ClaudeStreamParserTests: XCTestCase {
    private func events(for lines: [String]) -> [ClaudeStreamEvent] {
        let parser = ClaudeStreamParser()
        return lines.flatMap { parser.feed(line: $0) }
    }

    func testParsesTextThinkingAndToolUse() throws {
        let lines = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#,
            "",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hemen "}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"efendim."}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"start_navigation","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"destina"}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"tion\": \"Kadıköy\"}"}}"#,
            #"data: {"type":"content_block_stop","index":2}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        let parsed = events(for: lines)
        XCTAssertEqual(parsed.count, 4)

        guard case let .text(first) = parsed[0], case let .text(second) = parsed[1] else { return XCTFail("metin bekleniyordu") }
        XCTAssertEqual(first + second, "Hemen efendim.")

        guard case let .toolCall(call) = parsed[2] else { return XCTFail("araç çağrısı bekleniyordu") }
        XCTAssertEqual(call.id, "toolu_1")
        XCTAssertEqual(call.name, "start_navigation")
        XCTAssertEqual(call.input["destination"] as? String, "Kadıköy")

        guard case let .done(turn) = parsed[3] else { return XCTFail("bitiş bekleniyordu") }
        XCTAssertEqual(turn.stopReason, "tool_use")
        XCTAssertEqual(turn.text, "Hemen efendim.")
        XCTAssertEqual(turn.blocks.count, 3)
        XCTAssertEqual(turn.blocks[0]["type"] as? String, "thinking")
        XCTAssertEqual(turn.blocks[0]["signature"] as? String, "abc", "Thinking imzası geçmişe aynen dönmeli")
        XCTAssertEqual(turn.blocks[1]["text"] as? String, "Hemen efendim.")
        XCTAssertEqual((turn.blocks[2]["input"] as? [String: Any])?["destination"] as? String, "Kadıköy")
        XCTAssertEqual(turn.assistantMessage.role, "assistant")
    }

    func testErrorEventBecomesFailure() {
        let parsed = events(for: [#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#])
        guard case let .failure(message) = parsed.first else { return XCTFail("hata bekleniyordu") }
        XCTAssertEqual(message, "Overloaded")
    }

    func testIgnoresNoise() {
        XCTAssertTrue(events(for: ["event: ping", #"data: {"type":"ping"}"#, "", "garbage"]).isEmpty)
    }
}

// MARK: - HTTP istemcisi

final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    static var lastRequest: URLRequest?
    static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
        let (status, body) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ClaudeClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.lastBody = nil
        super.tearDown()
    }

    func testStreamingRequestShapeAndParsing() async throws {
        StubURLProtocol.handler = { _ in
            let body = [
                #"data: {"type":"message_start","message":{"id":"msg_1"}}"#,
                #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Elbette efendim."}}"#,
                #"data: {"type":"content_block_stop","index":0}"#,
                #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
                #"data: {"type":"message_stop"}"#,
            ].joined(separator: "\n\n") + "\n\n"
            return (200, Data(body.utf8))
        }

        let client = ClaudeClient(apiKey: "sk-test", model: .opus, session: session)
        var texts: [String] = []
        var finished: ClaudeTurn?
        for try await event in client.stream(system: "Sistem", messages: [.user(text: "Merhaba")], tools: AssistantTools.definitions) {
            switch event {
            case let .text(piece): texts.append(piece)
            case let .done(turn): finished = turn
            default: XCTFail("beklenmeyen olay")
            }
        }
        XCTAssertEqual(texts, ["Elbette efendim."])
        XCTAssertEqual(finished?.stopReason, "end_turn")

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), ClaudeClient.apiVersion)
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), ClaudeClient.fallbackBeta)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.lastBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["system"] as? String, "Sistem")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertNil(body["thinking"], "Opus 5.5'te thinking parametresi gönderilmez (uyarlanabilir varsayılan)")
        XCTAssertNil(body["temperature"])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, [AssistantTools.startNavigation, AssistantTools.searchPlaces, AssistantTools.stopNavigation, AssistantTools.tripStatus])
        XCTAssertEqual(tools.first?["strict"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
    }

    func testHaikuSendsNoFallback() throws {
        let client = ClaudeClient(apiKey: "sk-test", model: .haiku, session: session)
        let request = try client.makeRequest(system: "S", messages: [.user(text: "Selam")], tools: [])
        XCTAssertNil(request.value(forHTTPHeaderField: "anthropic-beta"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(body["fallbacks"])
        XCTAssertNil(body["tools"])
    }

    func testHTTPErrorIsReported() async {
        StubURLProtocol.handler = { _ in
            (401, Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))
        }
        let client = ClaudeClient(apiKey: "bad", model: .opus, session: session)
        do {
            for try await _ in client.stream(system: "S", messages: [.user(text: "Selam")], tools: []) {}
            XCTFail("hata bekleniyordu")
        } catch let error as ClaudeError {
            guard case let .http(status, message) = error else { return XCTFail("HTTP hatası bekleniyordu") }
            XCTAssertEqual(status, 401)
            XCTAssertEqual(message, "invalid x-api-key")
            XCTAssertTrue(error.localizedDescription.contains("anahtar"))
        } catch {
            XCTFail("beklenmeyen hata: \(error)")
        }
    }
}

// MARK: - Motor

final class ScriptedBrain: AssistantBrain {
    var rounds: [[ClaudeStreamEvent]]
    private(set) var requests: [[ClaudeMessage]] = []
    private(set) var systems: [String] = []

    init(rounds: [[ClaudeStreamEvent]]) {
        self.rounds = rounds
    }

    func stream(system: String, messages: [ClaudeMessage], tools: [[String: Any]]) -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        requests.append(messages)
        systems.append(system)
        let events = rounds.isEmpty ? [] : rounds.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    static func textRound(_ pieces: [String], stopReason: String = "end_turn") -> [ClaudeStreamEvent] {
        var events: [ClaudeStreamEvent] = pieces.map { .text($0) }
        let text = pieces.joined()
        events.append(.done(ClaudeTurn(blocks: [["type": "text", "text": text]], stopReason: stopReason, text: text)))
        return events
    }
}

final class RecordingVoice: VoiceOutput {
    var onLevel: ((Float) -> Void)?
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0

    func speak(_ text: String) async throws {
        spoken.append(text)
    }

    func stop() {
        stopCount += 1
    }
}

final class FakeListener: SpeechInput {
    var onLevel: ((Float) -> Void)?
    var onPartial: ((String) -> Void)?
    var authorized = true
    var transcripts: [String] = []
    private(set) var listenCount = 0
    private(set) var cancelCount = 0

    func requestAuthorization() async -> Bool { authorized }

    func listen(silenceTimeout: TimeInterval, maxDuration: TimeInterval) async throws -> String {
        listenCount += 1
        guard !transcripts.isEmpty else { return "" }
        let text = transcripts.removeFirst()
        onPartial?(text)
        return text
    }

    func cancel() {
        cancelCount += 1
    }
}

final class AssistantEngineTests: XCTestCase {
    private var settings: AssistantSettings!
    private var voice: RecordingVoice!
    private var listener: FakeListener!
    private var navigated: [String] = []
    private var searched: [String] = []

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults(suiteName: "CarMirrorTests.assistant.\(UUID().uuidString)")!
        settings = AssistantSettings(defaults: defaults, secrets: InMemorySecretStore())
        settings.anthropicAPIKey = "sk-test"
        voice = RecordingVoice()
        listener = FakeListener()
        navigated = []
        searched = []
    }

    private func makeEngine(brain: AssistantBrain?, navigation: NavigationEngine? = nil) -> AssistantEngine {
        let voice = self.voice!
        let navigation = navigation ?? NavigationEngine(location: FakeLocationSource(authorized: false), router: FakeRouter())
        let engine = AssistantEngine(
            settings: settings,
            listener: listener,
            navigation: navigation,
            brainFactory: { _ in brain },
            voiceFactory: { _ in voice }
        )
        engine.isSilent = false
        engine.activatesAudioSession = false
        engine.isDemoMode = true
        engine.navigationHandler = { [weak self] destination in self?.navigated.append(destination) }
        engine.placesHandler = { [weak self] query in self?.searched.append(query) }
        return engine
    }

    func testTypedMessageIsAnsweredSentenceBySentence() {
        let brain = ScriptedBrain(rounds: [ScriptedBrain.textRound(["Elbette efendim. ", "Kadıköy'e doğru ", "yola çıkıyoruz!"])])
        let engine = makeEngine(brain: brain)

        engine.submit(text: "Merhaba")
        waitUntil(timeout: 5, message: "cevap konuşulmadı: \(voice.spoken)") {
            self.voice.spoken.count == 2 && engine.state == .idle
        }

        XCTAssertEqual(voice.spoken, ["Elbette efendim.", "Kadıköy'e doğru yola çıkıyoruz!"])
        XCTAssertEqual(engine.entries.map(\.text), ["Merhaba", "Elbette efendim. Kadıköy'e doğru yola çıkıyoruz!"])
        XCTAssertEqual(engine.reply, "Elbette efendim. Kadıköy'e doğru yola çıkıyoruz!")

        XCTAssertEqual(engine.conversation.count, 2)
        XCTAssertEqual(engine.conversation[0].role, "user")
        XCTAssertTrue(engine.conversation[0].text.hasPrefix("(Zaman: "))
        XCTAssertTrue(engine.conversation[0].text.hasSuffix("Merhaba"))
        XCTAssertEqual(engine.conversation[1].role, "assistant")
        XCTAssertEqual(brain.requests.count, 1)
        XCTAssertTrue(brain.systems[0].contains("Alfred"))
    }

    func testNavigationToolCallOpensMapsAndFinishesTheTurn() {
        let toolCall = ClaudeToolCall(id: "toolu_1", name: AssistantTools.startNavigation, inputJSON: #"{"destination": "Kadıköy"}"#)
        let firstRound: [ClaudeStreamEvent] = [
            .toolCall(toolCall),
            .done(ClaudeTurn(
                blocks: [["type": "tool_use", "id": "toolu_1", "name": AssistantTools.startNavigation, "input": ["destination": "Kadıköy"]]],
                stopReason: "tool_use",
                text: ""
            )),
        ]
        let brain = ScriptedBrain(rounds: [firstRound, ScriptedBrain.textRound(["Kadıköy'e rota çizildi efendim."])])
        let engine = makeEngine(brain: brain)

        engine.submit(text: "Kadıköy'e gidelim")
        waitUntil(timeout: 5, message: "tur bitmedi") { engine.state == .idle && !self.voice.spoken.isEmpty }

        XCTAssertEqual(navigated, ["Kadıköy"])
        XCTAssertEqual(voice.spoken, ["Kadıköy'e rota çizildi efendim."])
        XCTAssertEqual(brain.requests.count, 2)
        let secondRequest = brain.requests[1]
        XCTAssertEqual(secondRequest.count, 3)
        XCTAssertEqual(secondRequest[1].role, "assistant")
        XCTAssertEqual(secondRequest[2].role, "user")
        XCTAssertEqual(secondRequest[2].content.first?["type"] as? String, "tool_result")
        XCTAssertEqual(secondRequest[2].content.first?["tool_use_id"] as? String, "toolu_1")
        XCTAssertEqual(engine.conversation.count, 4)
    }

    func testNavigationToolStartsInAppRouteWhenLocationIsAvailable() {
        let toolCall = ClaudeToolCall(id: "toolu_2", name: AssistantTools.startNavigation, inputJSON: #"{"destination": "Test Hedefi"}"#)
        let firstRound: [ClaudeStreamEvent] = [
            .toolCall(toolCall),
            .done(ClaudeTurn(
                blocks: [["type": "tool_use", "id": "toolu_2", "name": AssistantTools.startNavigation, "input": ["destination": "Test Hedefi"]]],
                stopReason: "tool_use",
                text: ""
            )),
        ]
        let brain = ScriptedBrain(rounds: [firstRound, ScriptedBrain.textRound(["Rota hazır efendim."])])
        let router = FakeRouter()
        router.places = [TestRoute.place]
        router.plan = TestRoute.plan()
        let navigation = NavigationEngine(location: FakeLocationSource(authorized: true, latest: TestRoute.origin), router: router)
        let engine = makeEngine(brain: brain, navigation: navigation)

        engine.submit(text: "Test hedefine yol tarifi al")
        waitUntil(timeout: 5, message: "tur bitmedi") { engine.state == .idle && !self.voice.spoken.isEmpty }

        XCTAssertTrue(navigated.isEmpty, "Konum varken Apple Haritalar'a düşülmemeli")
        XCTAssertEqual(navigation.state, .navigating)
        let toolResult = brain.requests[1][2].content.first?["content"] as? String
        XCTAssertTrue(toolResult?.contains("Navigasyon başladı") == true, toolResult ?? "")
        XCTAssertTrue(toolResult?.contains("800 metre") == true, toolResult ?? "")
        // İlk manevra duyurusu asistanın cevabından önce okunur.
        XCTAssertTrue(voice.spoken.contains("Şimdi: Turn right onto Test Street"), "\(voice.spoken)")
        XCTAssertEqual(voice.spoken.last, "Rota hazır efendim.")
    }

    func testTripStatusAndStopTools() {
        let statusCall = ClaudeToolCall(id: "toolu_3", name: AssistantTools.tripStatus, inputJSON: "{}")
        let stopCall = ClaudeToolCall(id: "toolu_4", name: AssistantTools.stopNavigation, inputJSON: "{}")
        let round: [ClaudeStreamEvent] = [
            .toolCall(statusCall),
            .toolCall(stopCall),
            .done(ClaudeTurn(
                blocks: [
                    ["type": "tool_use", "id": "toolu_3", "name": AssistantTools.tripStatus, "input": [String: Any]()],
                    ["type": "tool_use", "id": "toolu_4", "name": AssistantTools.stopNavigation, "input": [String: Any]()],
                ],
                stopReason: "tool_use",
                text: ""
            )),
        ]
        let brain = ScriptedBrain(rounds: [round, ScriptedBrain.textRound(["Aktif rota yok efendim."])])
        let engine = makeEngine(brain: brain)
        engine.submit(text: "Ne zaman varırız?")
        waitUntil(timeout: 5, message: "tur bitmedi") { engine.state == .idle && !self.voice.spoken.isEmpty }

        let results = brain.requests[1][2].content
        XCTAssertEqual(results.count, 2, "İki araç sonucu tek kullanıcı mesajında dönmeli")
        XCTAssertEqual(results[0]["content"] as? String, "Aktif navigasyon yok.")
        XCTAssertEqual(results[1]["content"] as? String, "Zaten aktif navigasyon yoktu.")
    }

    func testMissingAPIKeyIsExplained() {
        settings.anthropicAPIKey = ""
        let engine = makeEngine(brain: nil)
        engine.submit(text: "Selam")
        waitUntil(timeout: 5, message: "uyarı konuşulmadı") { engine.state == .idle && !self.voice.spoken.isEmpty }
        XCTAssertTrue(voice.spoken.first?.contains("API anahtarım yok") == true)
    }

    func testRefusalIsAnnounced() {
        let brain = ScriptedBrain(rounds: [[.done(ClaudeTurn(blocks: [], stopReason: "refusal", text: ""))]])
        let engine = makeEngine(brain: brain)
        engine.submit(text: "...")
        waitUntil(timeout: 5, message: "ret cümlesi konuşulmadı") { engine.state == .idle && !self.voice.spoken.isEmpty }
        XCTAssertTrue(voice.spoken.first?.contains("yardımcı olamıyorum") == true)
    }

    func testGreetsOnAppearThenListensAndResponds() {
        let brain = ScriptedBrain(rounds: [ScriptedBrain.textRound(["Gayet iyiyim efendim, teşekkür ederim."])])
        listener.transcripts = ["Nasılsın?"]
        let engine = makeEngine(brain: brain)
        engine.isDemoMode = false

        engine.surfaceDidAppear(.phone)
        XCTAssertEqual(engine.state, .greeting)
        waitUntil(timeout: 5, message: "karşılama ve cevap tamamlanmadı: \(voice.spoken)") {
            self.voice.spoken.count == 2 && engine.state == .idle
        }

        XCTAssertTrue(voice.spoken[0].lowercased().contains("efendim"), "Karşılama hitap içermeli: \(voice.spoken[0])")
        XCTAssertEqual(voice.spoken[1], "Gayet iyiyim efendim, teşekkür ederim.")
        XCTAssertEqual(engine.entries.map(\.role), [.assistant, .user, .assistant])
        XCTAssertEqual(engine.entries[1].text, "Nasılsın?")
        XCTAssertEqual(listener.listenCount, 2, "Cevaptan sonra bir kez daha dinlenmeli; sessizlikte durmalı")
        XCTAssertEqual(engine.isAuthorized, true)
    }

    func testDeniedPermissionShowsHint() {
        listener.authorized = false
        let engine = makeEngine(brain: ScriptedBrain(rounds: []))
        engine.isDemoMode = false
        engine.startListening()
        waitUntil(timeout: 5, message: "izin uyarısı gelmedi") { engine.statusMessage != nil && engine.state == .idle }
        XCTAssertTrue(engine.statusMessage?.contains("izin") == true)
        XCTAssertEqual(engine.isAuthorized, false)
    }

    func testInterruptStopsEverything() {
        let brain = ScriptedBrain(rounds: [ScriptedBrain.textRound(["Bir. ", "İki. ", "Üç."])])
        let engine = makeEngine(brain: brain)
        engine.submit(text: "Say")
        engine.interrupt()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertGreaterThan(listener.cancelCount, 0)
        spinRunLoop(for: 0.3)
        XCTAssertEqual(engine.state, .idle)
    }

    func testResetClearsConversation() {
        let brain = ScriptedBrain(rounds: [ScriptedBrain.textRound(["Tamam."])])
        let engine = makeEngine(brain: brain)
        engine.submit(text: "Selam")
        waitUntil(timeout: 5, message: "cevap gelmedi") { engine.state == .idle && !self.voice.spoken.isEmpty }
        engine.reset()
        XCTAssertTrue(engine.conversation.isEmpty)
        XCTAssertTrue(engine.entries.isEmpty)
        XCTAssertEqual(engine.reply, "")
    }
}
