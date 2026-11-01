import Foundation

/// Claude Messages API'sine gönderilen bir mesaj. İçerik, API'nin blok
/// biçimindedir (text, tool_use, tool_result, thinking ...).
struct ClaudeMessage {
    var role: String
    var content: [[String: Any]]

    static func user(text: String) -> ClaudeMessage {
        ClaudeMessage(role: "user", content: [["type": "text", "text": text]])
    }

    static func toolResults(_ results: [(toolUseID: String, content: String)]) -> ClaudeMessage {
        ClaudeMessage(role: "user", content: results.map { result in
            ["type": "tool_result", "tool_use_id": result.toolUseID, "content": result.content]
        })
    }

    var text: String {
        content.compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined()
    }
}

struct ClaudeToolCall: Equatable {
    var id: String
    var name: String
    var inputJSON: String

    var input: [String: Any] {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}

/// Modelin bir dönüşte ürettiği her şey: geçmişe eklenecek bloklar ve bitiş nedeni.
struct ClaudeTurn {
    var blocks: [[String: Any]]
    var stopReason: String?
    var text: String

    var assistantMessage: ClaudeMessage {
        ClaudeMessage(role: "assistant", content: blocks)
    }
}

enum ClaudeStreamEvent {
    case text(String)
    case toolCall(ClaudeToolCall)
    case done(ClaudeTurn)
    case failure(String)
}

enum ClaudeError: LocalizedError {
    case http(status: Int, message: String)
    case stream(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .http(status, message):
            switch status {
            case 401, 403: return "API anahtarı geçersiz görünüyor."
            case 429: return "Çok fazla istek gönderildi; biraz sonra tekrar deneyin."
            case 529, 503: return "Yapay zekâ sunucusu şu anda çok yoğun."
            default: return "Sunucu hatası (\(status)): \(message)"
            }
        case let .stream(message): return message
        case .invalidResponse: return "Sunucudan beklenmeyen bir yanıt geldi."
        }
    }
}

/// Sunucudan gelen SSE satırlarını olaylara çevirir. Blokları olduğu gibi
/// biriktirir; böylece thinking blokları (imzalarıyla) ve fallback blokları
/// bir sonraki isteğe değiştirilmeden geri gönderilebilir.
final class ClaudeStreamParser {
    private var blocks: [Int: [String: Any]] = [:]
    private var partialJSON: [Int: String] = [:]
    private var stopReason: String?
    private var text = ""

    func feed(line: String) -> [ClaudeStreamEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return [] }
        return handle(type: type, json: json)
    }

    private func handle(type: String, json: [String: Any]) -> [ClaudeStreamEvent] {
        switch type {
        case "content_block_start":
            guard let index = json["index"] as? Int, let block = json["content_block"] as? [String: Any] else { return [] }
            blocks[index] = block
            if block["type"] as? String == "tool_use" { partialJSON[index] = "" }
            return []

        case "content_block_delta":
            guard let index = json["index"] as? Int, let delta = json["delta"] as? [String: Any],
                  var block = blocks[index] else { return [] }
            defer { blocks[index] = block }
            switch delta["type"] as? String {
            case "text_delta":
                let piece = delta["text"] as? String ?? ""
                block["text"] = (block["text"] as? String ?? "") + piece
                text += piece
                return piece.isEmpty ? [] : [.text(piece)]
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
            case "thinking_delta":
                block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
            case "signature_delta":
                block["signature"] = (block["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
            default:
                break
            }
            return []

        case "content_block_stop":
            guard let index = json["index"] as? Int, var block = blocks[index] else { return [] }
            guard block["type"] as? String == "tool_use" else { return [] }
            var inputJSON = partialJSON[index] ?? ""
            if inputJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { inputJSON = "{}" }
            if let data = inputJSON.data(using: .utf8),
               let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                block["input"] = input
            }
            blocks[index] = block
            let call = ClaudeToolCall(
                id: block["id"] as? String ?? "",
                name: block["name"] as? String ?? "",
                inputJSON: inputJSON
            )
            return [.toolCall(call)]

        case "message_delta":
            if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                stopReason = reason
            }
            return []

        case "message_stop":
            let ordered = blocks.keys.sorted().compactMap { blocks[$0] }
            return [.done(ClaudeTurn(blocks: ordered, stopReason: stopReason, text: text))]

        case "error":
            let error = json["error"] as? [String: Any]
            return [.failure(error?["message"] as? String ?? "Bilinmeyen akış hatası")]

        default:
            return []
        }
    }
}

