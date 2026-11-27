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

    /// Whether a file name names a non-story page. Whole words only ("cover1.xhtml", "title-page",
    /// "toc.xhtml"), so story files such as "chapter_discovery" or "Navarro" aren't caught.
    static func isFrontMatterFileName(_ name: String) -> Bool {
        let base = ((name as NSString).deletingPathExtension).lowercased()
        let words = base.split { !$0.isLetter }.map(String.init)
        var candidates = Set(words)
        for i in words.indices.dropLast() { candidates.insert(words[i] + words[i + 1]) }   // title-page → titlepage
        let names = Set(frontMatterNames.map { $0.replacingOccurrences(of: "-", with: "") })
        return !candidates.isDisjoint(with: names) || words.contains { $0.hasPrefix("acknowledg") }
    }

    /// Lowercased title prefixes that mark non-story pages.
    static let frontMatterTitles = [
        "copyright", "contents", "table of contents", "title page", "also by", "other books by",
        "books by", "imprint", "colophon", "uncopyright", "front matter",
        "dedication", "acknowledgment", "acknowledgement", "about the author", "about the publisher",
        "praise for", "advance praise", "a note on the type", "also available", "newsletter", "sign up",
        "agradecimientos", "dedicatoria", "sobre el autor", "acerca del autor",
        // Spanish, German, Russian, Ukrainian
        "índice", "indice", "contenido", "créditos", "derechos", "inhalt", "inhaltsverzeichnis", "impressum",
        "содержание", "оглавление", "выходные данные", "зміст", "вихідні дані",
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
            /// Front matter only because it's short and untitled (a guess, not a declaration).
            var guessedFront = false
            /// Habla made the title up ("Chapter 3"): it gets translated into the book's language.
            var generatedNumber: Int? = nil
        }
        var drafts: [Draft] = []
        var untitledCount = 0
        let tocIsUsable = Set(package.toc.map(\.href)).count >= 2
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
                || Self.isFrontMatterFileName((lowerHref as NSString).lastPathComponent)

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
            // Declared front matter (by the book itself), as opposed to a guess from length.
            let declared = isFront || title.map { t in Self.frontMatterTitles.contains { t.lowercased().hasPrefix($0) } } == true
            var generated: Int?
            if title == nil {
                untitledCount += front ? 0 : 1
                title = front ? "Front matter" : "Chapter \(untitledCount)"
                if !front { generated = untitledCount }
            }
            drafts.append(Draft(title: title!, blocks: result.blocks, frontMatter: front,
                                spineIndex: spineItem.index, href: item.href, words: words,
                                guessedFront: front && !declared, generatedNumber: generated))
        }

        guard drafts.contains(where: { $0.words > 0 }) else { throw EPUBError.noText }
        // A short book (a story, an essay) can be all "short untitled pages": if nothing was left
        // to narrate, those pages are the book, not front matter.
        if !drafts.contains(where: { !$0.frontMatter }) {
            var n = 0
            for i in drafts.indices where drafts[i].guessedFront && drafts[i].words > 0 {
                n += 1
                drafts[i].frontMatter = false
                drafts[i].title = drafts.filter(\.guessedFront).count == 1 ? package.title : "Part \(n)"
            }
        }

        // The book's language decides sentence splitting, narration text, chapter names, and
        // whether Paradee can narrate it at all.
        let sample = drafts.filter { !$0.frontMatter }.flatMap(\.blocks).prefix(80).map(\.text).joined(separator: " ")
        let language = BookLanguage.detect(declared: package.language, sample: sample)
        let narratable = BookLanguage.hasVoice(language)
        var segmenter = self.segmenter; segmenter.language = language
        var normalizer = self.normalizer; normalizer.language = language
        let chapterWord = BookLanguage.chapterWord(language)
        for i in drafts.indices {
            if let n = drafts[i].generatedNumber { drafts[i].title = "\(chapterWord) \(n)" }
            else if drafts[i].title.hasPrefix("Part "), drafts[i].guessedFront, let n = Int(drafts[i].title.dropFirst(5)) {
                drafts[i].title = "\(BookLanguage.partWord(language)) \(n)"
            } else if language != "en", !drafts[i].frontMatter {
                // A heading that is only a number ("IV", "12.") names the chapter.
                let core = drafts[i].title.trimmingCharacters(in: CharacterSet(charactersIn: " .:"))
                if !core.isEmpty, core.count <= 8, core.allSatisfy({ "IVXLCDMivxlcdm".contains($0) }) || core.allSatisfy(\.isNumber) {
                    drafts[i].title = "\(chapterWord) \(core.uppercased())"
                }
            }
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
                audioStatus: !narratable || (draft.frontMatter && !narrateFrontMatter) ? .skipped : .pending))
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
            id: id, title: package.title, author: package.author, language: language,
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
