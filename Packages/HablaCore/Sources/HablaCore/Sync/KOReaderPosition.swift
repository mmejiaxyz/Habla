import Foundation
import CryptoKit

/// Translates between e-reader positions (KOReader / CrossPoint XPointers) and Habla's
/// (chapter, sentence).
///
/// Formats (from the CrossPoint firmware, lib/KOReaderSync/ChapterXPathResolver.cpp):
///   `/body/DocFragment[N]/body/section[1]/p[3]/em[1]/text()[2].17`
/// - `DocFragment[N]`: 1-based spine index — always decides the section (never `percentage`).
/// - every element step carries `[n]` (index among same-name siblings); older crengine omits `[1]`.
/// - `text()[k].off`: k-th non-empty text node of that element, `off` characters into it.
///   KOReader also writes `text().off` (k = 1).
/// Positions resolve to the nearest sentence at or before the pointer, so small drift
/// (CrossPoint can land a line or two off) never moves the reader to another chapter.
public struct KOReaderPositionMap {
    struct Entry {
        var chapter: Int
        var path: String            // normalised block path (matching only)
        var original: String        // block path as written
        var spineIndex: Int
        var sentences: [Sentence]
        var anchors: [TextAnchor]   // text nodes inside the block (may be empty for old bundles)
    }

    let entries: [Entry]
    let manifest: BookManifest

    public init(bundle: BookBundle) throws {
        manifest = try bundle.manifest()
        var out: [Entry] = []
        for info in manifest.chapters {
            let text = try bundle.chapterText(info)
            for block in text.blocks {
                out.append(Entry(chapter: info.index, path: Self.normalize(block.source.xpointer),
                                 original: block.source.xpointer, spineIndex: block.source.spineIndex,
                                 sentences: block.sentences, anchors: block.anchors ?? []))
            }
        }
        entries = out
    }

    // MARK: Habla → e-reader

    public func xpointer(chapter: Int, sentence: Int) -> String? {
        guard let (entry, s) = locate(chapter: chapter, sentence: sentence) else { return nil }
        let pos = s.range.location
        if let a = entry.anchors.last(where: { $0.offset <= pos }) {
            // Written in CrossPoint's READ numbering, with a raw (uncollapsed) code-point offset.
            return "\(Self.indexed(a.path))/text()[\(a.readerNode ?? a.node)].\(a.rawOffset(pos - a.offset))"
        }
        return "\(Self.indexed(entry.original))/text()[1].\(pos)"
    }

    func locate(chapter: Int, sentence: Int) -> (Entry, Sentence)? {
        // Synthetic ids (spoken title, chapter-end silence) are before the chapter's first
        // real sentence; an e-reader position maps to that start, not to the chapter's end.
        if sentence < 0 {
            for e in entries where e.chapter == chapter {
                if let s = e.sentences.first { return (e, s) }
            }
            return nil
        }
        for e in entries where e.chapter == chapter {
            if let s = e.sentences.first(where: { $0.id == sentence }) { return (e, s) }
        }
        for e in entries.reversed() where e.chapter == chapter {
            if let s = e.sentences.last { return (e, s) }
        }
        return nil
    }

    // MARK: e-reader → Habla

    public func position(for xpointer: String) -> (chapter: Int, sentence: Int)? {
        let (elementPath, node, offset) = Self.split(xpointer)
        let target = Self.normalize(elementPath)
        guard let spine = Self.docFragment(target) else { return nil }
        let inSpine = entries.indices.filter { entries[$0].spineIndex == spine }
        guard !inSpine.isEmpty else { return nil }

        // 1. Exact text node (works inside <em>, links, etc.).
        for i in inSpine {
            // Devices WRITE the k-th non-empty text run, with raw code-point offsets.
            if let a = entries[i].anchors.first(where: { Self.normalize($0.path) == target && $0.node == node }) {
                if let r = resolve(from: i, at: a.offset + a.displayOffset(offset)) { return r }
            }
        }
        // 2. The block itself, or the block containing the pointed element.
        let match = inSpine.first { entries[$0].path == target }
            ?? inSpine.filter { target.hasPrefix(entries[$0].path + "/") }.max { entries[$0].path.count < entries[$1].path.count }
            ?? inSpine.first { entries[$0].path.hasPrefix(target + "/") }
            ?? inSpine.last { Self.precedes(entries[$0].path, target) }
            ?? inSpine.first!
        let exactBlock = entries[match].path == target
        return resolve(from: match, at: exactBlock && node == 1 ? offset : 0)
    }

