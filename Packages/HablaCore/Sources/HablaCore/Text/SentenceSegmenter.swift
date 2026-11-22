import Foundation
import NaturalLanguage

/// Splits block text into sentences (the unit for narration, highlighting and positions).
public struct SentenceSegmenter {
    /// Kokoro sounds best below ~400 characters per request.
    public var maxLength = 320
    /// Fragments shorter than this ("Oh!", "Yes.") are merged with the next one
    /// so they get natural intonation instead of sounding clipped.
    public var minLength = 12
    /// Book language (ISO code): helps the sentence tokenizer.
    public var language = "en"

    public init() {}

    public func ranges(in text: String) -> [TextRange] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(NLLanguage(rawValue: language))
        var raw: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            raw.append(NSRange(r, in: text))
            return true
        }
        if raw.isEmpty { raw = [NSRange(location: 0, length: ns.length)] }

        // Fix common false splits on abbreviations ("Mr. Darcy"), then trim.
        var merged: [NSRange] = []
        for r in raw {
            if let last = merged.last,
               Self.endsWithAbbreviation(ns.substring(with: last), language: language) || Self.continuesSentence(ns.substring(with: r)) {
                merged[merged.count - 1] = NSUnionRange(last, r)
            } else {
                merged.append(r)
            }
        }

        // Merge very short fragments forward (within the same block).
        var grouped: [NSRange] = []
        var pending: NSRange?
        for r in merged {
            let current = pending.map { NSUnionRange($0, r) } ?? r
            let trimmedLength = ns.substring(with: current).trimmingCharacters(in: .whitespacesAndNewlines).count
            if trimmedLength < minLength && r != merged.last {
                pending = current
            } else {
                grouped.append(current)
                pending = nil
            }
        }
        if let p = pending { grouped.append(p) }

        return grouped
            .flatMap { splitLong($0, in: ns) }
            .compactMap { trim($0, in: ns) }
    }

    func splitLong(_ r: NSRange, in ns: NSString) -> [NSRange] {
        guard r.length > maxLength else { return [r] }
        let s = ns.substring(with: r) as NSString
        let target = r.length / 2
        // Prefer strong punctuation closest to the middle.
        for separators in [["; ", ": ", " — ", "—"], [", "], [" "]] {
            var best: Int?
            for sep in separators {
                var search = NSRange(location: 0, length: s.length)
                while true {
                    let f = s.range(of: sep, options: [], range: search)
                    if f.location == NSNotFound { break }
                    let cut = f.location + f.length
                    if cut > 40 && cut < s.length - 40,
                       best == nil || abs(cut - target) < abs(best! - target) { best = cut }
                    search = NSRange(location: cut, length: s.length - cut)
                }
            }
            if let cut = best {
                return splitLong(NSRange(location: r.location, length: cut), in: ns)
                     + splitLong(NSRange(location: r.location + cut, length: r.length - cut), in: ns)
            }
        }
        return [r]
    }

    func trim(_ r: NSRange, in ns: NSString) -> TextRange? {
        var start = r.location, end = r.location + r.length
        let ws = CharacterSet.whitespacesAndNewlines
        while start < end, let u = UnicodeScalar(ns.character(at: start)), ws.contains(u) { start += 1 }
        while end > start, let u = UnicodeScalar(ns.character(at: end - 1)), ws.contains(u) { end -= 1 }
        return end > start ? TextRange(location: start, length: end - start) : nil
    }

    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "jr", "sr", "prof", "capt", "col", "gen", "lt", "sgt",
        "rev", "hon", "messrs", "mme", "mlle", "esq", "vs", "no", "vol", "ch", "fig", "mt", "ft",
    ]

    static let languageAbbreviations: [String: Set<String>] = [
        "es": ["sr", "sra", "srta", "dr", "dra", "ud", "uds", "pág", "págs", "etc", "aprox", "núm", "av", "dña", "dª", "d"],
        "de": ["dr", "prof", "bzw", "usw", "ca", "evtl", "ggf", "nr", "hr", "fr", "str", "vgl", "bspw", "inkl", "s", "z", "b", "d", "h", "u", "a", "o", "ä"],
        "ru": ["т", "е", "д", "п", "г", "гг", "др", "пр", "см", "рис", "стр", "им", "ул", "тыс", "млн", "р", "ст", "напр", "проф"],
        "uk": ["т", "д", "п", "р", "рр", "ін", "см", "рис", "стор", "ім", "вул", "тис", "млн", "ст", "напр", "проф"],
    ]

    /// "…taken it?” cried his wife." — a lowercase start continues the previous sentence.
    static func continuesSentence(_ s: String) -> Bool {
        guard let first = s.first(where: { !$0.isWhitespace && !"“”\"'‘’([—".contains($0) }) else { return false }
        return first.isLowercase
    }

    static func endsWithAbbreviation(_ s: String, language: String = "en") -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasSuffix(".") else { return false }
        let word = t.dropLast().split(whereSeparator: { !$0.isLetter }).last.map { $0.lowercased() } ?? ""
        if abbreviations.contains(word) || languageAbbreviations[language]?.contains(word) == true { return true }
        // Single initials: "J. R. R. Tolkien".
        return word.count == 1 && t.dropLast().last?.isUppercase == true
    }
}
