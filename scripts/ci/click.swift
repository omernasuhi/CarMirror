// Ekranda verilen noktaya fare tıklaması gönderir (ekran noktası, sol üst orijin).
// Kullanım: swift click.swift <x> <y>
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3, let x = Double(arguments[1]), let y = Double(arguments[2]) else {
    FileHandle.standardError.write("Kullanım: click <x> <y>\n".data(using: .utf8)!)
    exit(2)
}

let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType) {
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

post(.mouseMoved)
usleep(150_000)
post(.leftMouseDown)
usleep(120_000)
post(.leftMouseUp)
print("Tıklandı: \(Int(x)),\(Int(y))")
