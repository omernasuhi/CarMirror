import CoreMedia
import CoreVideo
import ImageIO
import QuartzCore
import UIKit

/// Uygulamanın kendi ekranını yakalayıp CarPlay'e yansıtır.
///
/// iOS simülatöründe ReplayKit ekran yayını çalışmadığı için CarPlay
/// simülatöründe denemenin yolu budur; gerçek cihazda da kullanılabilir.
/// Kareler, tüm ekran yayınıyla aynı H.264 kodlayıcıdan ve CarPlay
/// gösterim hattından geçer. Yalnızca ana iş parçacığından kullanılır.
final class InAppMirror: NSObject {
    static let shared = InAppMirror()

    /// CarPlay bağlıyken telefon ekranı açılınca yansıtma kendiliğinden başlasın.
    var autoStartWhenPossible = false

    private(set) var isRunning = false

    private let framesPerSecond: Double = 24
    /// Yakalanan görüntünün uzun kenarı (piksel).
    private let maxLongSide: CGFloat = 1280

    private weak var window: UIWindow?
    private var displayLink: CADisplayLink?
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var framesInFlight = 0
    private var startTime: CFTimeInterval = 0
    private var lastCaptureTime: CFTimeInterval = 0

    // Yalnızca `encodeQueue` üzerinde kullanılır.
    private let encodeQueue = DispatchQueue(label: "carmirror.inapp")
    private var encoder: H264Encoder?
    private var framesSubmittedToEncoder = 0
    private var encoderHasWorked = false
    private var usesRawFrames = false

    /// Telefon ekranının (CarPlay olmayan sahnenin) penceresi.
    static var phoneWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.session.role == .windowApplication }) else { return nil }
        return scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
    }

    func startOnPhoneWindow() {
        guard let window = Self.phoneWindow else { return }
        start(window: window)
    }

    func start(window: UIWindow) {
        guard !isRunning else { return }
        isRunning = true
        self.window = window
        startTime = CACurrentMediaTime()
        lastCaptureTime = 0
        framesInFlight = 0

        MirrorReceiver.shared.beginLocalStream { [weak self] in
            self?.encodeQueue.async { [weak self] in self?.encoder?.forceNextKeyFrame() }
        }

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(framesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        displayLink = link
        MirrorState.shared.update(inAppMirroring: true)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        displayLink?.invalidate()
        displayLink = nil
        window = nil
        MirrorReceiver.shared.endLocalStream()
        encodeQueue.async {
            self.encoder?.invalidate()
            self.encoder = nil
            self.framesSubmittedToEncoder = 0
            self.encoderHasWorked = false
            self.usesRawFrames = false
        }
        MirrorState.shared.update(inAppMirroring: false)
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard isRunning, let window, framesInFlight < 2 else { return }
        let now = link.timestamp
        guard now - lastCaptureTime >= 1 / framesPerSecond - 0.005 else { return }
        lastCaptureTime = now

        guard let pixelBuffer = capture(window) else { return }
        let time = CMTime(seconds: now - startTime, preferredTimescale: 600)
        framesInFlight += 1
        encodeQueue.async {
            self.process(pixelBuffer, presentationTime: time)
            DispatchQueue.main.async { self.framesInFlight -= 1 }
        }
    }

    // MARK: - Yakalama

    private func capture(_ window: UIWindow) -> CVPixelBuffer? {
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(window.traitCollection.displayScale, maxLongSide / max(bounds.width, bounds.height))
        let width = Int(bounds.width * scale) / 2 * 2
        let height = Int(bounds.height * scale) / 2 * 2
        guard width > 0, height > 0, let pixelBuffer = makePixelBuffer(width: width, height: height) else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // UIKit yukarıdan aşağı çizer; Core Graphics bağlamını buna göre çevir.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / bounds.width, y: -CGFloat(height) / bounds.height)
        UIGraphicsPushContext(context)
        _ = window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        UIGraphicsPopContext()
        return pixelBuffer
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolWidth != width || poolHeight != height {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolWidth = width
            poolHeight = height
        }
        guard let pool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        return pixelBuffer
    }

    // MARK: - Kodlama (encodeQueue)

    private func process(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let orientation = CGImagePropertyOrientation.up
        if !usesRawFrames {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            if let current = encoder, current.sourceWidth != width || current.sourceHeight != height {
                current.invalidate()
                encoder = nil
            }
            if encoder == nil {
                encoder = H264Encoder(sourceWidth: width, sourceHeight: height, quality: .balanced) { packet in
                    MirrorReceiver.shared.submitLocal(packet)
                }
            }
            framesSubmittedToEncoder += 1
            if encoder?.encode(pixelBuffer, presentationTime: presentationTime, orientation: UInt8(orientation.rawValue)) != true {
                // Oturum geçersizleşti; bir sonraki karede yeniden oluşturulur.
                encoder?.invalidate()
                encoder = nil
            }
            if !encoderHasWorked, (encoder?.emittedFrameCount ?? 0) > 0 {
                encoderHasWorked = true
            }
            // Bu ortamda H.264 kodlayıcı hiç kare üretmiyorsa kareleri sıkıştırmadan gönder.
            if !encoderHasWorked && framesSubmittedToEncoder >= 30 {
                NSLog("CarMirror: H.264 kodlayıcı kare üretmiyor; sıkıştırılmamış karelere geçiliyor.")
                encoder?.invalidate()
                encoder = nil
                usesRawFrames = true
            }
        }
        if usesRawFrames,
           let sampleBuffer = MirrorSampleBuffers.makeSampleBuffer(pixelBuffer: pixelBuffer, presentationTime: presentationTime) {
            MirrorReceiver.shared.submitLocalRaw(sampleBuffer, orientation: orientation)
        }
    }
}
