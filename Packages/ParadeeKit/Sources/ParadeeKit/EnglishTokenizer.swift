import Foundation
import NaturalLanguage

/// A spaCy-like English tokenizer built on Apple's NaturalLanguage, for measurement (b): the same
/// (text, Penn tag, whitespace) triples misaki reads from spaCy's en_core_web_sm. It splits
/// punctuation and contractions (n't, 's, 're, 've, 'll, 'd, 'm), and tags words with NLTagger's
/// lexical class + name type plus form rules. Fine verb tags exist in the lexicons only for
/// read/reread/used/wound, so those get context rules; everything else collapses to the lexicon's
/// coarse tags anyway.
enum EnglishTokenizer {
    private static let determiners: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "every", "each", "either", "neither",
        "some", "any", "no", "all", "both", "another", "such",
    ]
    private static let personal: Set<String> = [
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them", "ye", "thee", "thou",
    ]
    private static let whPronouns: Set<String> = ["who", "whom", "whoever", "whomever", "what", "whatever"]
    private static let whDeterminers: Set<String> = ["which", "whichever", "whose"]
    private static let possessives: Set<String> = [
        "my", "your", "his", "her", "its", "our", "their", "thy", "thine", "mine", "yours", "hers", "ours", "theirs",
    ]
    private static let modals: Set<String> = [
        "can", "could", "may", "might", "must", "shall", "should", "will", "would", "ought",
    ]
    private static let prepositions: Set<String> = [
        "of", "in", "on", "at", "by", "for", "with", "without", "from", "into", "onto", "over", "under",
        "through", "throughout", "between", "among", "amongst", "against", "during", "before", "after",
        "above", "below", "up", "down", "out", "off", "about", "around", "near", "until", "till", "since",
        "within", "upon", "per", "via", "versus", "than", "as", "like", "except", "despite", "beyond",
        "beneath", "beside", "besides", "toward", "towards", "past", "along", "across", "behind", "unto",
        "amid", "amidst", "inside", "outside",
    ]
    private static let conjunctions: Set<String> = [
        "and", "or", "but", "nor", "yet", "for", "so", "while", "whilst", "whereas", "because", "although",
        "though", "if", "unless", "whether", "lest",
    ]
    private static let interjections: Set<String> = [
        "oh", "ah", "hey", "hello", "hi", "hmm", "huh", "ooh", "aah", "wow", "alas", "hurrah", "hooray",
        "goodbye", "farewell", "yes", "please", "sorry", "thanks", "thank",
    ]
    private static let adverbs: Set<String> = [
        "not", "too", "very", "just", "only", "also", "here", "there", "now", "then", "never", "always",
        "often", "soon", "again", "still", "however", "therefore", "thus", "indeed", "quite", "rather",
        "almost", "nearly", "even", "especially", "perhaps", "maybe", "really", "suddenly", "together",
        "away", "back", "forward", "forth", "hence", "whence", "once", "twice", "thrice", "well",
    ]
    private static let abbreviations: Set<String> = [
        "Mr.", "Mrs.", "Ms.", "Dr.", "St.", "Jr.", "Sr.", "Prof.", "Rev.", "Capt.", "Col.", "Gen.", "Lt.",
        "Gov.", "Sen.", "Rep.", "No.", "Mt.", "Ft.", "etc.", "viz.", "cf.", "vs.", "approx.", "dept.", "est.",
        "vol.", "ch.", "p.", "pp.", "fig.", "al.", "inc.", "ltd.", "co.", "corp.", "jan.", "feb.", "mar.",
        "apr.", "jun.", "jul.", "aug.", "sep.", "sept.", "oct.", "nov.", "dec.", "a.m.", "p.m.",
    ]

    /// One spaCy-style token per whitespace chunk: punctuation and contractions split off, the last
    /// sub-token of each chunk carrying the chunk's trailing whitespace.
    static func tokenize(_ text: String) throws -> [EnglishToken] {
        var out: [EnglishToken] = []
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text

        // Chunks: whitespace-separated pieces, each with its UTF-16 offset and trailing whitespace.
        var chunks: [(piece: String, whitespace: String, offset: Int)] = []
        var utf16Offset = 0
        var i = text.startIndex
        while i < text.endIndex {
            let start = i
            while i < text.endIndex && !text[i].unicodeScalars.first!.properties.isWhitespace { i = text.index(after: i) }
            let piece = String(text[start..<i])
            let pieceEnd = i
            while i < text.endIndex && text[i].unicodeScalars.first!.properties.isWhitespace { i = text.index(after: i) }
            chunks.append((piece, String(text[pieceEnd..<i]), utf16Offset))
            utf16Offset += piece.utf16.count + text[pieceEnd..<i].utf16.count
        }

        var sentenceInitial = true
        var previous: EnglishToken? = nil
        for chunk in chunks {
            let sub = splitChunk(chunk.piece)
            for (si, s) in sub.enumerated() {
                let token = tag(s, at: chunk.offset + s.startOffset, in: text, tagger: tagger,
                                sentenceInitial: sentenceInitial && si == 0,
                                previous: si == 0 ? previous : out.last)
                token.whitespace = si == sub.count - 1 ? chunk.whitespace : ""
                out.append(token)
                previous = token
            }
            let lastPiece = sub.last?.text ?? chunk.piece
            let isSentenceEnd = !isAbbreviation(chunk.piece) && (lastPiece == "." || lastPiece == "!" || lastPiece == "?"
                || lastPiece == "…" || lastPiece == "”" || lastPiece == "’" || lastPiece == "\"" || lastPiece == "'")
            sentenceInitial = isSentenceEnd
        }
        fixUsedTo(out)
        return out
    }

    // MARK: - Splitting

    private struct Piece { var text: String; var startOffset: Int }

    /// Splits one whitespace chunk into spaCy-style tokens, keeping each token's UTF-16 offset in
    /// the original text (for NLTagger lookups).
    private static func splitChunk(_ chunk: String) -> [Piece] {
        if isAbbreviation(chunk) { return [Piece(text: chunk, startOffset: 0)] }
        var pieces: [Piece] = []
        var offset = 0
        let s = Array(chunk.unicodeScalars)
        var i = 0
        func append(_ scalars: ArraySlice<Unicode.Scalar>) {
            if !scalars.isEmpty { pieces.append(Piece(text: scalarString(scalars), startOffset: offset)) }
            offset += scalars.reduce(0) { $0 + String($1).utf16.count }
        }
        while i < s.count {
            let c = s[i]
            // Opening quotes, parens, currency: their own token.
            let openers: [Unicode.Scalar] = ["“", "‘", "`", "\"", "'", "(", "[", "{", "£", "€"]
            if openers.contains(c) {
                append(s[i..<i + 1])
                i += 1
                continue
            }
            // A run of letters/digits; dots, commas and colons join it only between digits ("3.5",
            // "5,000", "2:30"), and apostrophes always join ("o'clock", "5'3").
            var j = i
            while j < s.count {
                let d = s[j]
                if d.properties.isAlphabetic || isDecimalDigit(d) || d == "'" || d == "’" {
                    j += 1
                } else if (d == "." || d == "," || d == ":"), s[i..<j].contains(where: isDecimalDigit),
                          j + 1 < s.count, isDecimalDigit(s[j + 1]) {
                    j += 1
                } else {
                    break
                }
            }
            let word = Array(s[i..<j])
            // Contractions split: X n't / X 's / X 're / X 've / X 'll / X 'd / X 'm, and s' / '.
            if let split = contractionSplit(word) {
                append(s[i..<i + split])
                append(s[i + split..<j])
                i = j
                continue
            }
            append(s[i..<j])
            i = j
            if i >= s.count { break }
            // Dashes between words are their own tokens; the em/en dash too.
            if s[i] == "—" || s[i] == "–" {
                append(s[i..<i + 1])
                i += 1
                continue
            }
            if s[i] == "-", let prev = word.last, prev.properties.isAlphabetic,
               i + 1 < s.count, s[i + 1].properties.isAlphabetic {
                append(s[i..<i + 1])
                i += 1
                continue
            }
            // Closing quotes, sentence punctuation, and anything else: one-char tokens.
            append(s[i..<i + 1])
            i += 1
        }
        if pieces.isEmpty { pieces = [Piece(text: chunk, startOffset: 0)] }
        return pieces
    }

    /// The prefix length for a contraction ("don't" -> 2, "dogs'" -> 4), nil when the word stays whole.
    private static func contractionSplit(_ w: [Unicode.Scalar]) -> Int? {
        func hasSuffix(_ suffix: String) -> Bool {
            let suf = Array(suffix.unicodeScalars)
            return w.count > suf.count && Array(w[(w.count - suf.count)...]) == suf
        }
        if hasSuffix("n't"), w.count > 3 { return w.count - 3 }
        if hasSuffix("'s") || hasSuffix("’s"), w.count > 2 { return w.count - 2 }
        if hasSuffix("s'") || hasSuffix("s’"), w.count > 2 { return w.count - 1 }
        if hasSuffix("'re") || hasSuffix("'ve") || hasSuffix("'ll") || hasSuffix("'d") || hasSuffix("'m") || hasSuffix("'em"),
           w.count > 3 { return w.count - 3 }
        if hasSuffix("'") || hasSuffix("’"), w.count > 1 { return w.count - 1 }
        return nil
    }

    /// Chunks the tokenizer keeps whole: common abbreviations, initials, dotted acronyms.
    private static func isAbbreviation(_ chunk: String) -> Bool {
        if abbreviations.contains(chunk) || abbreviations.contains(chunk.lowercased()) { return true }
        if chunk.range(of: #"^([A-Za-z]\.)+$"#, options: .regularExpression) != nil { return true }
        return false
    }

    // MARK: - Tagging

    private static func tag(_ piece: Piece, at offset: Int, in text: String, tagger: NLTagger,
                            sentenceInitial: Bool, previous: EnglishToken?) -> EnglishToken {
        let t = piece.text
        let index = String.Index(utf16Offset: offset, in: text)
        let taggerClass: NLTag? = offset < text.utf16.count
            ? tagger.tag(at: index, unit: .word, scheme: .lexicalClass).0 : nil
        let nameType: NLTag? = offset < text.utf16.count
            ? tagger.tag(at: index, unit: .word, scheme: .nameType).0 : nil
        let lowered = t.lowercased()

        // Punctuation first.
        switch t {
        case ".", "!", "?": return EnglishToken(text: t, tag: ".", whitespace: "")
        case ",": return EnglishToken(text: t, tag: ",", whitespace: "")
        case ";", ":": return EnglishToken(text: t, tag: ":", whitespace: "")
        case "(": return EnglishToken(text: t, tag: "-LRB-", whitespace: "")
        case ")": return EnglishToken(text: t, tag: "-RRB-", whitespace: "")
        case "“", "‘", "`": return EnglishToken(text: t, tag: "``", whitespace: "")
        case "”", "’": return EnglishToken(text: t, tag: "''", whitespace: "")
        case "\"", "'": return EnglishToken(text: t, tag: previous == nil || sentenceInitial ? "``" : "''", whitespace: "")
        case "…": return EnglishToken(text: t, tag: "NFP", whitespace: "")
        case "—", "–": return EnglishToken(text: t, tag: ":", whitespace: "")
        case "-": return EnglishToken(text: t, tag: "HYPH", whitespace: "")
        case "$", "£", "€": return EnglishToken(text: t, tag: "$", whitespace: "")
        case "%", "&", "+", "@": return EnglishToken(text: t, tag: "NN", whitespace: "")
        default: break
        }

        // Contraction endings.
        if lowered == "n't" { return EnglishToken(text: t, tag: "RB", whitespace: "") }
        if lowered == "'s" || lowered == "’s" {
            if let p = previous?.text.lowercased(), personal.contains(p) || whPronouns.contains(p) || p == "there" {
                return EnglishToken(text: t, tag: "VBZ", whitespace: "")
            }
            return EnglishToken(text: t, tag: "POS", whitespace: "")
        }
        if lowered == "'re" || lowered == "'ve" || lowered == "'m" || lowered == "'em" {
            return EnglishToken(text: t, tag: "VBP", whitespace: "")
        }
        if lowered == "'ll" || lowered == "'d" { return EnglishToken(text: t, tag: "MD", whitespace: "") }
        if lowered == "'" || lowered == "’" { return EnglishToken(text: t, tag: "POS", whitespace: "") }

        // Numbers: digit runs with numeric punctuation stay whole and are CD; ordinals too.
        if t.unicodeScalars.contains(where: isDecimalDigit) {
            return EnglishToken(text: t, tag: "CD", whitespace: "")
        }

        // Context rules for the words whose fine verb tags the lexicons distinguish.
        if lowered == "read" || lowered == "reread" {
            let prev = previous?.text.lowercased() ?? ""
            let tag: String
            if ["to", "will", "would", "can", "could", "may", "might", "must", "shall", "should", "do", "did",
                "does", "don't", "didn't", "doesn't", "let", "please", "and", "or", "but"].contains(prev) {
                tag = "VB"
            } else if ["have", "has", "had", "'ve", "'d", "was", "were", "been", "be", "is", "are", "am", "being",
                       "haven't", "hasn't", "hadn't"].contains(prev) {
                tag = "VBN"
            } else if taggerClass == .verb || taggerClass == nil {
                tag = "VBD"   // narrative past
            } else {
                tag = "NN"    // "a good read"
            }
            return EnglishToken(text: t, tag: tag, whitespace: "")
        }
        if lowered == "wound" {
            let prev = previous?.text.lowercased() ?? ""
            let tag: String
            if ["have", "has", "had", "'ve", "'d", "was", "were", "been", "be", "is", "are"].contains(prev) { tag = "VBN" }
            else if taggerClass == .verb || taggerClass == nil { tag = "VBD" }
            else { tag = "NN" }
            return EnglishToken(text: t, tag: tag, whitespace: "")
        }

        // Whitelists, then NLTagger's lexical class.
        if determiners.contains(lowered) { return EnglishToken(text: t, tag: "DT", whitespace: "") }
        if possessives.contains(lowered) { return EnglishToken(text: t, tag: "PRP$", whitespace: "") }
        if personal.contains(lowered) { return EnglishToken(text: t, tag: "PRP", whitespace: "") }
        if whPronouns.contains(lowered) { return EnglishToken(text: t, tag: "WP", whitespace: "") }
        if whDeterminers.contains(lowered) { return EnglishToken(text: t, tag: "WDT", whitespace: "") }
        if lowered == "to" { return EnglishToken(text: t, tag: "TO", whitespace: "") }
        if modals.contains(lowered) { return EnglishToken(text: t, tag: "MD", whitespace: "") }
        if conjunctions.contains(lowered) { return EnglishToken(text: t, tag: "CC", whitespace: "") }
        if prepositions.contains(lowered) { return EnglishToken(text: t, tag: "IN", whitespace: "") }
        if interjections.contains(lowered) { return EnglishToken(text: t, tag: "UH", whitespace: "") }
        if adverbs.contains(lowered) { return EnglishToken(text: t, tag: "RB", whitespace: "") }

        switch taggerClass {
        case .pronoun: return EnglishToken(text: t, tag: "PRP", whitespace: "")
        case .determiner: return EnglishToken(text: t, tag: "DT", whitespace: "")
        case .preposition: return EnglishToken(text: t, tag: "IN", whitespace: "")
        case .conjunction: return EnglishToken(text: t, tag: "CC", whitespace: "")
        case .adverb: return EnglishToken(text: t, tag: "RB", whitespace: "")
        case .adjective: return EnglishToken(text: t, tag: "JJ", whitespace: "")
        case .interjection: return EnglishToken(text: t, tag: "UH", whitespace: "")
        case .number: return EnglishToken(text: t, tag: "CD", whitespace: "")
        case .classifier: return EnglishToken(text: t, tag: "NN", whitespace: "")
        case .particle: return EnglishToken(text: t, tag: "RP", whitespace: "")
        case .verb:
            if t.hasSuffix("ing") { return EnglishToken(text: t, tag: "VBG", whitespace: "") }
            if t.hasSuffix("ed") { return EnglishToken(text: t, tag: "VBD", whitespace: "") }
            if t.hasSuffix("es") { return EnglishToken(text: t, tag: "VBZ", whitespace: "") }
            if t.hasSuffix("s"), !t.hasSuffix("ss") { return EnglishToken(text: t, tag: "VBZ", whitespace: "") }
            return EnglishToken(text: t, tag: "VB", whitespace: "")
        case .noun, .otherWord, .other, nil:
            if nameType == .personalName || nameType == .placeName || nameType == .organizationName {
                return EnglishToken(text: t, tag: "NNP", whitespace: "")
            }
            if isProperForm(t, sentenceInitial: sentenceInitial) {
                return EnglishToken(text: t, tag: "NNP", whitespace: "")
            }
            return EnglishToken(text: t, tag: "NN", whitespace: "")
        default: break
        }
        return EnglishToken(text: t, tag: "NN", whitespace: "")
    }

    /// Capitalized words (not at a sentence start), all-caps and dotted names are proper nouns.
    private static func isProperForm(_ t: String, sentenceInitial: Bool) -> Bool {
        let letters = Array(t.unicodeScalars.filter { $0.properties.isAlphabetic })
        guard let first = letters.first, letters.count > 1 else { return false }
        if first.properties.isUppercase {
            if !sentenceInitial { return true }
            // At a sentence start, only mixed-case or dotted forms look like names ("McLane", "U.S.").
            let rest = letters.dropFirst()
            if !rest.allSatisfy({ $0.properties.isLowercase }) { return true }
            return t.contains(".")
        }
        return false
    }

    /// "used" is VBD only when it means "accustomed to" (followed by "to"); otherwise VBN.
    /// Runs over the finished token list, as the context rules do.
    static func fixUsedTo(_ tokens: [EnglishToken]) {
        for i in tokens.indices where tokens[i].text.lowercased() == "used" {
            let next = i + 1 < tokens.count ? tokens[i + 1].text.lowercased() : ""
            tokens[i].tag = next == "to" ? "VBD" : "VBN"
        }
    }
}
