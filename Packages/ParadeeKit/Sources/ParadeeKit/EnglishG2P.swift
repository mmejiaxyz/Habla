import Foundation

/// A Swift port of `misaki/en.py` (English G2P: Lexicon + G2P — spaCy is replaced, per measurement
/// (b), by `EnglishTokenizer` with Apple's NaturalLanguage) and of misaki's `MToken`.
///
/// Like ParadeeG2P, all string work is on `unicodeScalars` (Python indexes code points), and the
/// phoneme strings use misaki's symbols ("T" is the US flap the final replacement writes).
final class EnglishToken {
    var text: String
    var tag: String
    var whitespace: String
    var phonemes: String?
    var isHead: Bool
    var alias: String?
    var stress: Double?
    var currency: String?
    var numFlags: String
    var prespace: Bool
    var rating: Int?

    init(text: String, tag: String, whitespace: String, phonemes: String? = nil,
         isHead: Bool = true, alias: String? = nil, stress: Double? = nil, currency: String? = nil,
         numFlags: String = "", prespace: Bool = false, rating: Int? = nil) {
        self.text = text; self.tag = tag; self.whitespace = whitespace; self.phonemes = phonemes
        self.isHead = isHead; self.alias = alias; self.stress = stress; self.currency = currency
        self.numFlags = numFlags; self.prespace = prespace; self.rating = rating
    }

    /// A copy with some fields changed, as `dataclasses.replace` does.
    func replaced(text: String? = nil, tag: String? = nil, whitespace: String? = nil,
                  isHead: Bool? = nil, stress: Double? = nil, numFlags: String? = nil,
                  prespace: Bool? = nil) -> EnglishToken {
        EnglishToken(text: text ?? self.text, tag: tag ?? self.tag,
                     whitespace: whitespace ?? self.whitespace, phonemes: self.phonemes,
                     isHead: isHead ?? self.isHead, alias: self.alias, stress: stress ?? self.stress,
                     currency: self.currency, numFlags: numFlags ?? self.numFlags,
                     prespace: prespace ?? self.prespace, rating: self.rating)
    }
}

// MARK: - Shared tables (misaki/en.py module constants)

enum EnglishTables {
    static let diphthongs: Set<Unicode.Scalar> = Set("AIOQWYʤʧ".unicodeScalars)
    static let subtokenJunks: Set<Unicode.Scalar> = Set("',-._‘’/".unicodeScalars)
    static let puncts: Set<Unicode.Scalar> = Set(";:,.!?—…\"“”".unicodeScalars)
    static let nonQuotePuncts: Set<Unicode.Scalar> = Set(";:,.!?—…".unicodeScalars)
    static let punctTags: Set<String> = [".", ",", "-LRB-", "-RRB-", "``", "\"\"", "''", ":", "$", "#", "NFP"]
    static let punctTagPhonemes: [String: String] = ["-LRB-": "(", "-RRB-": ")", "``": "“", "\"\"": "”", "''": "”"]
    static let lexiconOrds: Set<Int> = Set([39, 45] + Array(65...90) + Array(97...122))
    static let consonants: Set<Unicode.Scalar> = Set("bdfhjklmnpstvwzðŋɡɹɾʃʒʤʧθ".unicodeScalars)
    static let usTaus: Set<Unicode.Scalar> = Set("AIOWYiuæɑəɛɪɹʊʌ".unicodeScalars)
    static let currencies: [String: (String, String)] = ["$": ("dollar", "cent"), "£": ("pound", "pence"), "€": ("euro", "cent")]
    static let ordinals: Set<String> = ["st", "nd", "rd", "th"]
    static let addSymbols: [String: String] = [".": "dot", "/": "slash"]
    static let symbols: [String: String] = ["%": "percent", "&": "and", "+": "plus", "@": "at"]
    static let vowels: Set<Unicode.Scalar> = Set("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ".unicodeScalars)
    static let primary: Unicode.Scalar = "ˈ"
    static let secondary: Unicode.Scalar = "ˌ"
    static let stresses: Set<Unicode.Scalar> = ["ˈ", "ˌ"]
}

// MARK: - Stress

/// misaki's `apply_stress`: moves and swaps stress marks per the English compound/emphasis rules.
func applyStress(_ ps: String, _ stress: Double?) -> String {
    func restress(_ ps: String) -> String {
        let scalars = Array(ps.unicodeScalars)
        var items: [(Double, Unicode.Scalar)] = scalars.enumerated().map { (Double($0.offset), $0.element) }
        for (i, item) in items.enumerated() where EnglishTables.stresses.contains(item.1) {
            if let j = items[i...].first(where: { EnglishTables.vowels.contains($0.1) })?.0 {
                items[i].0 = j - 0.5   // 0.5 sorts just before the vowel's own index
            }
        }
        items.sort { $0.0 < $1.0 }
        return scalarString(items.map(\.1))
    }
    let scalars = Array(ps.unicodeScalars)
    let hasPrimary = scalars.contains(EnglishTables.primary)
    let hasSecondary = scalars.contains(EnglishTables.secondary)
    let noMarks = !hasPrimary && !hasSecondary
    let hasVowel = scalars.contains { EnglishTables.vowels.contains($0) }
    guard let stress else { return ps }
    if stress < -1 {
        return scalarString(scalars.filter { !EnglishTables.stresses.contains($0) })
    } else if stress == -1 || ((stress == 0 || stress == -0.5) && hasPrimary) {
        return scalarString(scalars.filter { $0 != EnglishTables.secondary }
            .map { $0 == EnglishTables.primary ? EnglishTables.secondary : $0 })
    } else if (stress == 0 || stress == 0.5 || stress == 1) && noMarks {
        return hasVowel ? restress(scalarString([EnglishTables.secondary] + scalars)) : ps
    } else if stress >= 1 && !hasPrimary && hasSecondary {
        return scalarString(scalars.map { $0 == EnglishTables.secondary ? EnglishTables.primary : $0 })
    } else if stress > 1 && noMarks {
        return hasVowel ? restress(scalarString([EnglishTables.primary] + scalars)) : ps
    }
    return ps
}