    /// Sentence at a display offset within block `i`; walks forward past sentence-less blocks.
    func resolve(from i: Int, at offset: Int) -> (chapter: Int, sentence: Int)? {
        for j in i..<entries.count {
            let e = entries[j]
            guard !e.sentences.isEmpty else { continue }
            let s = j == i ? (e.sentences.last { $0.range.location <= offset } ?? e.sentences[0]) : e.sentences[0]
            return (e.chapter, s.id)
        }
        return nil
    }

    /// 0…1 through the book, for KOReader's `percentage` field.
    public func percentage(chapter: Int, sentence: Int) -> Double {
        manifest.fraction(chapter: chapter, sentence: sentence)
    }

    // MARK: Path helpers

    /// Splits `…/text()[k].off` or `…/text().off` → (element path, k, off).
    static func split(_ xp: String) -> (String, Int, Int) {
        guard let r = xp.range(of: "/text()", options: .backwards) else { return (xp, 1, 0) }
        var tail = xp[r.upperBound...]
        var node = 1
        if tail.hasPrefix("[") {
            let digits = tail.dropFirst().prefix { $0.isNumber }
            node = max(1, Int(digits) ?? 1)
            tail = tail.dropFirst(1 + digits.count)
            if tail.hasPrefix("]") { tail = tail.dropFirst() }
        }
        let offset = tail.hasPrefix(".") ? Int(tail.dropFirst().prefix { $0.isNumber }) ?? 0 : 0
        return (String(xp[..<r.lowerBound]), node, offset)
    }

    static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "[1]", with: "")
            .split(separator: "/").map { $0.lowercased() }.joined(separator: "/")
            .replacingOccurrences(of: "docfragment", with: "DocFragment")
    }

    /// Writes `[1]` on every step after `DocFragment[N]/body`, like the CrossPoint firmware.
    static func indexed(_ path: String) -> String {
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let frag = parts.firstIndex(where: { $0.hasPrefix("DocFragment") }) else { return path }
        for i in parts.indices where i > frag + 1 && !parts[i].contains("[") { parts[i] += "[1]" }
        return "/" + parts.joined(separator: "/")
    }

    static func docFragment(_ path: String) -> Int? {
        guard let r = path.range(of: "DocFragment") else { return nil }
        let rest = path[r.upperBound...]
        guard rest.hasPrefix("[") else { return 0 }  // "[1]" was stripped
        return Int(rest.dropFirst().prefix { $0.isNumber }).map { $0 - 1 }
    }

    /// Document-order comparison of two element paths (`p[3]` before `p[12]`).
    static func precedes(_ a: String, _ b: String) -> Bool {
        let sa = a.split(separator: "/"), sb = b.split(separator: "/")
        for (x, y) in zip(sa, sb) where x != y {
            let (nx, ix) = step(x), (ny, iy) = step(y)
            return nx == ny ? ix < iy : x < y
        }
        return sa.count < sb.count
    }

    static func step(_ s: Substring) -> (Substring, Int) {
        guard let o = s.firstIndex(of: "[") else { return (s, 1) }
        return (s[..<o], Int(s[s.index(after: o)...].prefix { $0.isNumber }) ?? 1)
    }
}

public enum KOReaderDigest {
    /// CrossPoint's default document id: MD5 of the file name (basename with extension).
    public static func filename(_ name: String) -> String {
        Insecure.MD5.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
