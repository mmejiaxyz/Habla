import Foundation

/// Rewrites display text into what a voice should say, for English books.
/// "Mr. Darcy, in 1813…" → "Mister Darcy, in eighteen thirteen…".
/// Returns the input unchanged when nothing needed rewriting.
public struct SpeechNormalizer {
    public init() {}

    public func spoken(_ text: String, isHeading: Bool = false) -> String {
        var s = text

        s = s.replacingOccurrences(of: "\n", with: ", ")
        s = s.replacingOccurrences(of: "\u{00A0}", with: " ")
        s = s.replacingOccurrences(of: "[\u{00AD}\u{200B}\u{2060}\u{FEFF}]", with: "", options: .regularExpression)

        // Dashes become pauses; Kokoro otherwise tends to rush through them.
        s = replace(s, #"\s*[—―]\s*"#, ", ")
        s = replace(s, #"\s+–\s+"#, ", ")
        s = replace(s, #"(\d)–(\d)"#, "$1 to $2")
        s = replace(s, #",\s*,"#, ",")
        s = replace(s, #"^\s*,\s*"#, "")

        // Abbreviations.
        for (pattern, replacement) in Self.abbreviations { s = replace(s, pattern, replacement) }

        // Headings: "Chapter IV", "BOOK II.", or a heading that is just "XII".
        s = replace(s, #"\b(Chapter|CHAPTER|Book|BOOK|Part|PART|Volume|VOLUME|Act|ACT|Scene|SCENE|Canto|CANTO)\s+([IVXLCDM]+)\b\.?"#) { m in
            "\(m[1]) \(Self.romanToInt(m[2]).map(Self.cardinal) ?? m[2])"
        }
        if isHeading {
            // A heading that is only a number ("IV", "I.", "12") is a chapter number.
            let bare = s.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            if let n = bare == "I" ? 1 : (Self.romanToInt(bare) ?? Int(bare)) {
                s = "Chapter \(Self.cardinal(n))"
            }
        }

        // Currency, percentages, symbols.
        s = replace(s, #"\$(\d[\d,]*)(\.\d\d)?\b"#) { m in "\(m[1])\(m[2]) dollars" }
        s = replace(s, #"£(\d[\d,]*)"#, "$1 pounds")
        s = replace(s, #"(\d)\s?%"#, "$1 percent")
        s = s.replacingOccurrences(of: " & ", with: " and ")
        s = replace(s, #"\b(\d+)(st|nd|rd|th)\b"#) { m in Int(m[1]).map(Self.ordinal) ?? m[0] }

        // Years read as years: 1813 → eighteen thirteen; 1900 → nineteen hundred.
        s = replace(s, #"(?<![\d,.$£])\b(1[1-9]\d\d|20\d\d)\b(?![\d,]|\s*(?:dollars|pounds|percent|people|men|miles|feet))"#) { m in
            Int(m[1]).map(Self.year) ?? m[0]
        }
        // Other numbers spelled out (with commas removed).
        s = replace(s, #"(?<![\d.])\d{1,3}(?:,\d{3})+(?![\d])|(?<![\d.,])\d+(?![\d,.]\d)"#) { m in
            Int(m[0].replacingOccurrences(of: ",", with: "")).map(Self.cardinal) ?? m[0]
        }

        // SHOUTED sentences (chapter titles, "THE END") read as words, not letters.
        let letters = s.filter(\.isLetter)
        if letters.count > 6, letters.filter(\.isUppercase).count * 10 >= letters.count * 8 {
            s = s.lowercased()
            if let f = s.first { s = f.uppercased() + s.dropFirst() }
        }

        s = s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return s
    }

    // MARK: - Tables

    static let abbreviations: [(String, String)] = [
        (#"\bMr\.(?=\s)"#, "Mister"), (#"\bMrs\.(?=\s)"#, "Missus"), (#"\bMs\.(?=\s)"#, "Miz"),
        (#"\bDr\.(?=\s+[A-Z])"#, "Doctor"), (#"\bSt\.(?=\s+[A-Z])"#, "Saint"),
        (#"\bProf\.(?=\s)"#, "Professor"), (#"\bCapt\.(?=\s)"#, "Captain"), (#"\bCol\.(?=\s)"#, "Colonel"),
        (#"\bGen\.(?=\s)"#, "General"), (#"\bLt\.(?=\s)"#, "Lieutenant"), (#"\bSgt\.(?=\s)"#, "Sergeant"),
        (#"\bRev\.(?=\s)"#, "Reverend"), (#"\bHon\.(?=\s)"#, "Honourable"), (#"\bJr\.(?=[\s,])"#, "Junior"),
        (#"\bSr\.(?=[\s,])"#, "Senior"), (#"\bMessrs\.(?=\s)"#, "Messieurs"), (#"\bMt\.(?=\s)"#, "Mount"),
        (#"\bvs\.(?=\s)"#, "versus"), (#"\betc\."#, "et cetera"), (#"\be\.g\.,?"#, "for example,"),
        (#"\bi\.e\.,?"#, "that is,"), (#"\bNo\.\s*(?=\d)"#, "number "), (#"\bvol\.\s*(?=\d)"#, "volume "),
        (#"\bch\.\s*(?=\d)"#, "chapter "), (#"\bp\.\s*(?=\d)"#, "page "),
    ]

    // MARK: - Numbers

    static let spell: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .spellOut
        return f
    }()

    static func cardinal(_ n: Int) -> String { spell.string(from: NSNumber(value: n)) ?? String(n) }

    static func ordinal(_ n: Int) -> String {
        let words = cardinal(n)
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth",
                         "eight": "eighth", "nine": "ninth", "twelve": "twelfth"]
        var parts = words.components(separatedBy: CharacterSet(charactersIn: " -"))
        let seps = words.filter { $0 == " " || $0 == "-" }.map(String.init)
        guard var last = parts.popLast() else { return words }
        if let irr = irregular[last] { last = irr }
        else if last.hasSuffix("y") { last = String(last.dropLast()) + "ieth" }
        else { last += "th" }
        parts.append(last)
        var out = parts[0]
        for i in 1..<parts.count { out += seps[i - 1] + parts[i] }
        return out
    }

    static func year(_ y: Int) -> String {
        if y >= 2000 && y < 2010 { return cardinal(y) }                       // two thousand five
        let hi = y / 100, lo = y % 100
        if lo == 0 { return "\(cardinal(hi)) hundred" }                      // nineteen hundred
        if lo < 10 { return "\(cardinal(hi)) oh \(cardinal(lo))" }           // eighteen oh five
        return "\(cardinal(hi)) \(cardinal(lo))"                             // eighteen thirteen
    }

    static func romanToInt(_ s: String) -> Int? {
        let map: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]
        guard !s.isEmpty, s.count <= 9, s.allSatisfy({ map[$0] != nil }), s != "I" else { return nil }
        var total = 0, prev = 0
        for ch in s.reversed() {
            let v = map[ch]!
            total += v < prev ? -v : v
            prev = max(prev, v)
        }
        return total > 0 && total < 4000 ? total : nil
    }

    // MARK: - Regex helpers

    func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    func replace(_ s: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map {
                m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0))
            }
            out += transform(groups)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
