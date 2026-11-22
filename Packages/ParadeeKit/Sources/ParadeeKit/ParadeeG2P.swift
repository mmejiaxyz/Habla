import Foundation

/// Paradee's own grapheme-to-phoneme model, a Swift port of `paradee/g2p.py`: text -> the eSpeak-style
/// phonemes Paradee was trained on, without eSpeak. It reads one word, plus the last letter of the word
/// before it and the first letter of the word after it, through a small ONNX model, with word lists and
/// number tables for the words and numbers the model would get wrong.
///
/// All string algorithms work on `unicodeScalars`, as Python indexes strings by code point: Swift's
/// `Character` is a grapheme cluster ("ɔ̃" is one Character but two vocab ids).
final class ParadeeG2P: @unchecked Sendable {
    private static let maxWord = 60                       // letters of a word the model reads
    private static let percent: [String: String] = ["hi": "प्रतिशत", "fr": "pour cent", "es": "por ciento"]
    private static let devanagariDigits: [Unicode.Scalar: Unicode.Scalar] = [
        "०": "0", "१": "1", "२": "2", "३": "3", "४": "4", "५": "5", "६": "6", "७": "7", "८": "8", "९": "9",
    ]
    private static let soft: [Unicode.Scalar: Unicode.Scalar] = ["b": "β", "d": "ð", "ɡ": "ɣ"]
    /// The zero-width characters trimmed off the ends of a word and removed from the text.
    fileprivate static let zeroWidth: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}"]

    struct Lexicon {
        var words: [String: String]
        var contexts: [String: String]   // "word\tbefore\tafter" -> phonemes, as in the JSON
    }

    private let outs: [String]
    private let index: [String: Int]
    private let unk: Int
    private let numbers: [String: [String: String]]
    fileprivate let lexicon: [String: Lexicon]
    private let session: ONNXSession

    convenience init(threads: Int = 1) throws {
        try self.init(threads: threads, jsonURL: ParadeeResources.url("g2p.json.gz"),
                      modelURL: ParadeeResources.url("g2p.onnx"))
    }

    init(threads: Int = 1, jsonURL: URL, modelURL: URL) throws {
        struct Vocab: Decodable {
            let inn: [String]; let out: [String]
            enum CodingKeys: String, CodingKey { case inn = "in", out = "out" }
        }
        struct LangLexicon: Decodable { let w: [String: String]; let c: [String: String] }
        struct DataFile: Decodable {
            let vocab: Vocab; let numbers: [String: [String: String]]; let lexicon: [String: LangLexicon]
        }
        let data = try JSONDecoder().decode(DataFile.self, from: Gzip.gunzip(try Data(contentsOf: jsonURL)))
        outs = data.vocab.out
        var index: [String: Int] = [:]
        for (i, c) in data.vocab.inn.enumerated() { index[c] = i }
        self.index = index
        unk = index["<unk>"]!
        numbers = data.numbers
        lexicon = data.lexicon.mapValues { Lexicon(words: $0.w, contexts: $0.c) }
        session = try ONNXSession(modelData: Data(contentsOf: modelURL), threads: threads)
    }

    // MARK: - The model

    /// Phonemes for each (language, letter before, word, letter after), from the model alone.
    /// The model emits three output steps per input letter; the CTC path over the first
    /// 3 * row.count steps merges repeats and drops blanks (0).
    func model(_ items: [(lang: String, before: String, word: String, after: String)]) throws -> [String] {
        guard !items.isEmpty else { return [] }
        var rows: [[Int]] = []
        var longest = 0
        for item in items {
            var row = [index["<\(item.lang)>"]!, index[item.before] ?? unk, index["<s1>"]!]
            for c in item.word.lowercased().unicodeScalars.prefix(Self.maxWord) {
                row.append(index[String(c)] ?? unk)
            }
            row.append(index["<s2>"]!)
            row.append(index[item.after] ?? unk)
            longest = max(longest, row.count)
            rows.append(row)
        }
        var chars: [Int64] = []
        var pad: [Bool] = []
        for row in rows {
            chars.append(contentsOf: row.map(Int64.init))
            chars.append(contentsOf: repeatElement(0, count: longest - row.count))
            pad.append(contentsOf: repeatElement(false, count: row.count))
            pad.append(contentsOf: repeatElement(true, count: longest - row.count))
        }
        let best = try session.run([
            ("chars", .int64(chars, shape: [Int64(rows.count), Int64(longest)])),
            ("pad", .bool(pad, shape: [Int64(rows.count), Int64(longest)])),
        ], outputs: ["best"])[0].int64s
        let tOut = best.count / rows.count
        var out: [String] = []
        for (i, row) in rows.enumerated() {
            var phonemes = ""
            var prev: Int64 = 0
            for k in best[(i * tOut) ..< (i * tOut + tOut)].prefix(3 * row.count) {
                if k != prev && k != 0 { phonemes.append(outs[Int(k)]) }
                prev = k
            }
            out.append(phonemes)
        }
        return out
    }

    /// Phonemes for each (word, letter before, letter after): the word list first, then the model.
    func words(lang: String, items: [(word: String, before: String, after: String)]) throws -> [String] {
        let lex = lexicon[lang] ?? Lexicon(words: [:], contexts: [:])
        var out: [String?] = items.map { lex.contexts["\($0.word)\t\($0.before)\t\($0.after)"] ?? lex.words[$0.word] }
        let todo = out.indices.filter { out[$0] == nil }
        let filled = try model(todo.map { (lang: lang, before: items[$0].before, word: items[$0].word, after: items[$0].after) })
        for (i, p) in zip(todo, filled) { out[i] = p }
        return out.map { $0! }
    }

    // MARK: - Numbers

    /// The phonemes eSpeak would say for a number, put together from the language's number pieces.
    /// `before` is the letter or sound before the number ("#" after a pause); Spanish b, d and g
    /// soften after a vowel, so the pieces of a Spanish number soften against each other.
    func number(_ n: Int, lang: String, before: String = "#") -> String {
        let table = numbers[lang] ?? [:]
        var parts: [String]
        switch lang {
        case "hi": parts = Self.hindi(n, table)
        case "fr": parts = Self.french(n, table)
        default: parts = Self.spanish(n, table)
        }
        if lang == "es" {
            var soft: [String] = []
            for (k, p) in parts.enumerated() {
                let beforeK = k == 0 ? before : scalarString([soft[soft.count - 1].unicodeScalars.last!])
                soft.append(Self.soften(p, before: beforeK))
            }
            parts = soft
        }
        return parts.joined(separator: " ")
    }

    private static func unstress(_ s: String) -> String {
        scalarString(s.unicodeScalars.filter { $0 != "ˈ" && $0 != "ˌ" })
    }

    private static func hindi(_ n: Int, _ t: [String: String]) -> [String] {
        if n < 100 { return [t[String(n)]!] }
        var n = n, out: [String] = []
        for (div, name) in [(10_000_000, "crore"), (100_000, "lakh"), (1000, "thousand")] {
            if n >= div {
                out += hindi(n / div, t) + [t[name]!]
                n %= div
            }
        }
        if n >= 100 {
            out.append(t[String(n / 100 * 100)]!)
            n %= 100
        }
        if n != 0 { out.append(t[String(n)]!) }
        return out
    }

    private static func french(_ n: Int, _ t: [String: String], top: Bool = true) -> [String] {
        var n = n, out: [String] = []
        for (div, one, many) in [(1_000_000_000, "milliard", "milliards"), (1_000_000, "million", "millions")] {
            if n >= div {
                let q = n / div
                out += (q == 1 ? ["œ̃"] : french(q, t, top: false)) + [t[q == 1 ? one : many]!]
                n %= div
            }
        }
        if n >= 1000 {
            let q = n / 1000
            out += (q == 1 ? [] : french(q, t, top: false)) + [t["thousand"]!]
            n %= 1000
        }
        if n >= 100 {
            out.append(t[String(n / 100 * 100)]!)
            n %= 100
        }
        if n != 0 || out.isEmpty { out.append(t[String(n)]!) }
        if top {   // French stresses only the last word of a number
            out = out.dropLast().map(unstress) + [out[out.count - 1]]
        }
        return out
    }

    private static func spanish(_ n: Int, _ t: [String: String]) -> [String] {
        var n = n, out: [String] = []
        if n >= 1_000_000 {
            let q = n / 1_000_000
            out += q == 1 ? [t["millón"]!] : spanish(q, t) + [t["millones"]!]
            n %= 1_000_000
        }
        if n >= 1000 {
            let q = n / 1000
            if q == 1 {
                out.append(t["thousand"]!)
            } else {
                var p = spanish(q, t)
                if q % 10 == 1 && q % 100 != 11 && p[p.count - 1].hasSuffix("o") {   // veintiuno mil -> veintiún mil
                    p[p.count - 1] = scalarString(p[p.count - 1].unicodeScalars.dropLast())
                }
                out += p + [t["thousand"]!]
            }
            n %= 1000
        }
        if n >= 100 {
            let h = n / 100 * 100
            n %= 100
            out.append(h == 100 && n != 0 ? t["100+"]! : t[String(h)]!)
        }
        if n != 0 || out.isEmpty { out.append(t[String(n)]!) }
        return out
    }

    /// Spanish b, d and g are said β, ð and ɣ after a vowel and most consonants (also across words),
    /// as eSpeak writes them. `before` is the sound or letter before, "#" after a pause.
    private static func soften(_ p: String, before: String) -> String {
        let s = Array(p.unicodeScalars)
        var i = 0
        while i < s.count && (s[i] == "ˈ" || s[i] == "ˌ") { i += 1 }
        guard i < s.count, let soft = soft[s[i]], !"#nmɲŋ".contains(before), !(s[i] == "d" && before == "l") else {
            return p
        }
        var out = s
        out[i] = soft
        return scalarString(out)
    }

    // MARK: - Text -> phonemes

    /// One sentence of Hindi ("hi"), French ("fr") or Spanish ("es") -> phonemes, one space between
    /// words, punctuation kept, like misaki's EspeakG2P.
    func g2p(_ text: String, lang: String) throws -> String {
        var s = Array(text.unicodeScalars)
        for (i, c) in s.enumerated() { if let d = Self.devanagariDigits[c] { s[i] = d } }
        let guillemetLeft: Unicode.Scalar = "“", guillemetRight: Unicode.Scalar = "”"
        s = s.map { $0 == "«" ? guillemetLeft : $0 == "»" ? guillemetRight : $0 }
        s.removeAll { Self.zeroWidth.contains($0) }
        s = Self.spaceAfterDanda(s)
        if lang == "fr" { s = Self.removeThousandsSeparators(s) }
        s = Self.expandPercent(s, lang: lang)

        let pieces = splitWhitespace(s)
        var parsed: [(core: [Unicode.Scalar]?, lead: Bool, trail: Bool)] = []
        for piece in pieces {
            let core = stripEdges(piece)
            if let core, core.contains(where: { isAlnum($0) }) {
                let i = indexOf(core, in: piece)!
                parsed.append((core, i > 0, i + core.count < piece.count))
            } else {
                parsed.append((nil, true, true))
            }
        }
        let ctx = Self.contexts(parsed)

        var jobs: [(word: String, before: String, after: String)] = []
        var plan: [(lead: String, ids: [(kind: String, value: String)]?, trail: String)] = []
        for k in pieces.indices {
            let piece = pieces[k]
            guard let core = parsed[k].core else {
                plan.append((scalarString(piece), nil, ""))
                continue
            }
            let i = indexOf(core, in: piece)!
            let lead = scalarString(Array(piece.prefix(i)))
            let trail = scalarString(Array(piece.dropFirst(i + core.count)))
            var parts: [(kind: String, text: [Unicode.Scalar])] = []
            for run in digitRuns(core) {
                if run.allSatisfy(isDecimalDigit) {
                    parts.append(("number", run))
                } else {
                    let stripped = strip(run, of: ["-", ".", ",", "/", ":"])
                    if stripped.contains(where: { isAlnum($0) }) {
                        parts.append(("word", stripped))
                    }
                }
            }
            let firstText = scalarString(parts[0].text)
            let lastText = scalarString(parts[parts.count - 1].text)
            var ids: [(kind: String, value: String)] = []
            for part in parts {
                let text = scalarString(part.text)
                let first = text == firstText, last = text == lastText
                if part.kind == "number" {
                    if part.text.count < 10 {
                        ids.append(("text", number(intValue(part.text), lang: lang, before: first ? ctx[k]!.before : "#")))
                    } else {   // a long string of digits is read digit by digit
                        ids.append(("text", part.text.map { number(intValue([$0]), lang: lang) }.joined(separator: " ")))
                    }
                } else {
                    let w = text
                    jobs.append((w, first ? ctx[k]!.before : "#", last ? ctx[k]!.after : "#"))
                    ids.append(("job", String(jobs.count - 1)))
                }
            }
            plan.append((lead, ids, trail))
        }
        let res = try words(lang: lang, items: jobs)
        var out: [String] = []
        for (lead, ids, trail) in plan {
            if let ids {
                out.append(lead + ids.map { $0.kind == "text" ? $0.value : res[Int($0.value)!] }.joined(separator: " ") + trail)
            } else {
                out.append(lead)
            }
        }
        return out.joined(separator: " ").replacingOccurrences(of: "-", with: "")
    }

    // MARK: - The fallback for misaki's English G2P

    /// For the English G2P (Phase 2): phonemes for the English words misaki has no entry for, in place
    /// of misaki's EspeakFallback.
    func englishFallback(british: Bool, digitReader: @escaping (String) -> String) -> EnglishFallback {
        EnglishFallback(g2p: self, british: british, digitReader: digitReader)
    }

    // MARK: - Scalar helpers (Python str semantics on code points)

    /// A space after each Hindi danda (। and ॥) that touches the next word.
    private static func spaceAfterDanda(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        for (i, c) in s.enumerated() {
            out.append(c)
            if (c == "।" || c == "॥"), i + 1 < s.count, !s[i + 1].properties.isWhitespace {
                out.append(" ")
            }
        }
        return out
    }

    /// French writes "12 000" for one number; drop the single space, NBSP or NNBSP between digit groups
    /// of three. One left-to-right pass, as `re.sub` does.
    private static func removeThousandsSeparators(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            let isSpace = c == " " || c == "\u{00A0}" || c == "\u{202F}"
            if isSpace, i > 0, i + 4 <= s.count, isDecimalDigit(s[i - 1]),
               isDecimalDigit(s[i + 1]), isDecimalDigit(s[i + 2]), isDecimalDigit(s[i + 3]),
               (i + 4 == s.count || !isWordScalar(s[i + 4])) {
                i += 1   // remove the separator
            } else {
                out.append(c); i += 1
            }
        }
        return out
    }

    /// `(\d)\s?%` -> the digit, a space and the language's "percent": "50%" -> "50 pour cent".
    private static func expandPercent(_ s: [Unicode.Scalar], lang: String) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < s.count {
            if isDecimalDigit(s[i]) {
                if i + 1 < s.count, s[i + 1] == "%" {
                    out.append(s[i]); out.append(" ")
                    out.append(contentsOf: percent[lang]!.unicodeScalars)
                    i += 2
                    continue
                }
                if i + 2 < s.count, s[i + 1].properties.isWhitespace, s[i + 2] == "%" {
                    out.append(s[i]); out.append(" ")
                    out.append(contentsOf: percent[lang]!.unicodeScalars)
                    i += 3
                    continue
                }
            }
            out.append(s[i]); i += 1
        }
        return out
    }

    /// The last letter of the word before and the first letter of the word after, lowercased, or "#"
    /// when punctuation or the end of the sentence is in between.
    private static func contexts(_ words: [(core: [Unicode.Scalar]?, lead: Bool, trail: Bool)])
        -> [(before: String, after: String)?] {
        var out: [(before: String, after: String)?] = []
        for (i, w) in words.enumerated() {
            guard w.core != nil else { out.append(nil); continue }
            let before: String
            if i == 0 || w.lead || words[i - 1].core == nil || words[i - 1].trail {
                before = "#"
            } else {
                before = scalarString([words[i - 1].core!.last!]).lowercased()
            }
            let after: String
            if i == words.count - 1 || w.trail || words[i + 1].core == nil || words[i + 1].lead {
                after = "#"
            } else {
                after = scalarString([words[i + 1].core!.first!]).lowercased()
            }
            out.append((before, after))
        }
        return out
    }
}

