import CoreMedia
import XCTest
@testable import CarMirror

/// Simülatörde kullanılan yol: uygulama ekranı → kodlayıcı → alıcı → gösterici.
final class InAppMirrorTests: XCTestCase {
    override func tearDown() {
        InAppMirror.shared.stop()
        MirrorReceiver.shared.setSink(nil)
        super.tearDown()
    }

    func testPhoneScreenIsCapturedAndDelivered() throws {
        let window = try XCTUnwrap(waitForPhoneWindow())
        let sink = CollectingSink()
        MirrorReceiver.shared.setSink(sink)

        InAppMirror.shared.start(window: window)
        XCTAssertTrue(InAppMirror.shared.isRunning)
        waitUntil(timeout: 10, message: "uygulama içi yansıtmadan kare gelmedi") { sink.frames.count >= 5 }

        let first = try XCTUnwrap(sink.frames.first)
        XCTAssertTrue(first.isKeyFrame)
        let dimensions = try XCTUnwrap(TestMedia.dimensions(of: first.sampleBuffer))
        XCTAssertGreaterThan(dimensions.height, dimensions.width, "Telefon ekranı dikey olmalı")

        let image: CVPixelBuffer
        if let raw = CMSampleBufferGetImageBuffer(first.sampleBuffer) {
            print("CarMirror: uygulama içi yansıtma sıkıştırılmamış kare kullanıyor")
            image = raw
        } else {
            image = try TestMedia.decode(first.sampleBuffer)
        }
        XCTAssertGreaterThan(TestMedia.maxBrightness(of: image), 100, "Yakalanan ekran tamamen karanlık")

        InAppMirror.shared.stop()
        waitUntil(timeout: 3, message: "yansıtma durunca gösterici haberdar edilmedi") { sink.stopCount > 0 }
    }

    func testBroadcastTakesPriorityOverInAppMirror() throws {
        let window = try XCTUnwrap(waitForPhoneWindow())
        let socketPath = try XCTUnwrap(MirrorConfig.socketPath)
        let sink = CollectingSink()
        MirrorReceiver.shared.setSink(sink)
        InAppMirror.shared.start(window: window)
        waitUntil(timeout: 10, message: "uygulama içi kare gelmedi") { sink.frames.count >= 2 }

        // Yayın eklentisi bağlanınca uygulama içi yansıtma durmalı.
        let client = MirrorClient(socketPath: socketPath)
        client.start()
        defer { client.stop() }
        waitUntil(timeout: 5, message: "yayın istemcisi uygulamaya bağlanamadı: \(socketPath)") { client.isConnected }
        waitUntil(timeout: 3, message: "yayın başlayınca uygulama içi yansıtma durmadı") { !InAppMirror.shared.isRunning }
    }
}

extension TestMedia {
    /// Görüntüde seyrek bir ızgara üzerindeki en parlak pikselin parlaklığı (0–255).
    static func maxBrightness(of pixelBuffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var brightest = 0
        for y in stride(from: 0, to: CVPixelBufferGetHeight(pixelBuffer), by: 8) {
            for x in stride(from: 0, to: CVPixelBufferGetWidth(pixelBuffer), by: 8) {
                let pixel = base + y * bytesPerRow + x * 4
                brightest = max(brightest, (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3)
            }
        }
        return brightest
    }
}
