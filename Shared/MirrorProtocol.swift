import Foundation

/// Eklentiden uygulamaya giden paket biçimi:
///
///     [0]     tür (1 = video karesi)
///     [1]     yön (CGImagePropertyOrientation ham değeri)
///     [2]     bayraklar (bit 0 = anahtar kare)
///     [3]     ayrılmış
///     [4...7] yük uzunluğu (UInt32, big-endian)
///     [8...]  yük
///
/// Anahtar karelerde yük şöyle başlar:
///     [NAL başlık uzunluğu: UInt8][parametre seti sayısı: UInt8]
///     her set için [uzunluk: UInt16 big-endian][set baytları]
/// ve ardından AVCC biçimindeki kare verisi gelir. Diğer karelerde yük
/// doğrudan AVCC kare verisidir.
///
/// Uygulamadan eklentiye tek baytlık komutlar gönderilir.
enum MirrorProtocol {
    static let headerSize = 8
    static let packetTypeVideo: UInt8 = 1
    static let flagKeyFrame: UInt8 = 1 << 0
    static let maxPayloadSize = 16 * 1024 * 1024

    /// Uygulama yeni bir anahtar kare istiyor ("K").
    static let commandKeyFrameRequest: UInt8 = 0x4B
}

struct VideoPacket {
    var orientation: UInt8
    var isKeyFrame: Bool
    var nalUnitHeaderLength: Int
    var parameterSets: [Data]
    var sampleData: Data

    func serialized() -> Data {
        var payload = Data()
        if isKeyFrame {
            payload.append(contentsOf: [UInt8(nalUnitHeaderLength), UInt8(parameterSets.count)])
            for set in parameterSets {
                payload.append(contentsOf: [UInt8(set.count >> 8 & 0xFF), UInt8(set.count & 0xFF)])
                payload.append(set)
            }
        }
        payload.append(sampleData)

        let length = UInt32(payload.count)
        var packet = Data(capacity: MirrorProtocol.headerSize + payload.count)
        packet.append(contentsOf: [
            MirrorProtocol.packetTypeVideo,
            orientation,
            isKeyFrame ? MirrorProtocol.flagKeyFrame : 0,
            0,
            UInt8(length >> 24 & 0xFF),
            UInt8(length >> 16 & 0xFF),
            UInt8(length >> 8 & 0xFF),
            UInt8(length & 0xFF),
        ])
        packet.append(payload)
        return packet
    }

    /// Başlığı ayrıştırılmış bir paketin yükünü çözer.
    static func parse(orientation: UInt8, flags: UInt8, payload: Data) -> VideoPacket? {
        let isKeyFrame = flags & MirrorProtocol.flagKeyFrame != 0
        var index = payload.startIndex
        var nalUnitHeaderLength = 4
        var parameterSets: [Data] = []

        if isKeyFrame {
            guard payload.endIndex - index >= 2 else { return nil }
            nalUnitHeaderLength = Int(payload[index])
            let count = Int(payload[index + 1])
            index += 2
            for _ in 0..<count {
                guard payload.endIndex - index >= 2 else { return nil }
                let length = Int(payload[index]) << 8 | Int(payload[index + 1])
                index += 2
                guard payload.endIndex - index >= length else { return nil }
                parameterSets.append(payload.subdata(in: index..<(index + length)))
                index += length
            }
            guard !parameterSets.isEmpty else { return nil }
        }

        guard index < payload.endIndex else { return nil }
        return VideoPacket(
            orientation: orientation,
            isKeyFrame: isKeyFrame,
            nalUnitHeaderLength: nalUnitHeaderLength,
            parameterSets: parameterSets,
            sampleData: payload.subdata(in: index..<payload.endIndex)
        )
    }
}
