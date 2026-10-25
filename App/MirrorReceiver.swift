import CoreMedia
import Darwin
import Foundation
import ImageIO

/// Alınan kareleri gösteren hedef (CarPlay ekranı).
/// Tüm yöntemler alıcının kuyruğunda çağrılır.
protocol MirrorFrameSink: AnyObject {
    /// Gösterici yeni bir anahtar kareye ihtiyaç duyuyorsa false döndürür.
    func enqueue(_ sampleBuffer: CMSampleBuffer, isKeyFrame: Bool) -> Bool
    func orientationDidChange(_ orientation: CGImagePropertyOrientation)
    func streamDidStop()
}

/// Görüntü kaynaklarını CarPlay ekranına bağlar.
///
/// İki kaynak vardır:
/// - Yayın eklentisi (tüm iPhone ekranı): App Group içindeki Unix soketinden bağlanır.
/// - Uygulama içi yansıtma (`InAppMirror`): aynı süreçte, paketleri doğrudan verir.
///
/// Yayın eklentisi bağlıyken uygulama içi kareler yok sayılır. Gelen paketler
/// `CMSampleBuffer`'a çevrilip gösterilir; çözme işini `AVSampleBufferDisplayLayer` yapar.
final class MirrorReceiver {
    static let shared = MirrorReceiver(socketPath: MirrorConfig.socketPath)

    /// Yayın eklentisi bağlanınca/ayrılınca alıcının kuyruğunda çağrılır.
    /// `start` çağrısından önce atanmalıdır.
    var onBroadcastClientChange: ((Bool) -> Void)?

    private final class Client {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()

        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    private let socketPath: String?
    private let queue = DispatchQueue(label: "carmirror.receiver")
    private var listenSource: DispatchSourceRead?
    private var client: Client?
    private var readChunk = [UInt8](repeating: 0, count: 256 * 1024)
    private weak var sink: MirrorFrameSink?
    private var formatDescription: CMVideoFormatDescription?
    private var needsKeyFrame = true
    private var lastOrientation: UInt8 = 0
    private var localStreamActive = false
    private var localKeyFrameRequest: (() -> Void)?

    init(socketPath: String?) {
        self.socketPath = socketPath
    }

    func start() {
        queue.async { self.openListener() }
    }

    /// Soketi baştan açar. Uygulama uzun süre askıda kaldıysa sistem dinleyen
    /// soketi geri almış olabilir; ön plana dönüşte ve CarPlay bağlanınca çağrılır.
    /// Var olan yayın bağlantısını etkilemez.
    func restartListener() {
        queue.async {
            self.closeListener()
            self.openListener()
        }
    }

    /// Dinlemeyi ve varsa bağlantıyı kapatır.
    func stop() {
        queue.sync {
            closeListener()
            disconnectClient()
            if let socketPath { unlink(socketPath) }
        }
    }

    func setSink(_ newSink: MirrorFrameSink?) {
        queue.async {
            self.sink = newSink
            self.needsKeyFrame = true
            self.lastOrientation = 0
            self.requestKeyFrame()
        }
    }

    // MARK: - Uygulama içi kaynak

    func beginLocalStream(onKeyFrameRequest: @escaping () -> Void) {
        queue.async {
            self.localStreamActive = true
            self.localKeyFrameRequest = onKeyFrameRequest
            if self.client == nil {
                self.formatDescription = nil
                self.needsKeyFrame = true
                self.lastOrientation = 0
            }
        }
    }

    func endLocalStream() {
        queue.async {
            guard self.localStreamActive else { return }
            self.localStreamActive = false
            self.localKeyFrameRequest = nil
            if self.client == nil {
                self.formatDescription = nil
                self.needsKeyFrame = true
                self.sink?.streamDidStop()
            }
        }
    }

    func submitLocal(_ packet: VideoPacket) {
        queue.async {
            guard self.localStreamActive, self.client == nil else { return }
            self.handle(packet)
        }
    }

    /// Sıkıştırılmamış kare (kodlayıcı kullanılamadığında).
    func submitLocalRaw(_ sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation) {
        queue.async {
            guard self.localStreamActive, self.client == nil, let sink = self.sink else { return }
            self.reportOrientation(UInt8(orientation.rawValue), to: sink)
            _ = sink.enqueue(sampleBuffer, isKeyFrame: true)
        }
    }

    // MARK: - Dinleyici

