import AVFoundation
import Foundation

/// Metni sese çeviren kaynak. `speak`, cümle bitince döner.
protocol VoiceOutput: AnyObject {
    /// Çıkış ses seviyesi (0...1); ana kuyrukta çağrılır. Her sağlayıcı vermez.
    var onLevel: ((Float) -> Void)? { get set }
    func speak(_ text: String) async throws
    /// Bir sonraki cümleyi şimdiden hazırlamaya başlar (isteğe bağlı).
    func prefetch(_ text: String)
    /// Konuşmayı hemen keser; bekleyen `speak` çağrısı döner.
    func stop()
}

extension VoiceOutput {
    func prefetch(_ text: String) {}
}

enum VoiceError: LocalizedError {
    case http(status: Int, message: String)
    case playback

    var errorDescription: String? {
        switch self {
        case let .http(status, message):
            switch status {
            case 401: return "ElevenLabs API anahtarı geçersiz."
            case 404: return "ElevenLabs ses kimliği bulunamadı."
            case 429: return "ElevenLabs kotası doldu veya çok fazla istek."
            default: return "ElevenLabs hatası (\(status)): \(message)"
            }
        case .playback: return "Ses çalınamadı."
        }
    }
}

// MARK: - Apple

/// Cihaz içi seslendirme (AVSpeechSynthesizer). Anahtar gerektirmez, çevrimdışı çalışır.
final class AppleVoice: NSObject, VoiceOutput, AVSpeechSynthesizerDelegate {
    var onLevel: ((Float) -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(language: String = "tr-TR") {
        voice = Self.bestVoice(for: language)
        super.init()
        synthesizer.delegate = self
    }

    /// Dildeki en kaliteli sesi seçer (premium > enhanced > varsayılan).
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(language.prefix(2)).lowercased()
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.lowercased().hasPrefix(prefix) }
        let best = candidates.max { lhs, rhs in
            if lhs.quality.rawValue != rhs.quality.rawValue { return lhs.quality.rawValue < rhs.quality.rawValue }
            return lhs.language == language ? false : rhs.language == language
        }
        return best ?? AVSpeechSynthesisVoice(language: language)
    }

    func speak(_ text: String) async throws {
        stop()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 0.95
            utterance.postUtteranceDelay = 0.05
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finish()
    }

    private func finish() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish()
    }
}

// MARK: - ElevenLabs

/// ElevenLabs ile doğal seslendirme. Her cümle ayrı istek olarak alınıp
/// AVAudioPlayer ile çalınır; sonraki cümle çalma sırasında önceden hazırlanır.
final class ElevenLabsVoice: NSObject, VoiceOutput, AVAudioPlayerDelegate {
    struct Voice: Identifiable, Equatable {
        var id: String
        var name: String
        var description: String
    }

    var onLevel: ((Float) -> Void)?

    private let apiKey: String
    private let voiceID: String
    private let modelID: String
    private let session: URLSession
    private var prefetched: [String: Task<Data, Error>] = [:]
    private var player: AVAudioPlayer?
    private var meter: Timer?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(apiKey: String, voiceID: String, modelID: String = "eleven_flash_v2_5", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.modelID = modelID
        self.session = session
        super.init()
    }

    func prefetch(_ text: String) {
        guard prefetched[text] == nil else { return }
        prefetched[text] = Task { try await self.synthesize(text) }
    }

    func speak(_ text: String) async throws {
        let task = prefetched.removeValue(forKey: text) ?? Task { try await self.synthesize(text) }
        let data = try await task.value
        try Task.checkCancellation()
        try await play(data)
    }

    func stop() {
        prefetched.values.forEach { $0.cancel() }
        prefetched.removeAll()
        player?.stop()
        player = nil
        finish()
    }

    func synthesize(_ text: String) async throws -> Data {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "text": text,
            "model_id": modelID,
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.8],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoiceError.playback }
        guard http.statusCode == 200 else {
            throw VoiceError.http(status: http.statusCode, message: String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        return data
    }

    /// Hesaptaki sesleri listeler (ayarlar ekranı için).
    static func listVoices(apiKey: String, session: URLSession = .shared) async throws -> [Voice] {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoiceError.playback }
        guard http.statusCode == 200 else {
            throw VoiceError.http(status: http.statusCode, message: String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voices = json["voices"] as? [[String: Any]] else { return [] }
        return voices.compactMap { voice in
            guard let id = voice["voice_id"] as? String, let name = voice["name"] as? String else { return nil }
            let labels = (voice["labels"] as? [String: Any])?.values.compactMap { $0 as? String }.joined(separator: ", ") ?? ""
            return Voice(id: id, name: name, description: labels)
        }
    }

    private func play(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                player.isMeteringEnabled = true
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                self.player = player
                player.prepareToPlay()
                guard player.play() else {
                    finish(error: VoiceError.playback)
                    return
                }
                startMetering(player)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func startMetering(_ player: AVAudioPlayer) {
        meter?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak player] _ in
            guard let self, let player, player.isPlaying else { return }
            player.updateMeters()
            let power = player.averagePower(forChannel: 0)
            let level = min(1, max(0, (power + 45) / 45))
            self.onLevel?(level)
        }
        RunLoop.main.add(timer, forMode: .common)
        meter = timer
    }

    private func finish(error: Error? = nil) {
        meter?.invalidate()
        meter = nil
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        DispatchQueue.main.async { self.onLevel?(0) }
        if let error {
            pending?.resume(throwing: error)
        } else {
            pending?.resume()
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finish(error: error ?? VoiceError.playback)
    }
}

// MARK: - Sıra

/// Cümleleri sırayla okur; akıştan gelen cümleler kuyruğa eklenir.
/// Ana iş parçacığından kullanılır.
final class SpeechQueue {
    var voice: VoiceOutput
    /// Okuma başladığında (true) ve kuyruk boşalıp sustuğunda (false) çağrılır.
    var onSpeakingChange: ((Bool) -> Void)?

    private var pending: [String] = []
    private var isSpeaking = false
    private var generation = 0

    init(voice: VoiceOutput) {
        self.voice = voice
    }

    var isIdle: Bool { !isSpeaking && pending.isEmpty }

    func enqueue(_ sentence: String) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pending.append(trimmed)
        pump()
    }

    func cancel() {
        generation += 1
        pending.removeAll()
        voice.stop()
        if isSpeaking {
            isSpeaking = false
            onSpeakingChange?(false)
        }
    }

    @MainActor
    func waitUntilIdle() async {
        while !isIdle {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    private func pump() {
        guard !isSpeaking, !pending.isEmpty else { return }
        let sentence = pending.removeFirst()
        if let next = pending.first {
            voice.prefetch(next)
        }
        isSpeaking = true
        onSpeakingChange?(true)
        let generation = self.generation
        let voice = self.voice
        Task { @MainActor [weak self] in
            do {
                try await voice.speak(sentence)
            } catch {
                NSLog("CarMirror: seslendirme hatası: \(error.localizedDescription)")
            }
            guard let self, generation == self.generation else { return }
            self.isSpeaking = false
            if self.pending.isEmpty {
                self.onSpeakingChange?(false)
            } else {
                self.pump()
            }
        }
    }
}
