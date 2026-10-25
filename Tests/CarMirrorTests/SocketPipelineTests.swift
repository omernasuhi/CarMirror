import CoreMedia
import ImageIO
import XCTest
@testable import CarMirror

/// Yayın eklentisinin yolu: kodlayıcı → istemci → Unix soketi → alıcı → gösterici.
final class SocketPipelineTests: XCTestCase {
    private var socketPath = ""
    private var receiver: MirrorReceiver!
    private var sink: CollectingSink!
    private var client: MirrorClient!
    private var keyFrameRequests: AtomicCounter!

    override func setUp() {
        super.setUp()
        socketPath = Self.shortSocketPath()
        sink = CollectingSink()
        receiver = MirrorReceiver(socketPath: socketPath)
        receiver.setSink(sink)
        receiver.start()

        keyFrameRequests = AtomicCounter()
        client = MirrorClient(socketPath: socketPath)
        let requests = keyFrameRequests!
        client.onKeyFrameRequest = { requests.increment() }
    }

    override func tearDown() {
        client.stop()
        receiver.stop()
        client = nil
        receiver = nil
        sink = nil
        super.tearDown()
    }

    private func connectClient() {
        client.start()
        waitUntil(timeout: 5, message: "istemci sokete bağlanamadı: \(socketPath)") { client.isConnected }
        // Bağlantı sırasında gelen anahtar kare isteklerinin bitmesini bekle.
        spinRunLoop(for: 0.3)
    }

    func testFramesTravelThroughSocketAndDecodeToTheSameImage() throws {
        connectClient()

        let packets = try TestMedia.encode(frameCount: 12, width: 1170, height: 2532, color: .testRed, orientation: .right)
        XCTAssertTrue(packets.first?.isKeyFrame == true)
        packets.forEach { client.send($0) }

        waitUntil(timeout: 10, message: "kareler alıcıya ulaşmadı (\(sink.frames.count)/\(packets.count))") {
            sink.frames.count == packets.count
        }

        let first = try XCTUnwrap(sink.frames.first)
        XCTAssertTrue(first.isKeyFrame)
        XCTAssertEqual(sink.orientations.first, .right)

        let dimensions = try XCTUnwrap(TestMedia.dimensions(of: first.sampleBuffer))
        XCTAssertGreaterThan(dimensions.height, dimensions.width, "Dikey görüntü bekleniyordu")

        let decoded = try TestMedia.decode(first.sampleBuffer)
        let color = TestMedia.centerColor(of: decoded)
        XCTAssertTrue(color.isClose(to: .testRed, tolerance: 30), "Çözülen renk \(color), beklenen \(PixelColor.testRed)")
    }

    func testDisplayFailureRequestsKeyFrameFromBroadcast() throws {
        connectClient()
        keyFrameRequests.reset()

        sink.rejectNextFrames(1)
        let packets = try TestMedia.encode(frameCount: 3, width: 640, height: 1280, color: .testBlue)
        packets.forEach { client.send($0) }

        waitUntil(timeout: 5, message: "gösterici hatasından sonra anahtar kare istenmedi") {
            keyFrameRequests.value > 0
        }
    }

    func testClientReconnectsAfterReceiverRestarts() throws {
        connectClient()
        receiver.stop()
        waitUntil(timeout: 5, message: "istemci kopmayı fark etmedi") { !client.isConnected }
        XCTAssertGreaterThan(sink.stopCount, 0)

        receiver = MirrorReceiver(socketPath: socketPath)
        receiver.setSink(sink)
        receiver.start()
        waitUntil(timeout: 5, message: "istemci yeniden bağlanmadı") { client.isConnected }

        spinRunLoop(for: 0.3)
        let packets = try TestMedia.encode(frameCount: 2, width: 640, height: 1280, color: .testBlue)
        packets.forEach { client.send($0) }
        waitUntil(timeout: 5, message: "yeniden bağlandıktan sonra kare gelmedi") { sink.frames.count >= 2 }
    }
}
