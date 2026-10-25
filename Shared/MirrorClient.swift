import Darwin
import Foundation

/// Yayın eklentisi tarafındaki soket istemcisi. Uygulama yayın sırasında kapalıysa
/// saniyede bir yeniden bağlanmayı dener. Uygulama verileri yeterince hızlı
/// okumazsa bekleyen veriyi büyütmek yerine kareleri atlar ve bir sonraki
/// anahtar kareyi bekler.
final class MirrorClient {
    /// İstemcinin kuyruğunda çağrılır. `start` çağrısından önce atanmalıdır.
    var onKeyFrameRequest: (() -> Void)?

    /// Bekleyen bayt sayısı bunu aşarsa yeni kareler atlanır.
    private let maxBacklog = 1_500_000

    private let socketPath: String?
    private let queue = DispatchQueue(label: "carmirror.client")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    /// Soketi izleyen kaynakların hepsi iptal edildiğinde dosya tanımlayıcısını kapatmak için.
    private var sourcesGroup: DispatchGroup?
    private var retryTimer: DispatchSourceTimer?
    private var outgoing = Data()
    private var outgoingOffset = 0
    private var waitingForKeyFrame = true
    private var running = false

    private let connectedLock = NSLock()
    private var connected = false

    var isConnected: Bool {
        connectedLock.lock()
        defer { connectedLock.unlock() }
        return connected
    }

    init(socketPath: String? = MirrorConfig.socketPath) {
        self.socketPath = socketPath
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.connect()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, self.running, self.fd < 0 else { return }
                self.connect()
            }
            timer.resume()
            self.retryTimer = timer
        }
    }

    func stop() {
        queue.sync {
            running = false
            retryTimer?.cancel()
            retryTimer = nil
            disconnect()
        }
    }

    func send(_ packet: VideoPacket) {
        queue.async {
            guard self.fd >= 0 else { return }
            if self.waitingForKeyFrame && !packet.isKeyFrame { return }
            if self.outgoing.count - self.outgoingOffset > self.maxBacklog {
                self.waitingForKeyFrame = true
                self.onKeyFrameRequest?()
                return
            }
            self.waitingForKeyFrame = false
            self.outgoing.append(packet.serialized())
            self.flush()
        }
    }

    // MARK: - Bağlantı

    private func connect() {
        guard fd < 0,
              let path = socketPath,
              var address = UnixSocket.address(for: path) else { return }

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return }
        UnixSocket.disableSigPipe(socketFD)
        UnixSocket.setNonBlocking(socketFD)

        let result = UnixSocket.withSockAddr(&address) { Darwin.connect(socketFD, $0, $1) }
        guard result == 0 else {
            close(socketFD)
            return
        }

        let group = DispatchGroup()
        group.enter()
        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.readCommands() }
        source.setCancelHandler { group.leave() }
        source.resume()

        fd = socketFD
        readSource = source
        sourcesGroup = group
        outgoing.removeAll()
        outgoingOffset = 0
        waitingForKeyFrame = true
        setConnected(true)
        onKeyFrameRequest?()
    }

    private func disconnect() {
        guard fd >= 0 else { return }
        let socketFD = fd
        let group = sourcesGroup

        stopWatchingWritable()
        readSource?.cancel()
        readSource = nil
        sourcesGroup = nil
        fd = -1
        group?.notify(queue: queue) { close(socketFD) }

        outgoing.removeAll()
        outgoingOffset = 0
        waitingForKeyFrame = true
        setConnected(false)
    }

    private func setConnected(_ value: Bool) {
        connectedLock.lock()
        connected = value
        connectedLock.unlock()
    }

    // MARK: - Okuma / yazma

    private func readCommands() {
        var buffer = [UInt8](repeating: 0, count: 64)
        while fd >= 0 {
            let socketFD = fd
            let count = buffer.withUnsafeMutableBytes { Darwin.read(socketFD, $0.baseAddress, $0.count) }
            if count > 0 {
                if buffer[0..<count].contains(MirrorProtocol.commandKeyFrameRequest) {
                    onKeyFrameRequest?()
                }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            // 0: uygulama bağlantıyı kapattı; diğerleri: hata.
            disconnect()
            return
        }
    }

    private func flush() {
        while fd >= 0 && outgoingOffset < outgoing.count {
            let socketFD = fd
            let offset = outgoingOffset
            let written = outgoing.withUnsafeBytes { buffer in
                Darwin.write(socketFD, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if written > 0 {
                outgoingOffset += written
                continue
            }
            if written < 0 && errno == EINTR { continue }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                compactOutgoing()
                watchWritable()
                return
            }
            disconnect()
            return
        }
        outgoing.removeAll(keepingCapacity: true)
        outgoingOffset = 0
        stopWatchingWritable()
    }

    /// Gönderilmiş baytları tampondan atarak belleğin büyümesini önler.
    private func compactOutgoing() {
        guard outgoingOffset > 512 * 1024 else { return }
        outgoing.removeSubrange(outgoing.startIndex..<(outgoing.startIndex + outgoingOffset))
        outgoingOffset = 0
    }

    private func watchWritable() {
        guard writeSource == nil, fd >= 0, let group = sourcesGroup else { return }
        group.enter()
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.flush() }
        source.setCancelHandler { group.leave() }
        source.resume()
        writeSource = source
    }

    private func stopWatchingWritable() {
        writeSource?.cancel()
        writeSource = nil
    }
}
