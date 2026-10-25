import CoreMedia
import CoreVideo
import ImageIO
import VideoToolbox
import XCTest
@testable import CarMirror

struct PixelColor: Equatable, CustomStringConvertible {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    static let testRed = PixelColor(red: 220, green: 40, blue: 40)
    static let testBlue = PixelColor(red: 30, green: 60, blue: 210)

    var description: String { "rgb(\(red), \(green), \(blue))" }

    func isClose(to other: PixelColor, tolerance: Int) -> Bool {
        abs(Int(red) - Int(other.red)) <= tolerance
            && abs(Int(green) - Int(other.green)) <= tolerance
            && abs(Int(blue) - Int(other.blue)) <= tolerance
    }
}

enum TestMediaError: Error {
    case encoderUnavailable
    case encodeFailed
    case missingFormat
    case decoderUnavailable(OSStatus)
    case decodeFailed(OSStatus, OSStatus)
}

enum TestMedia {
    /// Tek renkli BGRA görüntü.
    static func makePixelBuffer(width: Int, height: Int, color: PixelColor) -> CVPixelBuffer {
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
        precondition(status == kCVReturnSuccess && pixelBuffer != nil, "CVPixelBufferCreate: \(status)")
        let buffer = pixelBuffer!

        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for x in 0..<width {
            base[x * 4] = color.blue
            base[x * 4 + 1] = color.green
            base[x * 4 + 2] = color.red
            base[x * 4 + 3] = 255
        }
        for y in 1..<height {
            memcpy(base + y * bytesPerRow, base, width * 4)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Verilen sayıda kareyi kodlar ve üretilen paketleri döndürür.
    static func encode(
        frameCount: Int,
        width: Int,
        height: Int,
        color: PixelColor,
        orientation: CGImagePropertyOrientation = .up,
        quality: MirrorQuality = .balanced
    ) throws -> [VideoPacket] {
        let collector = PacketCollector()
        guard let encoder = H264Encoder(sourceWidth: width, sourceHeight: height, quality: quality, output: collector.append) else {
            throw TestMediaError.encoderUnavailable
        }
        let pixelBuffer = makePixelBuffer(width: width, height: height, color: color)
        for index in 0..<frameCount {
            let time = CMTime(value: CMTimeValue(index), timescale: 30)
            guard encoder.encode(pixelBuffer, presentationTime: time, orientation: UInt8(orientation.rawValue)) else {
                throw TestMediaError.encodeFailed
            }
        }
        encoder.flush()
        encoder.invalidate()
        return collector.packets
    }

    /// Sıkıştırılmış bir örneği VideoToolbox ile BGRA görüntüye çözer.
    static func decode(_ sampleBuffer: CMSampleBuffer) throws -> CVPixelBuffer {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { throw TestMediaError.missingFormat }
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        var session: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard createStatus == noErr, let session else { throw TestMediaError.decoderUnavailable(createStatus) }
        defer { VTDecompressionSessionInvalidate(session) }

        let result = DecodeResult()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { outputStatus, _, imageBuffer, _, _ in
            result.store(status: outputStatus, image: imageBuffer)
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        let output = result.load()
        guard status == noErr, output.status == noErr, let image = output.image else {
            throw TestMediaError.decodeFailed(status, output.status)
        }
        return image
    }

    /// BGRA görüntünün ortasındaki pikselin rengi.
    static func centerColor(of pixelBuffer: CVPixelBuffer) -> PixelColor {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let x = CVPixelBufferGetWidth(pixelBuffer) / 2
        let y = CVPixelBufferGetHeight(pixelBuffer) / 2
        let pixel = base + y * bytesPerRow + x * 4
        return PixelColor(red: pixel[2], green: pixel[1], blue: pixel[0])
    }

    static func dimensions(of sampleBuffer: CMSampleBuffer) -> CMVideoDimensions? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        return CMVideoFormatDescriptionGetDimensions(format)
    }
}

final class PacketCollector {
    private let lock = NSLock()
    private var storage: [VideoPacket] = []

    var packets: [VideoPacket] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ packet: VideoPacket) {
        lock.lock()
        storage.append(packet)
        lock.unlock()
    }
}

final class DecodeResult {
    private let lock = NSLock()
    private var status: OSStatus = noErr
    private var image: CVImageBuffer?

    func store(status: OSStatus, image: CVImageBuffer?) {
        lock.lock()
        self.status = status
        self.image = image
        lock.unlock()
    }

    func load() -> (status: OSStatus, image: CVImageBuffer?) {
        lock.lock()
        defer { lock.unlock() }
        return (status, image)
    }
}

/// Alıcının ilettiği kareleri biriktiren sahte gösterici.
final class CollectingSink: MirrorFrameSink {
    struct Frame {
        let sampleBuffer: CMSampleBuffer
        let isKeyFrame: Bool
    }

    private let lock = NSLock()
    private var storedFrames: [Frame] = []
    private var storedOrientations: [CGImagePropertyOrientation] = []
    private var storedStopCount = 0
    private var framesToReject = 0

    var frames: [Frame] {
        lock.lock()
        defer { lock.unlock() }
        return storedFrames
    }

    var orientations: [CGImagePropertyOrientation] {
        lock.lock()
        defer { lock.unlock() }
        return storedOrientations
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStopCount
    }

    /// Sonraki `count` kareyi reddeder (göstericinin hata vermesini taklit eder).
    func rejectNextFrames(_ count: Int) {
        lock.lock()
        framesToReject = count
        lock.unlock()
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if framesToReject > 0 {
            framesToReject -= 1
            return false
        }
        storedFrames.append(Frame(sampleBuffer: sampleBuffer, isKeyFrame: isKeyFrame))
        return true
    }

    func orientationDidChange(_ orientation: CGImagePropertyOrientation) {
        lock.lock()
        storedOrientations.append(orientation)
        lock.unlock()
    }

    func streamDidStop() {
        lock.lock()
        storedStopCount += 1
        lock.unlock()
    }
}

/// Bir sayaç; farklı iş parçacıklarından artırılabilir.
final class AtomicCounter {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }
}

extension XCTestCase {
    /// Ana çalışma döngüsünü döndürerek koşulun sağlanmasını bekler.
    @discardableResult
    func waitUntil(
        timeout: TimeInterval,
        message: String = "zaman aşımı",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let satisfied = condition()
        XCTAssertTrue(satisfied, message, file: file, line: line)
        return satisfied
    }

    /// Ana çalışma döngüsünü belirli bir süre döndürür.
    func spinRunLoop(for duration: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
    }

    static func shortSocketPath() -> String {
        "/tmp/cm-test-\(UUID().uuidString.prefix(8)).sock"
    }
}