// MARK: - Free scalar helpers, shared with EnglishFallback. Python indexes strings by code point and
// classes characters by Unicode category; Swift's Character is a grapheme cluster, so these work on
// unicodeScalars.

func scalarString(_ s: some Sequence<Unicode.Scalar>) -> String {
    var out = ""
    out.unicodeScalars.append(contentsOf: s)
    return out
}

func isDecimalDigit(_ s: Unicode.Scalar) -> Bool {
    s.properties.numericType == .decimal
}

/// Python's `isalnum()`: any Unicode letter or number.
fileprivate func isAlnum(_ s: Unicode.Scalar) -> Bool {
    switch s.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
         .decimalNumber, .letterNumber, .otherNumber: return true
    default: return false
    }
}

/// Python's `_is_edge`: punctuation, symbols, separators and zero-width characters, trimmed off the
/// ends of a word.
fileprivate func isEdge(_ s: Unicode.Scalar) -> Bool {
    if ParadeeG2P.zeroWidth.contains(s) { return true }
    switch s.properties.generalCategory {
    case .openPunctuation, .closePunctuation, .connectorPunctuation, .dashPunctuation,
         .initialPunctuation, .finalPunctuation, .otherPunctuation,
         .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
         .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
    default: return false
    }
}

/// The piece with punctuation, symbols, separators and zero-width characters trimmed off both ends.
fileprivate func stripEdges(_ w: [Unicode.Scalar]) -> [Unicode.Scalar]? {
    var i = 0, j = w.count
    while i < j && isEdge(w[i]) { i += 1 }
    while j > i && isEdge(w[j - 1]) { j -= 1 }
    return i < j ? Array(w[i ..< j]) : nil
}

