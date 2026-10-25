import AVFoundation
import XCTest
@testable import CarMirror

/// CarPlay ekranındaki görünüm: yön/döndürme ve gerçek görüntü katmanına çizim.
final class CarPlayDisplayTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MirrorConfig.sharedDefaults.set(false, forKey: MirrorSettings.flipLandscapeKey)
    }

    func testRotationAngles() {
        typealias Controller = CarPlayMirrorViewController
        XCTAssertEqual(Controller.rotationAngle(for: .up, flipLandscape: false), 0)
        XCTAssertEqual(Controller.rotationAngle(for: .right, flipLandscape: false), .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(Controller.rotationAngle(for: .left, flipLandscape: false), -.pi / 2, accuracy: 0.0001)
        XCTAssertEqual(Controller.rotationAngle(for: .down, flipLandscape: false), .pi, accuracy: 0.0001)
        XCTAssertEqual(Controller.rotationAngle(for: .right, flipLandscape: true), 3 * .pi / 2, accuracy: 0.0001)
        XCTAssertEqual(Controller.rotationAngle(for: .up, flipLandscape: true), 0)
    }

    func testLandscapePhoneFillsTheCarScreen() throws {
        let controller = CarPlayMirrorViewController()
        let window = try makeCarWindow(rootViewController: controller)
        defer { window.isHidden = true }

        controller.apply(orientation: .right)
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.displayView.bounds.size, CGSize(width: 480, height: 800))
        XCTAssertEqual(controller.displayView.frame.width, 800, accuracy: 0.5)
        XCTAssertEqual(controller.displayView.frame.height, 480, accuracy: 0.5)

        controller.apply(orientation: .up)
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.displayView.bounds.size, CGSize(width: 800, height: 480))
        XCTAssertEqual(controller.displayView.transform, .identity)
    }

    func testDisplayLayerRendersReceivedFrames() throws {
        let controller = CarPlayMirrorViewController()
        let window = try makeCarWindow(rootViewController: controller)
        defer { window.isHidden = true }
        XCTAssertFalse(controller.placeholderLabel.isHidden)

        let packets = try TestMedia.encode(frameCount: 15, width: 1170, height: 2532, color: .testRed)
        let receiver = MirrorReceiver(socketPath: nil)
        receiver.setSink(controller.sink)
        receiver.beginLocalStream {}
        packets.forEach { receiver.submitLocal($0) }

        waitUntil(timeout: 5, message: "gösterici kareleri almadı (\(controller.sink.enqueuedFrameCount))") {
            controller.sink.enqueuedFrameCount == packets.count
        }
        spinRunLoop(for: 1)

        let renderer = controller.sink.renderer
        XCTAssertNotEqual(renderer.status, .failed, "Gösterici hatası: \(String(describing: renderer.error))")
        XCTAssertEqual(renderer.status, .rendering)
        XCTAssertTrue(controller.placeholderLabel.isHidden, "Görüntü gelince bekleme yazısı gizlenmeli")

        receiver.endLocalStream()
        waitUntil(timeout: 3, message: "yayın bitince bekleme yazısı geri gelmedi") {
            !controller.placeholderLabel.isHidden
        }
    }

    private func makeCarWindow(rootViewController: UIViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(waitForPhoneWindow()?.windowScene, "Uygulama penceresi bulunamadı")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 480)
        window.rootViewController = rootViewController
        window.isHidden = false
        rootViewController.view.layoutIfNeeded()
        return window
    }
}

extension XCTestCase {
    func waitForPhoneWindow(timeout: TimeInterval = 10) -> UIWindow? {
        waitUntil(timeout: timeout, message: "telefon penceresi açılmadı") { InAppMirror.phoneWindow != nil }
        return InAppMirror.phoneWindow
    }
}
