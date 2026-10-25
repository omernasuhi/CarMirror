import CoreMedia
import ImageIO
import QuartzCore
import ReplayKit

/// "Start Broadcast"a dokunulduğunda sistemin başlattığı yayın eklentisi.
/// Ekran karelerini H.264 ile kodlayıp App Group soketi üzerinden ana
/// uygulamaya gönderir; uygulama da onları CarPlay ekranında gösterir.
///
/// Eklentinin bellek sınırı yaklaşık 50 MB'tır. Bu yüzden kareler burada
/// biriktirilmez: uygulamaya bağlantı yoksa kodlanmadan atlanır.
final class SampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "carmirror.broadcast")
    private let client = MirrorClient()
    private var quality = MirrorQuality.balanced
    private var encoder: H264Encoder?

    // Kare hızı sınırlaması. Ekran durağanlaşınca ReplayKit yeni kare
    // göndermez; atlanan son kare de kaybolmasın diye kısa süre sonra kodlanır.
    private var lastEncodeTime: CFTimeInterval = 0
    private var pendingSample: CMSampleBuffer?
    private var pendingFlush: DispatchWorkItem?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        quality = MirrorSettings.quality
        client.onKeyFrameRequest = { [weak self] in
            self?.queue.async { [weak self] in self?.encoder?.forceNextKeyFrame() }
        }
        client.start()
    }

    override func broadcastResumed() {
        queue.async { self.encoder?.forceNextKeyFrame() }
    }

    override func broadcastFinished() {
        client.stop()
        queue.sync {
            pendingFlush?.cancel()
            pendingFlush = nil
            pendingSample = nil
            encoder?.invalidate()
            encoder = nil
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        // Ses, CarPlay bağlıyken zaten aracın hoparlörlerinden çalar; yalnızca görüntü aktarılır.
        guard sampleBufferType == .video, client.isConnected else { return }
        queue.async { self.throttle(sampleBuffer) }
    }

    private func throttle(_ sampleBuffer: CMSampleBuffer) {
        let interval = 1.0 / Double(quality.framesPerSecond)
        let wait = interval - (CACurrentMediaTime() - lastEncodeTime)
        guard wait > 0.002 else {
            pendingFlush?.cancel()
            pendingFlush = nil
            pendingSample = nil
            encode(sampleBuffer)
            return
        }

        pendingSample = sampleBuffer
        guard pendingFlush == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFlush = nil
            if let sample = self.pendingSample {
                self.pendingSample = nil
                self.encode(sample)
            }
        }
        pendingFlush = work
        queue.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastEncodeTime = CACurrentMediaTime()

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if let current = encoder, current.sourceWidth != width || current.sourceHeight != height {
            current.invalidate()
            encoder = nil
        }
        if encoder == nil {
            encoder = H264Encoder(sourceWidth: width, sourceHeight: height, quality: quality) { [weak self] packet in
                self?.client.send(packet)
            }
        }

        let orientationNumber = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber
        let orientation = orientationNumber?.uint8Value ?? UInt8(CGImagePropertyOrientation.up.rawValue)

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if encoder?.encode(pixelBuffer, presentationTime: presentationTime, orientation: orientation) == false {
            // Oturum geçersizleşti (ör. sistem kodlayıcıyı geri aldı); bir sonraki karede yeniden oluşturulur.
            encoder?.invalidate()
            encoder = nil
        }
    }
}