func stressWeight(_ ps: String) -> Int {
    ps.unicodeScalars.reduce(0) { $0 + (EnglishTables.diphthongs.contains($1) ? 2 : 1) }
}

// MARK: - Merging

/// misaki's `merge_tokens`: one token out of a clitic group, so the lexicon sees whole words.
func mergeTokens(_ tokens: [EnglishToken], unk: String? = nil) -> EnglishToken {
    let stress = Set(tokens.compactMap(\.stress))
    let currency = Set(tokens.compactMap(\.currency))
    let ratings = tokens.compactMap(\.rating)
    let phonemes: String?
    if let unk {
        var out = ""
        for tk in tokens {
            // Python checks `tk.phonemes` truthiness: an empty phoneme string adds no space.
            if tk.prespace && !out.isEmpty && !out.unicodeScalars.last!.properties.isWhitespace
                && !(tk.phonemes ?? "").isEmpty {
                out.append(" ")
            }
            out += tk.phonemes ?? unk
        }
        phonemes = out
    } else {
        phonemes = nil
    }
    let text = tokens.dropLast().map { $0.text + $0.whitespace }.joined() + (tokens.last?.text ?? "")
    // The tag of the most-capitalized token, as Python's max(..., key=uppercase count) picks it.
    func caps(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + (String($1) == String($1).lowercased() ? 1 : 2) }
    }
    let tag = tokens.max { caps($0.text) < caps($1.text) }?.tag ?? ""
    return EnglishToken(text: text, tag: tag, whitespace: tokens.last?.whitespace ?? "", phonemes: phonemes,
                        isHead: tokens.first?.isHead ?? true, alias: nil,
                        stress: stress.count == 1 ? stress.first : nil,
                        currency: currency.max(),
                        numFlags: scalarString(Set(tokens.flatMap { $0.numFlags.unicodeScalars }).sorted()),
                        prespace: tokens.first?.prespace ?? false,
                        rating: tokens.count == ratings.count ? ratings.min() : nil)
}

/// misaki's `token_context`: what the next word to the left needs to know about this word.
struct EnglishTokenContext {
    var futureVowel: Bool?
    var futureTo: Bool = false
}

func englishTokenContext(_ ctx: EnglishTokenContext, _ ps: String?, _ token: EnglishToken) -> EnglishTokenContext {
    var vowel = ctx.futureVowel
    if let ps {
        for c in ps.unicodeScalars
        where EnglishTables.vowels.contains(c) || EnglishTables.consonants.contains(c) || EnglishTables.nonQuotePuncts.contains(c) {
            vowel = EnglishTables.nonQuotePuncts.contains(c) ? nil : EnglishTables.vowels.contains(c)
            break
        }
    }
    let futureTo = token.text == "to" || token.text == "To" || (token.text == "TO" && (token.tag == "TO" || token.tag == "IN"))
    return EnglishTokenContext(futureVowel: vowel, futureTo: futureTo)
}

// MARK: - Subtokenizing

private let subtokenRegex = try! NSRegularExpression(
    pattern: "^['‘’]+|\\p{Lu}(?=\\p{Lu}\\p{Ll})|(?:^-)?(?:\\d?[,.]?\\d)+|[-_]+|['‘’]{2,}|\\p{L}*?(?:['‘’]\\p{L})*?\\p{Ll}(?=\\p{Lu})|\\p{L}+(?:['‘’]\\p{L})*|[^-_\\p{L}'‘’\\d]|['‘’]+$")

/// misaki's `subtokenize` (the `regex` module pattern; ICU-compatible): how a token splits into clitics.
func subtokenize(_ word: String) -> [String] {
    let ns = NSRange(word.startIndex..., in: word)
    return subtokenRegex.matches(in: word, range: ns).map { (word as NSString).substring(with: $0.range) }
}

// MARK: - The lexicon

/// misaki's `Lexicon`: the gold and silver word lists, and the word-building rules around them.
final class EnglishLexicon {
    let british: Bool
    let capStresses: (Double, Double) = (0.5, 2)
    private let golds: [String: LexValue]
    private let silvers: [String: LexValue]

    enum LexValue {
        case phonemes(String)
        case byTag([String: String?])
    }

    init(british: Bool, goldURL: URL, silverURL: URL) throws {
        self.british = british
        golds = Self.grow(Self.load(goldURL))
        silvers = Self.grow(Self.load(silverURL))
    }

    private static func load(_ url: URL) -> [String: LexValue] {
        let data = try! Gzip.gunzip(try! Data(contentsOf: url))
        let raw = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        var out: [String: LexValue] = [:]
        for (k, v) in raw {
            if let s = v as? String {
                out[k] = .phonemes(s)
            } else if let d = v as? [String: Any] {
                var tags: [String: String?] = [:]
                for (t, p) in d { tags[t] = p as? String }
                out[k] = .byTag(tags)
            }
        }
        return out
    }

    /// misaki's `grow_dictionary`: capitalized and lowercase twins share each entry. Python's
    /// `str.capitalize()` uppercases only the first letter (Swift's `capitalized` also capitalizes
    /// after hyphens, so "X-ray" would not get its "x-ray" twin).
    private static func grow(_ d: [String: LexValue]) -> [String: LexValue] {
        func pyCapitalize(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst().lowercased() }
        var e: [String: LexValue] = [:]
        for (k, v) in d {
            if k.count < 2 { continue }
            if k == k.lowercased() {
                let cap = pyCapitalize(k)
                if k != cap { e[cap] = v }
            } else if k == pyCapitalize(k) {
                e[k.lowercased()] = v
            }
        }
        for (k, v) in d { e[k] = v }
        return e
    }

