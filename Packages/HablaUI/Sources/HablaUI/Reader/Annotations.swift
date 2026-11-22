import Foundation

/// An underline in a book, anchored to a sentence (stable across text sizes, themes and
/// re-layouts): `offset`/`length` are UTF-16 units inside that sentence's text.
public struct Underline: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var chapter: Int
    public var sentence: Int
    public var offset: Int
    public var length: Int
    public var text: String
    public var created: Date = Date()
}

/// Underlines for every book, in one small JSON file next to the library.
public final class AnnotationStore: @unchecked Sendable {
    public let fileURL: URL
    private var byBook: [String: [Underline]]
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        byBook = (try? JSONDecoder().decode([String: [Underline]].self, from: Data(contentsOf: fileURL))) ?? [:]
    }

    /// The store that belongs to the library a bundle lives in (`<library>/../annotations.json`).
    public static func forLibrary(of bundle: URL) -> AnnotationStore {
        let url = bundle.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("annotations.json")
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let s = cache[url] { return s }
        let s = AnnotationStore(fileURL: url)
        cache[url] = s
        return s
    }
    nonisolated(unsafe) private static var cache: [URL: AnnotationStore] = [:]
    private static let cacheLock = NSLock()

    public func underlines(book: String, chapter: Int? = nil) -> [Underline] {
        lock.withLock { (byBook[book] ?? []).filter { chapter == nil || $0.chapter == chapter } }
    }

    public func add(_ u: Underline, book: String) {
        lock.withLock {
            var list = byBook[book] ?? []
            // Re-underlining the same span is a no-op.
            if !list.contains(where: { $0.chapter == u.chapter && $0.sentence == u.sentence && $0.offset == u.offset && $0.length == u.length }) {
                list.append(u)
            }
            byBook[book] = list
        }
        save()
    }

    public func remove(_ id: UUID, book: String) {
        lock.withLock { byBook[book]?.removeAll { $0.id == id } }
        save()
    }

    private func save() {
        let data = lock.withLock { try? JSONEncoder().encode(byBook) }
        try? data?.write(to: fileURL, options: .atomic)
    }
}

extension ReaderModel {
    public var annotations: AnnotationStore { AnnotationStore.forLibrary(of: bundle.url) }

    /// Character ranges (in the typeset chapter) of this chapter's underlines.
    public func underlineRanges() -> [NSRange] {
        guard let chapterText = layout?.chapter else { return [] }
        return annotations.underlines(book: manifest.id, chapter: chapter).compactMap { u in
            guard let s = chapterText.range(ofSentence: u.sentence) else { return nil }
            let r = NSRange(location: s.location + u.offset, length: u.length)
            return NSMaxRange(r) <= chapterText.text.length ? r : nil
        }
    }

    /// The underline covering a range, if any.
    public func underline(covering range: NSRange) -> Underline? {
        guard let chapterText = layout?.chapter else { return nil }
        return annotations.underlines(book: manifest.id, chapter: chapter).first { u in
            guard let s = chapterText.range(ofSentence: u.sentence) else { return false }
            return NSIntersectionRange(NSRange(location: s.location + u.offset, length: u.length), range).length > 0
        }
    }

    public func addUnderline(_ range: NSRange) {
        guard let chapterText = layout?.chapter, let sid = chapterText.sentence(atCharacter: range.location),
              let s = chapterText.range(ofSentence: sid) else { return }
        let text = (chapterText.text.string as NSString).substring(with: range)
        annotations.add(Underline(chapter: chapter, sentence: sid, offset: range.location - s.location,
                                  length: range.length, text: text), book: manifest.id)
        objectWillChange.send()
    }

    public func removeUnderline(_ u: Underline) {
        annotations.remove(u.id, book: manifest.id)
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