fileprivate func indexOf(_ core: [Unicode.Scalar], in piece: [Unicode.Scalar]) -> Int? {
    guard core.count <= piece.count else { return nil }
    for i in 0 ... piece.count - core.count where Array(piece[i ..< i + core.count]) == core { return i }
    return nil
}

/// Python's `str.split()`: whitespace-separated pieces, leading/trailing runs dropped.
fileprivate func splitWhitespace(_ s: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
    var out: [[Unicode.Scalar]] = []
    var current: [Unicode.Scalar] = []
    for c in s {
        if c.properties.isWhitespace {
            if !current.isEmpty { out.append(current); current = [] }
        } else {
            current.append(c)
        }
    }
    if !current.isEmpty { out.append(current) }
    return out
}

/// `\d+|[^\d]+` runs, as Python's `re.findall` splits a word's core.
fileprivate func digitRuns(_ s: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
    var out: [[Unicode.Scalar]] = []
    var current: [Unicode.Scalar] = []
    var inDigits: Bool?
    for c in s {
        let d = isDecimalDigit(c)
        if inDigits == nil || inDigits == d { current.append(c) } else { out.append(current); current = [c] }
        inDigits = d
    }
    if !current.isEmpty { out.append(current) }
    return out
}

fileprivate func strip(_ s: [Unicode.Scalar], of chars: [Unicode.Scalar]) -> [Unicode.Scalar] {
    var i = 0, j = s.count
    while i < j && chars.contains(s[i]) { i += 1 }
    while j > i && chars.contains(s[j - 1]) { j -= 1 }
    return Array(s[i ..< j])
}

