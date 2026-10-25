import AVFoundation
import ImageIO
import UIKit

final class MirrorDisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// Alınan kareleri bir `AVSampleBufferDisplayLayer`'a yazar.
/// `MirrorFrameSink` yöntemleri alıcının kuyruğunda çağrılır; arayüz
/// bildirimleri ana kuyrukta yapılır.
final class DisplayLayerSink: MirrorFrameSink {
    /// Ana kuyrukta çağrılır: görüntü gelmeye başladı (true) ya da kesildi (false).
    var onStreamActiveChange: ((Bool) -> Void)?
    /// Ana kuyrukta çağrılır.
    var onOrientationChange: ((CGImagePropertyOrientation) -> Void)?

    /// `AVSampleBufferVideoRenderer` iş parçacığı güvenlidir.
    let renderer: AVSampleBufferVideoRenderer

    private let lock = NSLock()
    private var isStreamActive = false
    private var enqueued = 0

    var enqueuedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return enqueued
    }

    init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) -> Bool {
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            if !isKeyFrame { return false }
        }
        renderer.enqueue(sampleBuffer)

        lock.lock()
        enqueued += 1
        let becameActive = !isStreamActive
        isStreamActive = true
        lock.unlock()

        if becameActive {
            DispatchQueue.main.async { self.onStreamActiveChange?(true) }
        }
        return true
    }

    func orientationDidChange(_ orientation: CGImagePropertyOrientation) {
        DispatchQueue.main.async { self.onOrientationChange?(orientation) }
    }

    func streamDidStop() {
        lock.lock()
        isStreamActive = false
        lock.unlock()
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        DispatchQueue.main.async { self.onStreamActiveChange?(false) }
    }
}