/// Asistanın "beyni": mesaj geçmişini alır, olay akışı döndürür.
protocol AssistantBrain {
    func stream(system: String, messages: [ClaudeMessage], tools: [[String: Any]]) -> AsyncThrowingStream<ClaudeStreamEvent, Error>
}

/// Claude Messages API istemcisi (ham HTTP, akışlı).
final class ClaudeClient: AssistantBrain {
    static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    private let apiKey: String
    private let model: AssistantModel
    private let session: URLSession
    private let endpoint: URL
    private let maxTokens: Int

    init(apiKey: String, model: AssistantModel, session: URLSession = .shared, endpoint: URL = ClaudeClient.defaultEndpoint, maxTokens: Int = 8192) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.endpoint = endpoint
        self.maxTokens = maxTokens
    }

    func makeRequest(system: String, messages: [ClaudeMessage], tools: [[String: Any]]) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            // Sesli sohbet: hız öncelikli; düşünme derinliği düşük.
            "output_config": ["effort": "low"],
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        if !tools.isEmpty {
            body["tools"] = tools
        }
        if model.supportsServerFallback {
            body["fallbacks"] = "default"
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if model.supportsServerFallback {
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func stream(system: String, messages: [ClaudeMessage], tools: [[String: Any]]) -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(system: system, messages: messages, tools: tools)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ClaudeError.invalidResponse }
                    if http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 4000 { break }
                        }
                        throw ClaudeError.http(status: http.statusCode, message: Self.errorMessage(from: body))
                    }
                    let parser = ClaudeStreamParser()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for event in parser.feed(line: line) {
                            if case let .failure(message) = event {
                                throw ClaudeError.stream(message)
                            }
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func errorMessage(from body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return body }
        return message
    }
}

/// Asistanın kullanabildiği araçlar.
enum AssistantTools {
    static let startNavigation = "start_navigation"
    static let searchPlaces = "search_places"
    static let stopNavigation = "stop_navigation"
    static let tripStatus = "trip_status"

    static let definitions: [[String: Any]] = [
        [
            "name": startNavigation,
            "description": "Verilen hedefe araçla navigasyon başlatır: rota araç (CarPlay) ekranında haritada gösterilir, dönüşler sesli okunur. Kullanıcı bir yere gitmek istediğinde ya da aramadaki bir yeri seçtiğinde kullan. Sonuç mesafe ve süreyi içerir; onay cümlende bunları söyle.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "destination": [
                        "type": "string",
                        "description": "Gidilecek yer: adres, semt, şehir veya işletme adı",
                    ],
                ],
                "required": ["destination"],
                "additionalProperties": false,
            ],
            "strict": true,
        ],
        [
            "name": searchPlaces,
            "description": "Yakındaki yerleri arar (benzin istasyonu, kahveci, eczane, otopark gibi) ve en yakın birkaçını mesafeleriyle döndürür. Sonuçları kısaca numaralı oku; kullanıcı birini seçerse start_navigation'ı o yerin adıyla çağır.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Aranacak yer türü veya adı",
                    ],
                ],
                "required": ["query"],
                "additionalProperties": false,
            ],
            "strict": true,
        ],
        [
            "name": stopNavigation,
            "description": "Aktif navigasyonu durdurur. Kullanıcı rotayı iptal etmek istediğinde kullan.",
            "input_schema": [
                "type": "object",
                "properties": [String: Any](),
                "additionalProperties": false,
            ],
            "strict": true,
        ],
        [
            "name": tripStatus,
            "description": "Aktif navigasyonun durumunu verir: kalan mesafe, kalan süre, varış saati ve sıradaki manevra. \"Ne zaman varırız\", \"ne kadar kaldı\" gibi sorularda kullan.",
            "input_schema": [
                "type": "object",
                "properties": [String: Any](),
                "additionalProperties": false,
            ],
            "strict": true,
        ],
    ]
}