    private func goldsValue(_ key: String) -> LexValue? { golds[key] }

    /// Spells an acronym letter by letter ("USA" -> "ˈAˈɛsˈA" without interior breaks), misaki's `get_NNP`.
    func getNNP(_ word: String) -> (String?, Int?) {
        var out: [String] = []
        for c in word.unicodeScalars where c.properties.isAlphabetic {
            guard case .phonemes(let p)? = golds[String(c).uppercased()] else { return (nil, nil) }
            out.append(p)
        }
        var ps = applyStress(out.joined(), 0)
        if let last = ps.unicodeScalars.lastIndex(of: EnglishTables.secondary) {
            let a = scalarString(ps.unicodeScalars[..<last])
            let b = scalarString(ps.unicodeScalars[ps.unicodeScalars.index(after: last)...])
            ps = a + String(EnglishTables.primary) + b
        }
        return (ps, 3)
    }

    /// misaki's `get_parent_tag`: fine Penn tags collapse onto the lexicon's coarse keys.
    static func parentTag(_ tag: String?) -> String? {
        guard let tag else { return nil }
        if tag.hasPrefix("VB") { return "VERB" }
        if tag.hasPrefix("NN") { return "NOUN" }
        if tag.hasPrefix("ADV") || tag.hasPrefix("RB") { return "ADV" }
        if tag.hasPrefix("ADJ") || tag.hasPrefix("JJ") { return "ADJ" }
        return tag
    }

    private func specialCase(_ word: String, _ tag: String, _ stress: Double?, _ ctx: EnglishTokenContext) -> (String?, Int?) {
        if tag == "ADD", let w = EnglishTables.addSymbols[word] {
            return lookup(w, nil, -0.5, ctx)
        } else if let w = EnglishTables.symbols[word] {
            return lookup(w, nil, nil, ctx)
        } else if word.contains("."), !word.hasPrefix("."), !word.hasSuffix("."),
                  word.replacingOccurrences(of: ".", with: "").unicodeScalars.allSatisfy({ $0.properties.isAlphabetic }),
                  (word.split(separator: ".").map(\.count).max() ?? 0) < 3 {
            return getNNP(word)
        } else if word == "a" || word == "A" {
            return (tag == "DT" ? "ɐ" : "ˈA", 4)
        } else if word == "am" || word == "Am" || word == "AM" {
            if tag.hasPrefix("NN") {
                return getNNP(word)
            } else if ctx.futureVowel == nil || word != "am" || (stress ?? 0) > 0 {
                if case .phonemes(let p)? = golds["am"] { return (p, 4) }
                return (nil, nil)
            }
            return ("ɐm", 4)
        } else if word == "an" || word == "An" || word == "AN" {
            if word == "AN" && tag.hasPrefix("NN") { return getNNP(word) }
            return ("ɐn", 4)
        } else if word == "I" && tag == "PRP" {
            return ("ˌI", 4)
        } else if (word == "by" || word == "By" || word == "BY") && Self.parentTag(tag) == "ADV" {
            return ("bˈI", 4)
        } else if word == "to" || word == "To" || (word == "TO" && (tag == "TO" || tag == "IN")) {
            let ps: String
            switch ctx.futureVowel {
            case nil: ps = { if case .phonemes(let p)? = golds["to"] { return p }; return "tə" }()
            case false?: ps = "tə"
            default: ps = "tʊ"
            }
            return (ps, 4)
        } else if word == "in" || word == "In" || (word == "IN" && tag != "NNP") {
            let mark = ctx.futureVowel == nil || tag != "IN" ? "ˈ" : ""
            return (mark + "ɪn", 4)
        } else if word == "the" || word == "The" || (word == "THE" && tag == "DT") {
            return (ctx.futureVowel == true ? "ði" : "ðə", 4)
        } else if tag == "IN" && (word.lowercased() == "vs" || word.lowercased() == "vs.") {
            return lookup("versus", nil, nil, ctx)
        } else if word == "used" || word == "Used" || word == "USED" {
            if (tag == "VBD" || tag == "JJ") && ctx.futureTo,
               case .byTag(let d)? = golds["used"], let p = d["VBD"] ?? nil {
                return (p, 4)
            }
            if case .phonemes(let p)? = golds["used"] { return (p, 4) }
            if case .byTag(let d)? = golds["used"] { return (d["DEFAULT"] ?? nil, 4) }
            return (nil, nil)
        }
        return (nil, nil)
    }

    /// misaki's `is_known`: would the word lists (or their rules) have an entry?
    func isKnown(_ word: String, _ tag: String) -> Bool {
        if golds[word] != nil || silvers[word] != nil || EnglishTables.symbols[word] != nil { return true }
        if !word.unicodeScalars.allSatisfy({ $0.properties.isAlphabetic })
            || !word.unicodeScalars.allSatisfy({ EnglishTables.lexiconOrds.contains(Int($0.value)) }) { return false }
        if word.count == 1 { return true }
        if word == word.uppercased(), golds[word.lowercased()] != nil { return true }
        return word.dropFirst() == word.dropFirst().uppercased()
    }

