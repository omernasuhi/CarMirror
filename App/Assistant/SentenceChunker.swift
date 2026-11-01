import Foundation

/// Akış halinde gelen metni, sesli okuma için cümle cümle böler.
/// Böylece ilk cümle, cevabın tamamı gelmeden okunmaya başlar.
struct SentenceChunker {
    private(set) var buffer = ""

    private static let terminators: Set<Character> = [".", "!", "?", "…", "\n"]
    private static let trailing: Set<Character> = ["\"", "'", "”", "’", ")", "»"]

    /// Yeni parçayı ekler ve tamamlanan cümleleri döndürür.
    mutating func append(_ text: String) -> [String] {
        buffer += text
        var sentences: [String] = []
        while let range = Self.firstSentenceRange(in: buffer) {
            let sentence = String(buffer[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(range)
            if !sentence.isEmpty {
                sentences.append(sentence)
            }
        }
        return sentences
    }

    /// Kalan metni (bitiş işareti olmasa da) döndürür ve tamponu boşaltır.
    mutating func flush() -> String? {
        let remainder = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return remainder.isEmpty ? nil : remainder
    }

    /// Tamponun başındaki ilk tam cümlenin aralığı. Cümle, bir bitiş
    /// işaretinin ardından boşluk/satır sonu geldiğinde tamamlanmış sayılır;
    /// ondalık sayılar ("3.5") ve tek harfli kısaltmalar ("A.") bölünmez.
    private static func firstSentenceRange(in text: String) -> Range<String.Index>? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if terminators.contains(character) {
                var end = text.index(after: index)
                while end < text.endIndex, trailing.contains(text[end]) {
                    end = text.index(after: end)
                }
                let isNewline = character == "\n"
                let followedByBreak = end == text.endIndex ? false : text[end].isWhitespace
                if isNewline || followedByBreak, !isAbbreviation(text, at: index), !isDecimalPoint(text, at: index) {
                    return text.startIndex..<end
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func isDecimalPoint(_ text: String, at index: String.Index) -> Bool {
        guard text[index] == ".", index > text.startIndex else { return false }
        let next = text.index(after: index)
        guard next < text.endIndex else { return false }
        return text[text.index(before: index)].isNumber && text[next].isNumber
    }

    private static func isAbbreviation(_ text: String, at index: String.Index) -> Bool {
        guard text[index] == ".", index > text.startIndex else { return false }
        let previous = text.index(before: index)
        guard text[previous].isLetter else { return false }
        // Tek harfli kısaltma: " A." gibi.
        if previous == text.startIndex { return true }
        return text[text.index(before: previous)].isWhitespace
    }
}
