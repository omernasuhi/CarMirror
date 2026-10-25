import CoreMedia
import Foundation
import VideoToolbox

/// Ekran karelerini donanım H.264 kodlayıcısıyla sıkıştırır.
/// `encode`, `forceNextKeyFrame` ve `flush` aynı seri kuyruktan çağrılmalıdır;
/// `output` VideoToolbox'ın kendi iş parçacığında çağrılır.
final class H264Encoder {
    let sourceWidth: Int
    let sourceHeight: Int

    private var session: VTCompressionSession?
    private var forceKeyFrame = true
    private let output: (VideoPacket) -> Void

    private let counterLock = NSLock()
    private var emitted = 0

    /// Şimdiye kadar üretilen sıkıştırılmış kare sayısı.
    var emittedFrameCount: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return emitted
    }

    init?(sourceWidth: Int, sourceHeight: Int, quality: MirrorQuality, output: @escaping (VideoPacket) -> Void) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.output = output

        // Oturum boyutu kaynaktan farklıysa VideoToolbox kareyi kendisi ölçekler.
        let size = Self.targetSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight, maxLongSide: quality.maxLongSide)
        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: size.width,
            height: size.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )
        guard status == noErr, let newSession else {
            NSLog("CarMirror: H.264 kodlayıcı oluşturulamadı (\(status)).")
            return nil
        }
        session = newSession

        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2))
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: quality.framesPerSecond))
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: quality.bitRate))
        VTCompressionSessionPrepareToEncodeFrames(newSession)
    }

    deinit {
        invalidate()
    }

    func forceNextKeyFrame() {
        forceKeyFrame = true
    }

    /// Kodlayıcı artık kullanılamıyorsa (ör. oturum geçersizleştiyse) false döner.
    @discardableResult
    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, orientation: UInt8) -> Bool {
        guard let session else { return false }

        var frameProperties: CFDictionary?
        if forceKeyFrame {
            forceKeyFrame = false
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] encodeStatus, _, sampleBuffer in
            guard encodeStatus == noErr, let sampleBuffer, let self else { return }
            self.emit(sampleBuffer, orientation: orientation)
        }

        if status != noErr {
            forceKeyFrame = true
            return status != kVTInvalidSessionErr
        }
        return true
    }

    /// Kodlayıcıda bekleyen tüm karelerin çıkmasını bekler.
    func flush() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    private func emit(_ sampleBuffer: CMSampleBuffer, orientation: UInt8) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var isKeyFrame = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
           let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            isKeyFrame = !notSync
        }

        var parameterSets: [Data] = []
        var nalUnitHeaderLength: Int32 = 4
        if isKeyFrame {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &nalUnitHeaderLength
            )
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                guard status == noErr, let pointer else { return }
                parameterSets.append(Data(bytes: pointer, count: size))
            }
            guard !parameterSets.isEmpty else { return }
        }

        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0 else { return }
        var sampleData = Data(count: length)
        let copyStatus = sampleData.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        counterLock.lock()
        emitted += 1
        counterLock.unlock()

        output(VideoPacket(
            orientation: orientation,
            isKeyFrame: isKeyFrame,
            nalUnitHeaderLength: Int(nalUnitHeaderLength),
            parameterSets: parameterSets,
            sampleData: sampleData
        ))
    }

    /// En-boy oranını koruyarak uzun kenarı `maxLongSide` ile sınırlar; boyutlar çift sayıdır.
    static func targetSize(sourceWidth: Int, sourceHeight: Int, maxLongSide: Int) -> (width: Int32, height: Int32) {
        let longSide = max(sourceWidth, sourceHeight, 1)
        let scale = min(1.0, Double(maxLongSide) / Double(longSide))
        func even(_ value: Int) -> Int32 {
            Int32(max(2, Int((Double(value) * scale / 2).rounded()) * 2))
        }
        return (even(sourceWidth), even(sourceHeight))
    }
}
