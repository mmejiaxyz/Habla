import Foundation

/// EPUB → processed `.habla` bundle (text, cover, accent, manifest). No audio yet;
/// chapters start as `pending` and the `RenderPipeline` fills them in.
public struct BookImporter {
    public var segmenter = SentenceSegmenter()
    public var normalizer = SpeechNormalizer()
    /// Narrate front matter (copyright, TOC…)? Off by default; it's still readable.
    public var narrateFrontMatter = false
    /// Keep a copy of the original EPUB in `<library>/Originals/` (Mac only: e-readers download
    /// it over OPDS; it is never part of the bundle the iPhone syncs).
    public var keepOriginal = true

    public static func originalURL(for id: String, in library: URL) -> URL {
        library.appendingPathComponent("Originals/\(id).epub")
    }

    public init() {}

    static let frontMatterTypes: Set<String> = [
        "copyright-page", "titlepage", "halftitlepage", "toc", "imprint", "colophon", "imprimatur",
        "landmarks", "loi", "lot", "index", "uncopyright", "seriespage", "errata", "acknowledgments",
    ]
    static let frontMatterNames = [
        "copyright", "titlepage", "title-page", "toc", "contents", "imprint", "colophon",
        "uncopyright", "halftitle", "half-title", "nav", "cover", "loi", "endnotes", "acknowledg",
    ]

    /// Lowercased title prefixes that mark non-story pages.
    static let frontMatterTitles = [
        "copyright", "contents", "table of contents", "title page", "also by", "other books by",
        "books by", "imprint", "colophon", "uncopyright", "front matter",
    ]

