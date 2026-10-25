import XCTest
@testable import CarMirror

final class VideoPacketTests: XCTestCase {
    private func roundTrip(_ packet: VideoPacket) -> VideoPacket? {
        let data = packet.serialized()
        XCTAssertEqual(data[0], MirrorProtocol.packetTypeVideo)
        let length = Int(data[4]) << 24 | Int(data[5]) << 16 | Int(data[6]) << 8 | Int(data[7])
        XCTAssertEqual(length, data.count - MirrorProtocol.headerSize)
        let payload = data.subdata(in: MirrorProtocol.headerSize..<data.count)
        return VideoPacket.parse(orientation: data[1], flags: data[2], payload: payload)
    }

    func testKeyFrameRoundTrip() throws {
        let packet = VideoPacket(
            orientation: 6,
            isKeyFrame: true,
            nalUnitHeaderLength: 4,
            parameterSets: [Data([0x67, 0x64, 0x00, 0x1F]), Data([0x68, 0xEE, 0x3C])],
            sampleData: Data([0x00, 0x00, 0x00, 0x02, 0x65, 0x88])
        )
        let parsed = try XCTUnwrap(roundTrip(packet))
        XCTAssertEqual(parsed.orientation, 6)
        XCTAssertTrue(parsed.isKeyFrame)
        XCTAssertEqual(parsed.nalUnitHeaderLength, 4)
        XCTAssertEqual(parsed.parameterSets, packet.parameterSets)
        XCTAssertEqual(parsed.sampleData, packet.sampleData)
    }

    func testDeltaFrameRoundTrip() throws {
        let packet = VideoPacket(
            orientation: 1,
            isKeyFrame: false,
            nalUnitHeaderLength: 4,
            parameterSets: [],
            sampleData: Data(repeating: 0xAB, count: 70_000)
        )
        let parsed = try XCTUnwrap(roundTrip(packet))
        XCTAssertFalse(parsed.isKeyFrame)
        XCTAssertTrue(parsed.parameterSets.isEmpty)
        XCTAssertEqual(parsed.sampleData, packet.sampleData)
    }

    func testTruncatedKeyFrameIsRejected() {
        // Parametre seti uzunluğu 10 diyor ama yalnızca 2 bayt var.
        let payload = Data([4, 1, 0x00, 0x0A, 0x67, 0x64])
        XCTAssertNil(VideoPacket.parse(orientation: 1, flags: MirrorProtocol.flagKeyFrame, payload: payload))
    }

    func testEmptyPayloadIsRejected() {
        XCTAssertNil(VideoPacket.parse(orientation: 1, flags: 0, payload: Data()))
    }
}
