import Foundation
import HablaCore

/// One place the search text appears.
public struct FindHit: Identifiable, Equatable, Sendable {
    public var id: String { "\(chapter)-\(sentence)-\(offset)" }
    public var chapter: Int
    public var chapterTitle: String
    /// Sentence where the match starts (where the reader goes).
    public var sentence: Int
    /// Match position from the start of that sentence, and its length (UTF-16, display text).
    public var offset: Int
    public var length: Int
    public var before: String
    public var match: String
    public var after: String
}

/// Text folded for matching the way people type: any kind of space (incl. the non-breaking
/// ones books use in "Mr. Bennet") is one space, curly quotes and apostrophes are straight,
/// capitals and accents don't matter, soft hyphens vanish. Keeps a map back to the original.
struct FoldedText {
    var chars: [Character] = []
    var starts: [Int] = []      // UTF-16 offset of each folded character in the original
    var ends: [Int] = []

    init(_ text: String) {
        var offset = 0
        var lastWasSpace = false
        for ch in text {
            let len = ch.utf16.count
            defer { offset += len }
            if ch == "\u{00AD}" { continue }
            if ch.isWhitespace {
                if lastWasSpace, let i = ends.indices.last { ends[i] = offset + len; continue }
                chars.append(" "); starts.append(offset); ends.append(offset + len); lastWasSpace = true
                continue
            }
            lastWasSpace = false
            let mapped: String
            switch ch {
            case "\u{2019}", "\u{2018}", "\u{02BC}", "\u{2032}": mapped = "'"
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{00AB}", "\u{00BB}": mapped = "\""
            case "\u{2013}", "\u{2014}": mapped = "-"
            default: mapped = String(ch).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            }
            for f in mapped { chars.append(f); starts.append(offset); ends.append(offset + len) }
        }
    }

    /// Folded query: same folding, outer spaces trimmed.
    static func query(_ q: String) -> [Character] {
        var c = FoldedText(q.trimmingCharacters(in: .whitespacesAndNewlines)).chars
        while c.first == " " { c.removeFirst() }
        while c.last == " " { c.removeLast() }
        return c
    }

    /// UTF-16 ranges (in the original) of every match, left to right.
    func matches(_ q: [Character]) -> [NSRange] {
        guard !q.isEmpty, q.count <= chars.count else { return [] }
        var out: [NSRange] = []
        var i = 0
        let first = q[0]
        while i <= chars.count - q.count {
            if chars[i] == first {
                var j = 1
                while j < q.count && chars[i + j] == q[j] { j += 1 }
                if j == q.count {
                    out.append(NSRange(location: starts[i], length: ends[i + q.count - 1] - starts[i]))
                    i += q.count
                    continue
                }
            }
            i += 1
        }
        return out
    }
}

/// Whole-book search, in reading order. Matches across sentence breaks inside a paragraph.
public enum BookFind {
    public static func search(_ query: String, in bundle: BookBundle, manifest: BookManifest, limit: Int = 500) -> [FindHit] {
        let q = FoldedText.query(query)
        guard q.count >= 2 else { return [] }
        var hits: [FindHit] = []
        for info in manifest.chapters {
            guard let text = try? bundle.chapterText(info) else { continue }
            let title = ChapterNaming.title(info)
            for block in text.blocks where !block.sentences.isEmpty {
                let ns = block.text as NSString
                for r in FoldedText(block.text).matches(q) {
                    let s = block.sentences.last { $0.range.location <= r.location } ?? block.sentences[0]
                    hits.append(FindHit(chapter: info.index, chapterTitle: title, sentence: s.id,
                                        offset: r.location - s.range.location, length: r.length,
                                        before: tail(ns.substring(to: r.location), 40),
                                        match: ns.substring(with: r),
                                        after: head(ns.substring(from: NSMaxRange(r)), 60)))
                    if hits.count >= limit { return hits }
                }
            }
        }
        return hits
    }

    static func tail(_ s: String, _ n: Int) -> String {
        let t = s.count > n ? "…" + String(s.suffix(n).drop { !$0.isWhitespace }) : s
        return t.replacingOccurrences(of: "\n", with: " ")
    }
    static func head(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s.replacingOccurrences(of: "\n", with: " ") }
        let cut = s.prefix(n)
        let word = cut.lastIndex(where: \.isWhitespace).map { cut[..<$0] } ?? cut
        return String(word).replacingOccurrences(of: "\n", with: " ") + "…"
    }
}

extension ReaderModel {
    /// Goes to a search result and marks it on the page.
    public func show(_ hit: FindHit, query: String) {
        go(chapter: hit.chapter, sentence: hit.sentence)
        guard let layout, let sr = layout.chapter.range(ofSentence: hit.sentence) else { found = nil; return }
        let ns = layout.chapter.text.string as NSString
        var match = NSRange(location: sr.location + hit.offset, length: hit.length)
        // The page text matches the book text; if not (a typesetting difference), look nearby.
        let q = FoldedText.query(query)
        if NSMaxRange(match) > ns.length || FoldedText(ns.substring(with: match)).chars != q {
            let window = NSRange(location: max(0, sr.location - 20), length: min(ns.length - max(0, sr.location - 20), sr.length + hit.offset + hit.length + 40))
            guard let r = FoldedText(ns.substring(with: window)).matches(q).first else { found = nil; return }
            match = NSRange(location: window.location + r.location, length: r.length)
        }
        // A long sentence can run onto the next page: show the page with the match itself.
        found = (chapter, match)
        goToPage(layout.page(forCharacter: match.location))
    }
}