    /// misaki's `lookup`: the gold/silver entries, NNP spelling, then stress.
    func lookup(_ word: String, _ tag: String?, _ stress: Double?, _ ctx: EnglishTokenContext?) -> (String?, Int?) {
        var word = word
        var isNNP: Bool? = nil
        if word == word.uppercased(), golds[word] == nil {
            word = word.lowercased()
            isNNP = tag == "NNP"
        }
        var ps: String?
        var rating: Int? = 4
        var dict: [String: String?]? = nil
        if let v = golds[word] {
            if case .phonemes(let p) = v { ps = p } else if case .byTag(let d) = v { dict = d }
        } else if isNNP != true, let v = silvers[word] {
            rating = 3
            if case .phonemes(let p) = v { ps = p } else if case .byTag(let d) = v { dict = d }
        }
        if let dict {
            var t = tag
            if let ctx, ctx.futureVowel == nil, dict.keys.contains("None") {
                t = "None"
            } else if t == nil || !dict.keys.contains(t!) {
                t = Self.parentTag(t)
            }
            ps = t.flatMap { dict.keys.contains($0) ? dict[$0]! : nil } ?? dict["DEFAULT"] ?? nil
        }
        if ps == nil || (isNNP == true && !ps!.unicodeScalars.contains(EnglishTables.primary)) {
            let (nnp, r) = getNNP(word)
            if let nnp { return (nnp, r) }
        }
        guard let ps else { return (nil, rating) }
        return (applyStress(ps, stress), rating)
    }

    // MARK: Word-building (-s, -ed, -ing)

    func plural(_ stem: String) -> String? {
        guard let last = stem.unicodeScalars.last else { return nil }
        if "ptkfθ".unicodeScalars.contains(last) { return stem + "s" }
        if "szʃʒʧʤ".unicodeScalars.contains(last) { return stem + (british ? "ɪ" : "ᵻ") + "z" }
        return stem + "z"
    }

    func stemS(_ word: String, _ tag: String, _ stress: Double?, _ ctx: EnglishTokenContext?) -> (String?, Int?) {
        guard word.count >= 3, word.hasSuffix("s") else { return (nil, nil) }
        let stem: String
        if !word.hasSuffix("ss"), isKnown(String(word.dropLast()), tag) {
            stem = String(word.dropLast())
        } else if (word.hasSuffix("'s") || (word.count > 4 && word.hasSuffix("es") && !word.hasSuffix("ies")))
                    && isKnown(String(word.dropLast(2)), tag) {
            stem = String(word.dropLast(2))
        } else if word.count > 4 && word.hasSuffix("ies") && isKnown(String(word.dropLast(3)) + "y", tag) {
            stem = String(word.dropLast(3)) + "y"
        } else {
            return (nil, nil)
        }
        let (s, rating) = lookup(stem, tag, stress, ctx)
        guard let s else { return (nil, rating) }
        return (plural(s), rating)
    }

    func past(_ stem: String) -> String? {
        guard let last = stem.unicodeScalars.last else { return nil }
        if "pkfθʃsʧ".unicodeScalars.contains(last) { return stem + "t" }
        if last == "d" { return stem + (british ? "ɪ" : "ᵻ") + "d" }
        if last != "t" { return stem + "d" }
        if british || stem.count < 2 { return stem + "ɪd" }
        if let prev = stem.unicodeScalars.dropLast().last, EnglishTables.usTaus.contains(prev) {
            return String(stem.dropLast()) + "ɾᵻd"
        }
        return stem + "ᵻd"
    }

    func stemEd(_ word: String, _ tag: String, _ stress: Double?, _ ctx: EnglishTokenContext?) -> (String?, Int?) {
        guard word.count >= 4, word.hasSuffix("d") else { return (nil, nil) }
        let stem: String
        if !word.hasSuffix("dd"), isKnown(String(word.dropLast()), tag) {
            stem = String(word.dropLast())
        } else if word.count > 4 && word.hasSuffix("ed") && !word.hasSuffix("eed") && isKnown(String(word.dropLast(2)), tag) {
            stem = String(word.dropLast(2))
        } else {
            return (nil, nil)
        }
        let (s, rating) = lookup(stem, tag, stress, ctx)
        guard let s else { return (nil, rating) }
        return (past(s), rating)
    }

    func gerund(_ stem: String) -> String? {
        guard let last = stem.unicodeScalars.last else { return nil }
        if british {
            if "əː".unicodeScalars.contains(last) { return nil }
        } else if stem.count > 1, last == "t",
                  let prev = stem.unicodeScalars.dropLast().last, EnglishTables.usTaus.contains(prev) {
            return String(stem.dropLast()) + "ɾɪŋ"
        }
        return stem + "ɪŋ"
    }