    /// The file name Habla gives an EPUB it sends to an e-reader (stable, so CrossPoint's
    /// file-name document id is predictable): "Pride and Prejudice-bc41e616.epub".
    public static func deviceFileName(title: String, id: String) -> String {
        // Safe on FAT/exFAT SD cards: no reserved or control characters, no trailing dots/spaces,
        // short enough for every path the firmware builds from it.
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.illegalCharacters)
        var safe = String(String.UnicodeScalarView(title.unicodeScalars.filter { !banned.contains($0) }))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // ≤ 100 UTF-8 bytes in total, like the firmware's own file names.
        while safe.utf8.count > 80 { safe.removeLast() }
        while let last = safe.last, last == "." || last == " " { safe.removeLast() }
        while let first = safe.first, first == "." || first == " " { safe.removeFirst() }
        if safe.isEmpty { safe = "Book" }
        return "\(safe)-\(id.prefix(8)).epub"
    }

    @discardableResult
    public func importEPUB(at epubURL: URL, into library: URL) throws -> BookBundle {
        let package = try EPUBPackage(url: epubURL)
        let id = try DocumentDigest.sha256Prefix(of: epubURL)
        let fm = FileManager.default
        let dest = BookBundle.url(for: id, in: library)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let bundle = BookBundle(url: dest)

        // TOC title lookup by file (first, shallowest entry wins).
        var tocTitles: [String: String] = [:]
        for entry in package.toc.sorted(by: { $0.depth < $1.depth }) where tocTitles[entry.href] == nil {
            tocTitles[entry.href] = entry.title
        }

        // Extract each spine document; merge untitled continuation files into the previous chapter.
        struct Draft {
            var title: String; var blocks: [TextBlock]; var frontMatter: Bool
            var spineIndex: Int; var href: String; var words: Int
        }
        var drafts: [Draft] = []
        var untitledCount = 0
        let tocIsUsable = Set(package.toc.map(\.href)).count >= 3
        for spineItem in package.spine {
            let item = spineItem.item
            guard item.mediaType.contains("html") || item.href.hasSuffix("html") || item.href.hasSuffix(".htm"),
                  let data = try? package.archive.read(item.href) else { continue }
            let result = ContentExtractor(spineIndex: spineItem.index, href: item.href).extract(data)
            guard result.blocks.contains(where: { $0.kind != .sceneBreak }) else { continue }

            let lowerHref = item.href.lowercased()
            let isFront = !spineItem.linear
                || item.properties.contains("nav")
                || !result.structuralTypes.isDisjoint(with: Self.frontMatterTypes)
                || Self.frontMatterNames.contains { (lowerHref as NSString).lastPathComponent.contains($0) }

            let tocTitle = tocTitles[item.href]
            let words = result.blocks.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
            // Untitled file after a titled chapter = the publisher split one chapter across files.
            // Only trust that when the TOC is real; Kindle→Calibre books often have a 1-entry TOC
            // and image-only chapter headings, where every file is its own chapter.
            if tocIsUsable, tocTitle == nil, result.firstHeading == nil, let last = drafts.last, !last.frontMatter, !isFront {
                drafts[drafts.count - 1].blocks += result.blocks
                continue
            }
            var title = tocTitle ?? result.firstHeading.map { String($0.prefix(80)) }
            // Short untitled pages before the story starts are title pages, maps, epigraph blurbs.
            let beforeStory = !drafts.contains { !$0.frontMatter && $0.words > 400 }
            let front = isFront
                || (title == nil && words < 120 && beforeStory)
                || title.map { t in Self.frontMatterTitles.contains { t.lowercased().hasPrefix($0) } } == true
            if title == nil {
                untitledCount += front ? 0 : 1
                title = front ? "Front matter" : "Chapter \(untitledCount)"
            }
            drafts.append(Draft(title: title!, blocks: result.blocks, frontMatter: front,
                                spineIndex: spineItem.index, href: item.href, words: words))
        }

        // Sentences + spoken text, then write each chapter.
        var chapters: [ChapterInfo] = []
        for (i, draft) in drafts.enumerated() {
            var nextID = 0
            var words = 0
            let blocks = draft.blocks.map { block -> TextBlock in
                var b = block
                guard b.kind != .sceneBreak else { return b }
                b.sentences = segmenter.ranges(in: b.text).map { range in
                    let display = b.substring(range)
                    let spoken = normalizer.spoken(display, isHeading: b.kind == .heading)
                    defer { nextID += 1 }
                    return Sentence(id: nextID, range: range, spoken: spoken == display ? nil : spoken)
                }
                words += b.text.split(whereSeparator: { $0.isWhitespace }).count
                return b
            }
            let text = ChapterText(index: i, title: draft.title, blocks: blocks)
            try bundle.write(text, to: BookBundle.textPath(i))
            chapters.append(ChapterInfo(
                index: i, title: draft.title, textFile: BookBundle.textPath(i), audioFile: nil, timingFile: nil,
                sentenceCount: nextID, wordCount: words, duration: nil, isFrontMatter: draft.frontMatter,
                spineIndex: draft.spineIndex, href: draft.href,
                audioStatus: draft.frontMatter && !narrateFrontMatter ? .skipped : .pending))
        }

        // Cover + accent.
        var coverFile: String?
        let rawCover = package.coverData()
        if let rawCover, let jpeg = ImageTools.normalizedCover(rawCover) {
            try jpeg.write(to: bundle.fileURL("cover.jpg"))
            coverFile = "cover.jpg"
        }

        if keepOriginal {
            let original = Self.originalURL(for: id, in: library)
            do {
                try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: original.path) { try fm.removeItem(at: original) }
                try fm.copyItem(at: epubURL, to: original)
            } catch {
                try? fm.removeItem(at: dest)
                throw error
            }
        }

        let now = Date()
        let manifest = BookManifest(
            id: id, title: package.title, author: package.author, language: package.language,
            publisher: package.publisher, summary: package.summary,
            sourceFileName: epubURL.lastPathComponent,
            koreaderDigest: try DocumentDigest.koreaderPartialMD5(of: epubURL),
            koreaderFilenameDigest: KOReaderDigest.filename(Self.deviceFileName(title: package.title, id: id)),
            accentColor: ImageTools.accentColor(from: rawCover, seed: id),
            coverFile: coverFile, createdAt: now, updatedAt: now, revision: 0,
            voice: nil, chapters: chapters, files: [])
        do { try bundle.commit(manifest) }   // the manifest last: a half-imported book never appears
        catch { try? fm.removeItem(at: dest); throw error }
        return bundle
    }
}
