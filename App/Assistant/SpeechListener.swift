import AVFoundation
import Foundation
import Speech

/// Kullanıcının söylediklerini yazıya çeviren kaynak.
protocol SpeechInput: AnyObject {
    /// Mikrofon seviyesi (0...1); ana kuyrukta çağrılır.
    var onLevel: ((Float) -> Void)? { get set }
    /// Konuşma devam ederken ara sonuçlar; ana kuyrukta çağrılır.
    var onPartial: ((String) -> Void)? { get set }
    func requestAuthorization() async -> Bool
    /// Kullanıcı susana kadar dinler ve metni döndürür; hiçbir şey
    /// söylenmediyse boş metin döner. `cancel` çağrılırsa `CancellationError` fırlatır.
    func listen(silenceTimeout: TimeInterval, maxDuration: TimeInterval) async throws -> String
    func cancel()
}

enum SpeechError: LocalizedError {
    case unavailable
    case noInput

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Konuşma tanıma şu anda kullanılamıyor."
        case .noInput: return "Mikrofon bulunamadı."
        }
    }
}

/// Apple'ın konuşma tanıma servisiyle (SFSpeechRecognizer) dinler.
/// Konuşma bittikten `silenceTimeout` kadar sonra sonucu verir.
final class SpeechListener: NSObject, SpeechInput {
    var onLevel: ((Float) -> Void)?
    var onPartial: ((String) -> Void)?

    /// Hiç konuşma algılanmazsa bu süre sonunda boş sonuçla biter.
    var initialSilenceTimeout: TimeInterval = 7

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var monitor: Task<Void, Never>?

    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var latestTranscript = ""
    private var lastChange = Date()

    init(localeIdentifier: String = "tr-TR") {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) ?? SFSpeechRecognizer()
        super.init()
    }

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    func requestAuthorization() async -> Bool {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechStatus == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func listen(silenceTimeout: TimeInterval, maxDuration: TimeInterval) async throws -> String {
        guard let recognizer, recognizer.isAvailable else { throw SpeechError.unavailable }
        cancel()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            latestTranscript = ""
            lastChange = Date()
            lock.unlock()
            do {
                try start(recognizer: recognizer, silenceTimeout: silenceTimeout, maxDuration: maxDuration)
            } catch {
                finish(.failure(error))
            }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    // MARK: - İç işleyiş

    private func start(recognizer: SFSpeechRecognizer, silenceTimeout: TimeInterval, maxDuration: TimeInterval) throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if #available(iOS 16, *) {
            request.addsPunctuation = true
        }
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError.noInput }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            let level = Self.level(of: buffer)
            DispatchQueue.main.async { self.onLevel?(level) }
        }
        audioEngine.prepare()
        try audioEngine.start()

        let startDate = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.lock.lock()
                let changed = text != self.latestTranscript
                if changed {
                    self.latestTranscript = text
                    self.lastChange = Date()
                }
                self.lock.unlock()
                if changed {
                    DispatchQueue.main.async { self.onPartial?(text) }
                }
                if result.isFinal {
                    self.finish(.success(text))
                    return
                }
            }
            if error != nil {
                // Sesi biz kestiğimizde de hata gelir; elimizdeki metinle bitir.
                self.finish(.success(self.currentTranscript))
            }
        }

        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, !Task.isCancelled else { return }
                let now = Date()
                self.lock.lock()
                let transcript = self.latestTranscript
                let sinceChange = now.timeIntervalSince(self.lastChange)
                self.lock.unlock()
                let elapsed = now.timeIntervalSince(startDate)
                if !transcript.isEmpty, sinceChange >= silenceTimeout {
                    self.finish(.success(transcript))
                    return
                }
                if elapsed >= maxDuration || (transcript.isEmpty && elapsed >= self.initialSilenceTimeout) {
                    self.finish(.success(transcript))
                    return
                }
            }
        }
    }

    private var currentTranscript: String {
        lock.lock()
        defer { lock.unlock() }
        return latestTranscript
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        teardown()
        guard let pending else { return }
        switch result {
        case let .success(text):
            pending.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
        case let .failure(error):
            pending.resume(throwing: error)
        }
    }

    private func teardown() {
        monitor?.cancel()
        monitor = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }

    /// Tamponun ses seviyesi (0...1), yaklaşık -50 dB ... 0 dB aralığından.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(count))
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 50) / 50))
    }
}

/// Ses oturumu: hem dinleme hem konuşma; CarPlay bağlıyken araç hoparlörü.
enum AudioSessionController {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            NSLog("CarMirror: ses oturumu ayarlanamadı: \(error.localizedDescription)")
        }
    }
}