    func stemIng(_ word: String, _ tag: String, _ stress: Double?, _ ctx: EnglishTokenContext?) -> (String?, Int?) {
        guard word.count >= 5, word.hasSuffix("ing") else { return (nil, nil) }
        let stem: String
        if word.count > 5, isKnown(String(word.dropLast(3)), tag) {
            stem = String(word.dropLast(3))
        } else if isKnown(String(word.dropLast(3)) + "e", tag) {
            stem = String(word.dropLast(3)) + "e"
        } else if word.count > 5, word.range(of: #"([bcdgklmnprstvxz])\1ing$|cking$"#, options: .regularExpression) != nil,
                  isKnown(String(word.dropLast(4)), tag) {
            stem = String(word.dropLast(4))
        } else {
            return (nil, nil)
        }
        let (s, rating) = lookup(stem, tag, stress, ctx)
        guard let s else { return (nil, rating) }
        return (gerund(s), rating)
    }

    // MARK: Word lookup

    /// misaki's `get_word`: special cases, capitalization, the word lists, then -s/-ed/-ing stems.
    func getWord(_ word: String, _ tag: String, _ stress: Double?, _ ctx: EnglishTokenContext) -> (String?, Int?) {
        let (ps, rating) = specialCase(word, tag, stress, ctx)
        if ps != nil { return (ps, rating) }
        var word = word
        let wl = word.lowercased()
        if word.count > 1, word.replacingOccurrences(of: "'", with: "").unicodeScalars.allSatisfy({ $0.properties.isAlphabetic }),
           word != word.lowercased(), (tag != "NNP" || word.count > 7), golds[word] == nil, silvers[word] == nil,
           (word == word.uppercased() || word.dropFirst() == word.dropFirst().lowercased()),
           (golds[wl] != nil || silvers[wl] != nil || stemS(wl, tag, stress, ctx).0 != nil
            || stemEd(wl, tag, stress, ctx).0 != nil || stemIng(wl, tag, stress, ctx).0 != nil) {
            word = wl
        }
        if isKnown(word, tag) {
            return lookup(word, tag, stress, ctx)
        } else if word.hasSuffix("s'"), isKnown(String(word.dropLast(2)) + "'s", tag) {
            return lookup(String(word.dropLast(2)) + "'s", tag, stress, ctx)
        } else if word.hasSuffix("'"), isKnown(String(word.dropLast()), tag) {
            return lookup(String(word.dropLast()), tag, stress, ctx)
        }
        let (s, r1) = stemS(word, tag, stress, ctx)
        if s != nil { return (s, r1) }
        let (ed, r2) = stemEd(word, tag, stress, ctx)
        if ed != nil { return (ed, r2) }
        let (ing, r3) = stemIng(word, tag, stress == nil ? 0.5 : stress, ctx)
        if ing != nil { return (ing, r3) }
        return (nil, nil)
    }

    // MARK: Numbers

    static func isCurrency(_ word: String) -> Bool {
        if !word.contains(".") { return true }
        if word.components(separatedBy: ".").count - 1 > 1 { return false }
        let cents = word.split(separator: ".")[1]
        return cents.count < 3 || Set(cents) == Set("0")
    }

    /// misaki's `get_number`: digits -> number words (num2words), then lexicon phonemes.
    func getNumber(_ word: String, _ currency: String?, _ isHead: Bool, _ numFlags: String) -> (String?, Int?) {
        var word = word
        let suffix = word.range(of: "[a-z']+$", options: .regularExpression).map { String(word[$0]) }
        if let suffix { word = String(word.dropLast(suffix.count)) }
        var result: [(String, Int)] = []
        if word.hasPrefix("-") {
            let (m, r) = lookup("minus", nil, nil, nil)
            result.append((m ?? "minus", r ?? 4))
            word = String(word.dropFirst())
        }
        func extendNum(_ num: String, first: Bool = true, escape: Bool = false) {
            let words: String
            if escape {
                words = num
            } else if let n = Int(num) {
                words = Num2Words.cardinal(n)
            } else {
                words = num   // beyond Int64: read the digits as given (unreachable in book text)
            }
            let splits = words.split { !("a"..."z").contains($0) }.map(String.init)
            for (i, w) in splits.enumerated() {
                if w != "and" || numFlags.contains("&") {
                    if first && i == 0 && splits.count > 1 && w == "one" && numFlags.contains("a") {
                        result.append(("ə", 4))
                    } else {
                        let (ps, r) = lookup(w, nil, w == "point" ? -2 : nil, nil)
                        result.append((ps ?? "", r ?? 4))
                    }
                } else if w == "and" && numFlags.contains("n") && !result.isEmpty {
                    result[result.count - 1] = (result[result.count - 1].0 + "ən", result[result.count - 1].1)
                }
            }
        }
        let allDigits = word.unicodeScalars.allSatisfy { isDecimalDigit($0) }
        let ordinalSuffix = suffix.map { EnglishTables.ordinals.contains($0) } ?? false
        if allDigits && ordinalSuffix, let n = Int(word) {
            extendNum(Num2Words.ordinal(n), escape: true)
        } else if result.isEmpty && word.count == 4 && !(currency.map { EnglishTables.currencies[$0] != nil } ?? false)
                    && allDigits, let n = Int(word) {
            extendNum(Num2Words.year(n), escape: true)
        } else if !isHead && !word.contains(".") {
            let num = word.replacingOccurrences(of: ",", with: "")
            if num.first == "0" || num.count > 3 {
                for d in num { extendNum(String(d), first: false) }
            } else if num.count == 3 && !num.hasSuffix("00") {
                extendNum(String(num.first!))
                if num.dropFirst().first == "0" {
                    let (o, r) = lookup("O", nil, -2, nil)
                    result.append((o ?? "", r ?? 4))
                    extendNum(String(num.dropFirst(2).first!), first: false)
                } else {
                    extendNum(String(num.dropFirst()), first: false)
                }
            } else {
                extendNum(num)
            }
        } else if word.components(separatedBy: ".").count - 1 > 1 || !isHead {
            var first = true
            for num in word.replacingOccurrences(of: ",", with: "").split(separator: ".") {
                if num.isEmpty {
                    // nothing, as in Python
                } else if num.first == "0" || (num.count != 2 && num.dropFirst().contains(where: { $0 != "0" })) {
                    for d in num { extendNum(String(d), first: false) }
                } else {
                    extendNum(String(num), first: first)
                }
                first = false
            }
        } else if currency.map({ EnglishTables.currencies[$0] != nil }) ?? false, Self.isCurrency(word) {
            var pairs: [(Int, String)] = []
            let units = EnglishTables.currencies[currency!]!
            for (i, num) in word.replacingOccurrences(of: ",", with: "").split(separator: ".").enumerated() {
                pairs.append((Int(num) ?? 0, i == 0 ? units.0 : units.1))
            }
            if pairs.count > 1 {
                if pairs[1].0 == 0 { pairs = Array(pairs.prefix(1)) }
                else if pairs[0].0 == 0 { pairs = Array(pairs.dropFirst()) }
            }
            for (i, pair) in pairs.enumerated() {
                if i > 0 {
                    let (a, r) = lookup("and", nil, nil, nil)
                    result.append((a ?? "", r ?? 4))
                }
                extendNum(String(pair.0), first: i == 0)
                if abs(pair.0) != 1 && pair.1 != "pence" {
                    let (u, r) = stemS(pair.1 + "s", "", nil, nil)
                    result.append((u ?? "", r ?? 4))
                } else {
                    let (u, r) = lookup(pair.1, nil, nil, nil)
                    result.append((u ?? "", r ?? 4))
                }
            }
        } else {
            var words: String
            if allDigits, let n = Int(word) {
                words = Num2Words.cardinal(n)
            } else if !word.contains(".") {
                let plain = word.replacingOccurrences(of: ",", with: "")
                if let n = Int(plain) {
                    words = ordinalSuffix ? Num2Words.ordinal(n) : Num2Words.cardinal(n)
                } else if plain.unicodeScalars.allSatisfy(isDecimalDigit) {
                    words = plain.map { Num2Words.cardinal(Int(String($0))!) }.joined(separator: " ")   // beyond Int64: digit by digit
                } else {
                    words = plain
                }
            } else {
                let w = word.replacingOccurrences(of: ",", with: "")
                if w.first == "." {
                    words = "point " + w.dropFirst().compactMap { Int(String($0)) }.map(Num2Words.cardinal).joined(separator: " ")
                } else {
                    words = Double(w).map(Num2Words.cardinal) ?? w
                }
            }
            extendNum(words, escape: true)
        }
        if result.isEmpty { return (nil, nil) }
        var ps = result.map(\.0).joined(separator: " ")
        let rating = result.map(\.1).min() ?? 4
        if suffix == "s" || suffix == "'s" {
            ps = plural(ps) ?? ps
        } else if suffix == "ed" || suffix == "'d" {
            ps = past(ps) ?? ps
        } else if suffix == "ing" {
            ps = gerund(ps) ?? ps
        }
        return (ps, rating)
    }

    func appendCurrency(_ ps: String, _ currency: String?) -> String {
        guard let currency, let pair = EnglishTables.currencies[currency] else { return ps }
        let (u, _) = stemS(pair.0 + "s", "", nil, nil)
        if let u { return "\(ps) \(u)" }
        return ps
    }

    /// misaki's `numeric_if_needed`: Unicode digits (incl. superscripts) become ASCII digits.
    static func numericIfNeeded(_ c: Unicode.Scalar) -> String {
        guard let n = c.properties.numericValue else { return String(c) }
        return n == n.rounded() ? String(Int(n)) : String(c)
    }

    static func isNumber(_ word: String, _ isHead: Bool) -> Bool {
        var word = word
        if word.unicodeScalars.allSatisfy({ !isDecimalDigit($0) }) { return false }
        for s in ["ing", "'d", "ed", "'s", "st", "nd", "rd", "th", "s"] where word.hasSuffix(s) {
            word = String(word.dropLast(s.count))
            break
        }
        return word.unicodeScalars.enumerated().allSatisfy { i, c in
            isDecimalDigit(c) || c == "," || c == "." || (isHead && i == 0 && c == "-")
        }
    }

    /// misaki's `Lexicon.__call__`: one token's phonemes, from the word lists or the number rules.
    func call(_ tk: EnglishToken, _ ctx: EnglishTokenContext) -> (String?, Int?) {
        var word = tk.alias ?? tk.text
        word = word.replacingOccurrences(of: "‘", with: "'").replacingOccurrences(of: "’", with: "'")
        word = word.precomposedStringWithCompatibilityMapping   // unicodedata.normalize('NFKC')
        word = word.unicodeScalars.map(Self.numericIfNeeded).joined()
        let stress: Double?
        if word == word.lowercased() {
            stress = nil
        } else {
            stress = word == word.uppercased() ? capStresses.1 : capStresses.0
        }
        let (ps, rating) = getWord(word, tk.tag, stress, ctx)
        if let ps {
            return (applyStress(appendCurrency(ps, tk.currency), tk.stress), rating)
        } else if Self.isNumber(word, tk.isHead) {
            let (n, r) = getNumber(word, tk.currency, tk.isHead, tk.numFlags)
            guard let n else { return (nil, r) }
            return (applyStress(n, tk.stress), r)
        } else if !word.unicodeScalars.allSatisfy({ EnglishTables.lexiconOrds.contains(Int($0.value)) }) {
            return (nil, nil)
        }
        return (nil, nil)
    }
}

// MARK: - The G2P

/// misaki's `en.G2P`: tokens -> phonemes, right to left, with Paradee's own G2P as the fallback
/// for the words misaki has no entry for. Feed Python's spaCy tokens for measurement (a); nil runs
/// the Apple-tagger tokenizer end to end for measurement (b).
final class EnglishG2P {
    let british: Bool
    let lexicon: EnglishLexicon
    let fallback: EnglishFallback
    let unk: String

