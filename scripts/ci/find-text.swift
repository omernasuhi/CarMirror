// Bir ekran görüntüsünde metin arar (Vision OCR).
// Kullanım: swift find-text.swift <görüntü.png> <aranan metin>
// Bulursa "x y üst yükseklik" (piksel, sol üst köşe orijin) yazdırır ve 0 ile çıkar.
import AppKit
import Foundation
import Vision

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write("Kullanım: find-text <görüntü> <metin>\n".data(using: .utf8)!)
    exit(2)
}

let url = URL(fileURLWithPath: arguments[1])
let needle = arguments[2].lowercased()
guard let image = NSImage(contentsOf: url),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("Görüntü açılamadı: \(url.path)\n".data(using: .utf8)!)
    exit(2)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: cgImage).perform([request])

let width = CGFloat(cgImage.width)
let height = CGFloat(cgImage.height)
var match: String?
for observation in request.results ?? [] {
    guard let candidate = observation.topCandidates(1).first else { continue }
    let box = observation.boundingBox
    let centerX = Int(box.midX * width)
    let centerY = Int((1 - box.midY) * height)
    let top = Int((1 - box.maxY) * height)
    let boxHeight = Int(box.height * height)
    FileHandle.standardError.write("OCR: \"\(candidate.string)\" @ \(centerX),\(centerY)\n".data(using: .utf8)!)
    if match == nil && candidate.string.lowercased().contains(needle) {
        match = "\(centerX) \(centerY) \(top) \(boxHeight)"
    }
}

if let match {
    print(match)
    exit(0)
}
exit(1)
