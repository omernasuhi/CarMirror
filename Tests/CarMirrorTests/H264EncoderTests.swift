import CoreMedia
import VideoToolbox
import XCTest
@testable import CarMirror

final class H264EncoderTests: XCTestCase {
    func testTargetSizeKeepsAspectRatioAndEvenDimensions() {
        let size = H264Encoder.targetSize(sourceWidth: 1179, sourceHeight: 2556, maxLongSide: 1280)
        XCTAssertEqual(size.height, 1280)
        XCTAssertEqual(size.width % 2, 0)
        XCTAssertEqual(Double(size.width) / Double(size.height), 1179.0 / 2556.0, accuracy: 0.01)

        let small = H264Encoder.targetSize(sourceWidth: 640, sourceHeight: 480, maxLongSide: 1600)
        XCTAssertEqual(small.width, 640)
        XCTAssertEqual(small.height, 480)
    }

    /// CI günlüğünde hangi kodlayıcıların bulunduğunu görmek için.
    func testLogAvailableVideoEncoders() {
        var list: CFArray?
        VTCopyVideoEncoderList(nil, &list)
        let encoders = (list as? [[String: Any]]) ?? []
        let names = encoders.compactMap { $0[kVTVideoEncoderList_EncoderName as String] as? String }
        print("CarMirror: VideoToolbox kodlayıcıları: \(names)")
    }

    func testFirstPacketIsKeyFrameWithParameterSetsAndScaledSize() throws {
        let packets = try TestMedia.encode(frameCount: 8, width: 1170, height: 2532, color: .testRed, quality: .balanced)
        XCTAssertGreaterThanOrEqual(packets.count, 8)

        let first = try XCTUnwrap(packets.first)
        XCTAssertTrue(first.isKeyFrame)
        XCTAssertGreaterThanOrEqual(first.parameterSets.count, 2, "SPS ve PPS bekleniyordu")
        XCTAssertEqual(first.nalUnitHeaderLength, 4)

        let format = try XCTUnwrap(MirrorSampleBuffers.makeFormatDescription(
            parameterSets: first.parameterSets,
            nalUnitHeaderLength: first.nalUnitHeaderLength
        ))
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let expected = H264Encoder.targetSize(sourceWidth: 1170, sourceHeight: 2532, maxLongSide: MirrorQuality.balanced.maxLongSide)
        XCTAssertEqual(Int(dimensions.width), Int(expected.width), accuracy: 16)
        XCTAssertEqual(Int(dimensions.height), Int(expected.height), accuracy: 16)

        XCTAssertTrue(packets.dropFirst().contains { !$0.isKeyFrame }, "Sonraki karelerin çoğu ara kare olmalı")
    }

    func testForcedKeyFrame() throws {
        let collector = PacketCollector()
        let encoder = try XCTUnwrap(H264Encoder(sourceWidth: 640, sourceHeight: 360, quality: .saver, output: collector.append))
        let pixelBuffer = TestMedia.makePixelBuffer(width: 640, height: 360, color: .testBlue)
        for index in 0..<6 {
            if index == 4 { encoder.forceNextKeyFrame() }
            XCTAssertTrue(encoder.encode(pixelBuffer, presentationTime: CMTime(value: CMTimeValue(index), timescale: 30), orientation: 1))
        }
        encoder.flush()
        let keyFrames = collector.packets.enumerated().filter { $0.element.isKeyFrame }.map(\.offset)
        XCTAssertEqual(keyFrames.first, 0)
        XCTAssertTrue(keyFrames.contains(4), "Zorlanan anahtar kare yok: \(keyFrames)")
        XCTAssertEqual(encoder.emittedFrameCount, collector.packets.count)
    }
}