    init(british: Bool, g2p: ParadeeG2P, unk: String = "") throws {
        self.british = british
        self.unk = unk
        let prefix = british ? "gb" : "us"
        let lex = try EnglishLexicon(british: british, goldURL: ParadeeResources.url("\(prefix)_gold.json.gz"),
                                     silverURL: ParadeeResources.url("\(prefix)_silver.json.gz"))
        lexicon = lex
        // The fallback reads digit pieces the way misaki's plain G2P does: one CD token at the head
        // of its fragment, so get_number takes the plain-cardinal path. (spaCy tags exactly "00"
        // as NFP, which misaki then reads as empty — "12:00" is "twelve", not "twelve zero".)
        fallback = g2p.englishFallback(british: british) { piece in
            piece == "00" ? "" : lex.getNumber(piece, nil, true, "").0 ?? ""
        }
    }

    /// A token exactly as Python's tokenize() builds it (text, Penn tag, whitespace).
    struct RawToken: Codable { var text: String; var tag: String; var ws: String }
    static func tokens(from raw: [RawToken]) -> [EnglishToken] {
        raw.map { EnglishToken(text: $0.text, tag: $0.tag, whitespace: $0.ws) }
    }

    /// `preprocess`: markdown links ([text](link)) keep only their text; the link part becomes a
    /// feature on the token where that text starts (stress, phonemes or number flags). Rare in
    /// books, present for faithfulness.
    enum Feature { case stress(Double), phonemes(String), numFlags(String) }

