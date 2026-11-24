import Foundation
import HablaCore

/// Underlines are markers of kind `.underline` (HablaCore `MarkerStore`, synced to every device).
public typealias Underline = Marker

extension MarkerStore {
    public func underlines(book: String, chapter: Int? = nil) -> [Marker] { markers(book: book, chapter: chapter, kind: .underline) }
}

extension ReaderModel {
    public var annotations: MarkerStore { MarkerStore.forLibrary(bundle.url.deletingLastPathComponent()) }

    /// Character ranges (in the typeset chapter) of this chapter's underlines.
    public func underlineRanges() -> [NSRange] {
        guard let chapterText = layout?.chapter else { return [] }
        return annotations.underlines(book: manifest.id, chapter: chapter).compactMap { u in
            guard let s = chapterText.range(ofSentence: u.sentence) else { return nil }
            let r = NSRange(location: s.location + (u.offset ?? 0), length: u.length ?? 0)
            return NSMaxRange(r) <= chapterText.text.length ? r : nil
        }
    }

    /// The underline covering a range, if any.
    public func underline(covering range: NSRange) -> Underline? {
        guard let chapterText = layout?.chapter else { return nil }
        return annotations.underlines(book: manifest.id, chapter: chapter).first { u in
            guard let s = chapterText.range(ofSentence: u.sentence) else { return false }
            return NSIntersectionRange(NSRange(location: s.location + (u.offset ?? 0), length: u.length ?? 0), range).length > 0
        }
    }

    public func addUnderline(_ range: NSRange) {
        guard let chapterText = layout?.chapter, let sid = chapterText.sentence(atCharacter: range.location),
              let s = chapterText.range(ofSentence: sid) else { return }
        let text = (chapterText.text.string as NSString).substring(with: range)
        let offset = range.location - s.location
        // Re-underlining the same span is a no-op.
        guard !annotations.underlines(book: manifest.id, chapter: chapter).contains(where: {
            $0.sentence == sid && $0.offset == offset && $0.length == range.length }) else { return }
        annotations.add(Marker(bookID: manifest.id, kind: .underline, chapter: chapter, sentence: sid, offset: offset,
                               length: range.length, text: text, deviceID: annotations.deviceID))
        objectWillChange.send()
    }

    public func removeUnderline(_ u: Underline) {
        annotations.remove(u.id)
        objectWillChange.send()
    }

    // MARK: Bookmarks

    /// Bookmarks on the page(s) showing now.
    public var pageBookmarks: [Marker] {
        guard let first = currentSentence else { return [] }
        let end = (page + columns < pageCount ? layout?.firstSentence(onPage: page + columns) : nil) ?? Int.max
        return annotations.markers(book: manifest.id, chapter: chapter, kind: .bookmark).filter { $0.sentence >= first && $0.sentence < end }
    }

    /// Bookmarks this page, or removes its bookmark.
    public func toggleBookmark() {
        if !pageBookmarks.isEmpty {
            for b in pageBookmarks { annotations.remove(b.id) }
        } else if let sid = currentSentence, let c = layout?.chapter {
            let text = c.range(ofSentence: sid).map { (c.text.string as NSString).substring(with: $0) } ?? chapterTitle
            annotations.add(Marker(bookID: manifest.id, kind: .bookmark, chapter: chapter, sentence: sid,
                                   text: text.trimmingCharacters(in: .whitespacesAndNewlines), deviceID: annotations.deviceID))
        }
        objectWillChange.send()
    }

    /// Every bookmark and underline of the book, in reading order.
    public var allMarkers: [Marker] { annotations.markers(book: manifest.id) }

    public func removeMarker(_ m: Marker) {
        annotations.remove(m.id)
        objectWillChange.send()
    }

    /// The whole grammatical sentence around a character (narration segments can be shorter).
    public func sentenceRange(around loc: Int) -> NSRange? {
        guard let c = layout?.chapter, loc < c.text.length else { return nil }
        let ns = c.text.string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: loc, length: 0))
        var found: NSRange?
        ns.enumerateSubstrings(in: paragraph, options: [.bySentences, .substringNotRequired]) { _, r, _, stop in
            if NSLocationInRange(loc, r) { found = r; stop.pointee = true }
        }
        guard var r = found else { return nil }
        let ws = CharacterSet.whitespacesAndNewlines
        while r.length > 0, ws.contains(Unicode.Scalar(ns.character(at: r.location)) ?? " ") { r.location += 1; r.length -= 1 }
        while r.length > 0, ws.contains(Unicode.Scalar(ns.character(at: NSMaxRange(r) - 1)) ?? " ") { r.length -= 1 }
        return r.length > 0 ? r : nil
    }
}
