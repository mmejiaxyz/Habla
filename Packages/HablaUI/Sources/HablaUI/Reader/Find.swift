import Foundation
import HablaCore

/// One place the search text appears: chapter, sentence, and which occurrence inside it.
public struct FindHit: Identifiable, Equatable, Sendable {
    public var id: String { "\(chapter)-\(sentence)-\(occurrence)" }
    public var chapter: Int
    public var chapterTitle: String
    public var sentence: Int
    public var occurrence: Int
    /// Text around the match, with the match's range inside it.
    public var before: String
    public var match: String
    public var after: String
}

/// Whole-book search: case- and accent-insensitive, in reading order.
public enum BookFind {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    public static func search(_ query: String, in bundle: BookBundle, manifest: BookManifest, limit: Int = 500) -> [FindHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        var hits: [FindHit] = []
        for info in manifest.chapters {
            guard let text = try? bundle.chapterText(info) else { continue }
            let title = ChapterNaming.title(info)
            for block in text.blocks {
                for s in block.sentences {
                    let sentence = block.substring(s.range)
                    var from = sentence.startIndex
                    var k = 0
                    while let r = sentence.range(of: q, options: options, range: from..<sentence.endIndex) {
                        hits.append(FindHit(chapter: info.index, chapterTitle: title, sentence: s.id, occurrence: k,
                                            before: tail(sentence[..<r.lowerBound], 40),
                                            match: String(sentence[r]),
                                            after: head(sentence[r.upperBound...], 60)))
                        if hits.count >= limit { return hits }
                        k += 1
                        from = r.upperBound
                    }
                }
            }
        }
        return hits
    }

    static func tail(_ s: Substring, _ n: Int) -> String {
        let t = s.count > n ? "…" + s.suffix(n).drop { !$0.isWhitespace } : String(s)
        return t.replacingOccurrences(of: "\n", with: " ")
    }
    static func head(_ s: Substring, _ n: Int) -> String {
        guard s.count > n else { return String(s).replacingOccurrences(of: "\n", with: " ") }
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
        var searchRange = sr
        var match = NSRange(location: NSNotFound, length: 0)
        for _ in 0...hit.occurrence {
            match = ns.range(of: query.trimmingCharacters(in: .whitespacesAndNewlines), options: BookFind.options, range: searchRange)
            guard match.location != NSNotFound else { break }
            searchRange = NSRange(location: NSMaxRange(match), length: max(0, NSMaxRange(sr) - NSMaxRange(match)))
        }
        guard match.location != NSNotFound else { found = nil; return }
        // A long sentence can run onto the next page: show the page with the match itself.
        let p = layout.page(forCharacter: match.location)
        found = (chapter, match)
        goToPage(p)
    }
}