    static func preprocess(_ text: String) -> (text: String, features: [Int: Feature]) {
        var result = ""
        var features: [Int: Feature] = [:]
        var lastEnd = text.startIndex
        let pattern = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^\\)]*)\\)")
        for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text), let g1 = Range(m.range(at: 1), in: text),
                  let g2 = Range(m.range(at: 2), in: text) else { continue }
            result += text[lastEnd..<r.lowerBound]
            let offset = result.count
            let f = String(text[g2])
            let body = f.hasPrefix("-") || f.hasPrefix("+") ? String(f.dropFirst()) : f
            let feature: Feature?
            if body.unicodeScalars.allSatisfy(isDecimalDigit) {
                feature = .stress(Double(Int(body) ?? 0))
            } else if f == "0.5" || f == "+0.5" {
                feature = .stress(0.5)
            } else if f == "-0.5" {
                feature = .stress(-0.5)
            } else if f.count > 1, f.hasPrefix("/"), f.hasSuffix("/") {
                feature = .phonemes(String(f.dropFirst().dropLast()))
            } else if f.count > 1, f.hasPrefix("#"), f.hasSuffix("#") {
                feature = .numFlags(String(f.dropFirst().dropLast()))
            } else {
                feature = nil
            }
            result += text[g1]
            if let feature { features[offset] = feature }
            lastEnd = r.upperBound
        }
        if lastEnd < text.endIndex { result += text[lastEnd...] }
        return (String(result), features)
    }

    /// misaki's `fold_left`: joins tokens that lost their head; the pipeline's tokens are all heads,
    /// so this is identity in practice — kept for faithfulness.
    func foldLeft(_ tokens: [EnglishToken]) -> [EnglishToken] {
        var result: [EnglishToken] = []
        for tk in tokens {
            if !result.isEmpty && !tk.isHead {
                result[result.count - 1] = mergeTokens([result.removeLast(), tk], unk: unk)
            } else {
                result.append(tk)
            }
        }
        return result
    }

    /// misaki's `retokenize`: clitics, currency, punctuation and numbers into token groups.
    static func retokenize(_ tokens: [EnglishToken]) -> [Any] {
        var words: [Any] = []
        var currency: String? = nil
        for (i, token) in tokens.enumerated() {
            var tks: [EnglishToken]
            if token.alias == nil && token.phonemes == nil {
                tks = subtokenize(token.text).map {
                    token.replaced(text: $0, whitespace: "", isHead: true, stress: token.stress,
                                   numFlags: token.numFlags, prespace: false)
                }
                if !tks.isEmpty { tks[tks.count - 1].whitespace = token.whitespace }
            } else {
                tks = [token]
            }
            for (j, tk) in tks.enumerated() {
                if tk.alias != nil || tk.phonemes != nil {
                    // keep as is
                } else if tk.tag == "$", EnglishTables.currencies[tk.text] != nil {
                    currency = tk.text
                    tk.phonemes = ""
                    tk.rating = 4
                } else if tk.tag == ":", tk.text == "-" || tk.text == "–" {
                    tk.phonemes = "—"
                    tk.rating = 3
                } else if EnglishTables.punctTags.contains(tk.tag),
                          !tk.text.unicodeScalars.allSatisfy({ 97...122 ~= Int($0.value) }) {
                    tk.phonemes = EnglishTables.punctTagPhonemes[tk.tag]
                        ?? scalarString(tk.text.unicodeScalars.filter { EnglishTables.puncts.contains($0) })
                    tk.rating = 4
                } else if currency != nil {
                    if tk.tag != "CD" {
                        currency = nil
                    } else if j + 1 == tks.count && (i + 1 == tokens.count || tokens[i + 1].tag != "CD") {
                        tk.currency = currency
                    }
                } else if j > 0, j < tks.count - 1, tk.text == "2",
                          let p = tks[j - 1].text.unicodeScalars.last, let n = tks[j + 1].text.unicodeScalars.first,
                          p.properties.isAlphabetic && n.properties.isAlphabetic {
                    tk.alias = "to"
                }
                if tk.alias != nil || tk.phonemes != nil {
                    words.append(tk)
                } else if !words.isEmpty, let group = words[words.count - 1] as? [EnglishToken],
                          group.last?.whitespace == "" {
                    tk.isHead = false
                    var g = group
                    g.append(tk)
                    words[words.count - 1] = g
                } else {
                    words.append(tk.whitespace.isEmpty ? [tk] : tk)
                }
            }
        }
        return words.map { w in
            if let list = w as? [EnglishToken], list.count == 1 { return list[0] as Any }
            return w
        }
    }

    /// misaki's `resolve_tokens`: punctuation-only groups and compound destressing.
    static func resolveTokens(_ tokens: [EnglishToken]) {
        let text = tokens.dropLast().map { $0.text + $0.whitespace }.joined() + (tokens.last?.text ?? "")
        let kinds = Set(text.unicodeScalars.filter { !EnglishTables.subtokenJunks.contains($0) }.map { c -> Int in
            c.properties.isAlphabetic ? 0 : (isDecimalDigit(c) ? 1 : 2)
        })
        let prespace = text.contains(" ") || text.contains("/") || kinds.count > 1
        for (i, tk) in tokens.enumerated() {
            if tk.phonemes == nil {
                if i == tokens.count - 1, tk.text.count == 1,
                   let first = tk.text.unicodeScalars.first, EnglishTables.nonQuotePuncts.contains(first) {
                    tk.phonemes = tk.text
                    tk.rating = 3
                } else if tk.text.unicodeScalars.allSatisfy({ EnglishTables.subtokenJunks.contains($0) }) {
                    tk.phonemes = ""
                    tk.rating = 3
                }
            } else if i > 0 {
                tk.prespace = prespace
            }
        }
        if prespace { return }
        var indices: [(Bool, Int, Int)] = []
        for (i, tk) in tokens.enumerated() where !(tk.phonemes ?? "").isEmpty {
            indices.append((tk.phonemes!.unicodeScalars.contains(EnglishTables.primary), stressWeight(tk.phonemes!), i))
        }
        if indices.count == 2, tokens[indices[0].2].text.count == 1 {
            tokens[indices[1].2].phonemes = applyStress(tokens[indices[1].2].phonemes!, -0.5)
            return
        } else if indices.count < 2 || indices.filter(\.0).count <= (indices.count + 1) / 2 {
            return
        }
        let sorted = indices.sorted {
            if $0.0 != $1.0 { return !$0.0 && $1.0 }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.2 < $1.2
        }
        for (_, _, i) in sorted.prefix(indices.count / 2) {
            tokens[i].phonemes = applyStress(tokens[i].phonemes!, -0.5)
        }
    }

    /// misaki's `G2P.__call__`: the whole word-by-word pipeline, right to left, with the fallback
    /// for the words misaki has no entry for.
    func phonemize(_ text: String, tokens raw: [RawToken]? = nil) throws -> String {
        let (stripped, features) = Self.preprocess(text)
        var tokens: [EnglishToken]
        if let raw {
            tokens = Self.tokens(from: raw)
        } else {
            tokens = try EnglishTokenizer.tokenize(stripped)
        }
        // Features (markdown links) name a token by the offset of the link's text in the stripped
        // text; the tokens appear verbatim, so offsets match the tokenizer's.
        var offset = 0
        var byOffset: [Int: Int] = [:]   // token start offset -> index
        for (i, tk) in tokens.enumerated() {
            byOffset[offset] = i
            offset += tk.text.count + tk.whitespace.count
        }
        for (k, feature) in features {
            guard let j = byOffset[k] else { continue }
            switch feature {
            case .stress(let s): tokens[j].stress = s
            case .phonemes(let p): tokens[j].isHead = true; tokens[j].phonemes = p; tokens[j].rating = 5
            case .numFlags(let f): tokens[j].numFlags = f
            }
        }
        tokens = foldLeft(tokens)
        let groups = Self.retokenize(tokens)
        var ctx = EnglishTokenContext()
        for i in groups.indices.reversed() {
            if let tk = groups[i] as? EnglishToken {
                if tk.phonemes == nil {
                    (tk.phonemes, tk.rating) = lexicon.call(tk, ctx)
                }
                if tk.phonemes == nil {
                    (tk.phonemes, tk.rating) = try fallback.phonemes(for: tk.text)
                }
                ctx = englishTokenContext(ctx, tk.phonemes, tk)
                continue
            }
            var group = groups[i] as! [EnglishToken]
            var left = 0, right = group.count
            var shouldFallback = false
            while left < right {
                var tk: EnglishToken? = nil
                if !group[left..<right].contains(where: { $0.alias != nil || $0.phonemes != nil }) {
                    tk = mergeTokens(Array(group[left..<right]))
                }
                var ps: String?
                var rating: Int?
                if let tk { (ps, rating) = lexicon.call(tk, ctx) }
                if let ps {
                    group[left].phonemes = ps
                    group[left].rating = rating
                    for x in group[(left + 1)..<right] {
                        x.phonemes = ""
                        x.rating = rating
                    }
                    ctx = englishTokenContext(ctx, ps, tk!)
                    right = left
                    left = 0
                } else if left + 1 < right {
                    left += 1
                } else {
                    right -= 1
                    let tk = group[right]
                    if tk.phonemes == nil {
                        if tk.text.unicodeScalars.allSatisfy({ EnglishTables.subtokenJunks.contains($0) }) {
                            tk.phonemes = ""
                            tk.rating = 3
                        } else {
                            shouldFallback = true
                            break
                        }
                    }
                    left = 0
                }
            }
            if shouldFallback {
                let tk = mergeTokens(group)
                (group[0].phonemes, group[0].rating) = try fallback.phonemes(for: tk.text)
                for j in 1..<group.count {
                    group[j].phonemes = ""
                    group[j].rating = group[0].rating
                }
            } else {
                Self.resolveTokens(group)
            }
        }
        let merged: [EnglishToken] = groups.map { g in
            if let tk = g as? EnglishToken { return tk }
            return mergeTokens(g as! [EnglishToken], unk: unk)
        }
        for tk in merged {
            if let p = tk.phonemes, !p.isEmpty {
                tk.phonemes = p.replacingOccurrences(of: "ɾ", with: "T").replacingOccurrences(of: "ʔ", with: "t")
            }
        }
        if text.contains("1st") {
            for tk in merged {
            }
        }
        return merged.map { ($0.phonemes ?? unk) + $0.whitespace }.joined()
    }
}