    private func openListener() {
        guard listenSource == nil, let socketPath else { return }
        guard var address = UnixSocket.address(for: socketPath) else {
            NSLog("CarMirror: soket yolu çok uzun: \(socketPath)")
            return
        }

        unlink(socketPath)
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return }
        let bound = UnixSocket.withSockAddr(&address) { bind(listenFD, $0, $1) }
        guard bound == 0, listen(listenFD, 4) == 0 else {
            NSLog("CarMirror: soket açılamadı (errno \(errno)): \(socketPath)")
            close(listenFD)
            return
        }
        UnixSocket.setNonBlocking(listenFD)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients(listenFD: listenFD) }
        source.setCancelHandler { close(listenFD) }
        source.resume()
        listenSource = source
    }

    private func closeListener() {
        listenSource?.cancel()
        listenSource = nil
    }

    private func acceptClients(listenFD: Int32) {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { return }
            UnixSocket.setNonBlocking(clientFD)
            UnixSocket.disableSigPipe(clientFD)

            // Aynı anda tek yayın olabilir; yeni bağlantı eskisinin yerini alır.
            disconnectClient()

            let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
            let newClient = Client(fd: clientFD, source: source)
            source.setEventHandler { [weak self, weak newClient] in
                guard let self, let newClient else { return }
                self.readAvailable(from: newClient)
            }
            source.setCancelHandler { close(clientFD) }
            client = newClient
            source.resume()

            formatDescription = nil
            needsKeyFrame = true
            lastOrientation = 0
            requestKeyFrame()
            onBroadcastClientChange?(true)
        }
    }

    private func disconnectClient() {
        guard let current = client else { return }
        client = nil
        current.source.cancel()
        formatDescription = nil
        needsKeyFrame = true
        lastOrientation = 0
        onBroadcastClientChange?(false)
        if localStreamActive {
            requestKeyFrame()
        } else {
            sink?.streamDidStop()
        }
    }

    private func requestKeyFrame() {
        if let client {
            var command = MirrorProtocol.commandKeyFrameRequest
            _ = Darwin.write(client.fd, &command, 1)
        } else if localStreamActive {
            localKeyFrameRequest?()
        }
    }

    // MARK: - Okuma

    private func readAvailable(from client: Client) {
        while self.client === client {
            let count = readChunk.withUnsafeMutableBytes { chunk -> Int in
                let readCount = Darwin.read(client.fd, chunk.baseAddress, chunk.count)
                if readCount > 0 {
                    client.buffer.append(chunk.baseAddress!.assumingMemoryBound(to: UInt8.self), count: readCount)
                }
                return readCount
            }
            if count > 0 { continue }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
            // 0: yayın bitti; diğerleri: hata.
            disconnectClient()
            return
        }
        processBuffer(of: client)
    }

    private func processBuffer(of client: Client) {
        var offset = client.buffer.startIndex
        let headerSize = MirrorProtocol.headerSize

        while client.buffer.endIndex - offset >= headerSize {
            let buffer = client.buffer
            let type = buffer[offset]
            let orientation = buffer[offset + 1]
            let flags = buffer[offset + 2]
            let length = Int(buffer[offset + 4]) << 24
                | Int(buffer[offset + 5]) << 16
                | Int(buffer[offset + 6]) << 8
                | Int(buffer[offset + 7])

            guard length <= MirrorProtocol.maxPayloadSize else {
                NSLog("CarMirror: geçersiz paket, bağlantı kapatılıyor.")
                disconnectClient()
                return
            }
            let payloadStart = offset + headerSize
            guard buffer.endIndex - payloadStart >= length else { break }
            let payload = buffer.subdata(in: payloadStart..<(payloadStart + length))
            offset = payloadStart + length

            if type == MirrorProtocol.packetTypeVideo,
               let packet = VideoPacket.parse(orientation: orientation, flags: flags, payload: payload) {
                handle(packet)
            }
        }

        // `handle` bağlantıyı kapatmış olabilir.
        guard self.client === client else { return }
        client.buffer.removeSubrange(client.buffer.startIndex..<offset)
    }

    private func handle(_ packet: VideoPacket) {
        guard let sink else { return }

        if packet.isKeyFrame {
            guard let format = MirrorSampleBuffers.makeFormatDescription(
                parameterSets: packet.parameterSets,
                nalUnitHeaderLength: packet.nalUnitHeaderLength
            ) else { return }
            formatDescription = format
            needsKeyFrame = false
        } else if needsKeyFrame {
            return
        }
        guard let formatDescription,
              let sampleBuffer = MirrorSampleBuffers.makeSampleBuffer(data: packet.sampleData, format: formatDescription)
        else { return }

        reportOrientation(packet.orientation, to: sink)

        if !sink.enqueue(sampleBuffer, isKeyFrame: packet.isKeyFrame) {
            needsKeyFrame = true
            requestKeyFrame()
        }
    }

    private func reportOrientation(_ orientation: UInt8, to sink: MirrorFrameSink) {
        guard orientation != lastOrientation else { return }
        lastOrientation = orientation
        sink.orientationDidChange(CGImagePropertyOrientation(rawValue: UInt32(orientation)) ?? .up)
    }
}

/// `CMSampleBuffer` oluşturma yardımcıları.
enum MirrorSampleBuffers {
    static func makeFormatDescription(parameterSets: [Data], nalUnitHeaderLength: Int) -> CMVideoFormatDescription? {
        var joined = Data()
        var sizes: [Int] = []
        for set in parameterSets {
            joined.append(set)
            sizes.append(set.count)
        }

        var format: CMFormatDescription?
        let status = joined.withUnsafeBytes { buffer -> OSStatus in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0
            for size in sizes {
                pointers.append(base + offset)
                offset += size
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: sizes.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(nalUnitHeaderLength),
                formatDescriptionOut: &format
            )
        }
        return status == noErr ? format : nil
    }

    /// AVCC biçimindeki tek bir sıkıştırılmış kareden örnek tampon oluşturur.
    static func makeSampleBuffer(data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let length = data.count
        guard length > 0 else { return nil }
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: CMBlockBufferFlags(kCMBlockBufferAssureMemoryNowFlag),
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        status = data.withUnsafeBytes { buffer in
            CMBlockBufferReplaceDataBytes(
                with: buffer.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: length
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = length
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }
        markDisplayImmediately(sampleBuffer)
        return sampleBuffer
    }

    /// Sıkıştırılmamış bir görüntüden örnek tampon oluşturur.
    static func makeSampleBuffer(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }
        markDisplayImmediately(sampleBuffer)
        return sampleBuffer
    }

    /// Zaman damgasına bakılmadan, kare geldiği anda gösterilsin.
    private static func markDisplayImmediately(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}