/// Python's `int()` on the decimal digits of any script.
fileprivate func intValue(_ s: [Unicode.Scalar]) -> Int {
    s.reduce(0) { $0 * 10 + Int($1.properties.numericValue!) }
}

/// Python's `\b` after `\d{3}`: the character after the group is not a word character.
fileprivate func isWordScalar(_ s: Unicode.Scalar) -> Bool {
    s == "_" || isAlnum(s)
}

/// Port of `paradee/g2p.py`'s `_EnglishFallback`, in place of misaki's EspeakFallback: phonemes for the
/// English words misaki has no entry for. Like eSpeak it keeps the punctuation around the word
/// ("St." -> "sənt."). Digit pieces ("22:", "Se8") are read by misaki itself; `digitReader` is the
/// Phase 2 misaki port, handed in so this file needs no English G2P of its own yet.
final class EnglishFallback {
    private let g2p: ParadeeG2P
    private let lang: String   // "en-us" | "en-gb"
    private let words: [String: String]
    private let digitReader: (String) -> String

    init(g2p: ParadeeG2P, british: Bool, digitReader: @escaping (String) -> String) {
        self.g2p = g2p
        lang = british ? "en-gb" : "en-us"
        words = g2p.lexicon[lang]?.words ?? [:]
        self.digitReader = digitReader
    }

    func phonemes(for tokenText: String) throws -> (phonemes: String, rating: Int) {
        var out: [String] = []
        for piece in splitWhitespace(Array(tokenText.unicodeScalars)) {
            let core = stripEdges(piece)
            guard let core, core.contains(where: { isAlnum($0) }) else { continue }
            let i = indexOf(core, in: piece)!
            var said: [String] = []
            for part in digitRuns(core) {
                if part.allSatisfy(isDecimalDigit) {
                    said.append(digitReader(scalarString(part)))
                } else {
                    let stripped = strip(part, of: ["-", ".", ",", "/", ":", "'"])
                    if stripped.contains(where: { isAlnum($0) }) {
                        let w = scalarString(stripped)
                        if let said0 = words[w] {
                            said.append(said0)
                        } else {
                            said.append(try g2p.model([(lang, "#", w, "#")])[0])
                        }
                    }
                }
            }
            out.append(scalarString(Array(piece.prefix(i))) + said.joined(separator: " ")
                + scalarString(Array(piece.dropFirst(i + core.count))))
        }
        return (out.joined(separator: " "), 2)
    }
}
