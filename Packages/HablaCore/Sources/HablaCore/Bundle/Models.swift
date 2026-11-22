import Foundation

// MARK: - Book manifest (manifest.json)

/// Top-level description of a processed book. Shared by the Mac app (writer)
/// and the iOS app (reader). Positions everywhere are (chapter, sentence).
public struct BookManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int = BookManifest.currentFormatVersion
    public var id: String
    public var title: String
    public var author: String
    public var language: String
    public var publisher: String?
    public var summary: String?
    /// Original EPUB file name, and KOReader's partial-MD5 document digest
    /// (lets a KOReader / CrossPoint device's progress be matched later).
    public var sourceFileName: String
    public var koreaderDigest: String
    /// CrossPoint's default document id: MD5 of the EPUB's file name on the device.
    public var koreaderFilenameDigest: String? = nil
    /// `#RRGGBB`, extracted from the cover and tuned for dark backgrounds.
    public var accentColor: String
    public var coverFile: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Bumped whenever any file in the bundle changes; drives sync.
    public var revision: Int
    public var voice: VoiceInfo?
    public var chapters: [ChapterInfo]
    public var files: [FileEntry]

    public var totalDuration: TimeInterval {
        chapters.compactMap(\.duration).reduce(0, +)
    }

    public var isFullyRendered: Bool {
        chapters.allSatisfy { $0.audioStatus != .pending }
    }

    /// Chapters that still need narrating with `voiceID` (pending, or narrated with another voice).
    public func chaptersToNarrate(voiceID: String) -> [ChapterInfo] {
        chapters.filter { c in
            c.audioStatus == .pending || (c.audioStatus == .ready && (c.voiceID ?? voice?.voiceID) != voiceID)
        }
    }
}

public struct VoiceInfo: Codable, Equatable, Hashable, Sendable {
    public var engine: String      // "kokoro", "system", ...
    public var voiceID: String     // e.g. "af_heart"
    public var speed: Double       // render speed; playback rate is separate
    public init(engine: String, voiceID: String, speed: Double = 1.0) {
        self.engine = engine; self.voiceID = voiceID; self.speed = speed
    }
}

public struct ChapterInfo: Codable, Equatable, Sendable {
    public enum AudioStatus: String, Codable, Sendable { case pending, ready, skipped }

    public var index: Int
    public var title: String
    public var textFile: String
    public var audioFile: String?
    public var timingFile: String?
    public var sentenceCount: Int
    public var wordCount: Int
    public var duration: TimeInterval?
    /// Copyright pages, tables of contents, colophons… readable, not narrated by default.
    public var isFrontMatter: Bool
    public var spineIndex: Int
    public var href: String
    public var audioStatus: AudioStatus
    /// Voice this chapter's audio was made with (nil = the book's voice, older bundles).
    public var voiceID: String? = nil
    /// The voice model that narrated it, e.g. "Kokoro v1.0 · fast (int8)" (nil in older bundles).
    public var model: String? = nil
}

public struct FileEntry: Codable, Equatable, Hashable, Sendable {
    public var path: String
    public var size: Int
    public var sha256: String
    /// When the file was last written on the Mac (lets re-indexing skip unchanged files).
    public var modified: Date? = nil
}

// MARK: - Chapter text (text/chNNN.json)

public struct ChapterText: Codable, Equatable, Sendable {
    public var index: Int
    public var title: String
    public var blocks: [TextBlock]

    /// All sentences in reading order, with their block for convenience.
    public var sentences: [(block: Int, sentence: Sentence)] {
        blocks.enumerated().flatMap { b, block in block.sentences.map { (b, $0) } }
    }

    public func sentenceText(_ id: Int) -> String? {
        for block in blocks {
            if let s = block.sentences.first(where: { $0.id == id }) { return block.substring(s.range) }
        }
        return nil
    }
}

public struct TextBlock: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case heading, paragraph, quote, listItem, preformatted, sceneBreak
    }

    public var kind: Kind
    /// Heading level 1–6 when `kind == .heading`.
    public var level: Int?
    /// Display text, as printed in the book.
    public var text: String
    /// Italic / bold runs, in UTF-16 offsets into `text`.
    public var styles: [StyleRun]
    public var sentences: [Sentence]
    /// Where the block came from in the EPUB (for KOReader/CrossPoint sync).
    public var source: SourceRef
    /// Start of each original text node inside the block (for exact e-reader positions).
    public var anchors: [TextAnchor]? = nil

    public func substring(_ r: TextRange) -> String {
        let ns = text as NSString
        guard r.location >= 0, r.location + r.length <= ns.length else { return "" }
        return ns.substring(with: NSRange(location: r.location, length: r.length))
    }
}

public struct TextRange: Codable, Equatable, Hashable, Sendable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
}

public struct StyleRun: Codable, Equatable, Sendable {
    public enum Style: String, Codable, Sendable { case italic, bold, smallCaps }
    public var range: TextRange
    public var style: Style
}

public struct Sentence: Codable, Equatable, Sendable {
    /// Sequential within the chapter (0-based). Positions point at this.
    public var id: Int
    /// UTF-16 range into the block's display text.
    public var range: TextRange
    /// Text sent to the voice when it differs from the display text
    /// ("Mr." → "Mister", "1984" → "nineteen eighty-four").
    public var spoken: String?
}

/// One DOM text node of the source XHTML: where it starts in the block's display text,
/// the element that contains it (full path, possibly an inline element like `em`), and
/// its 1-based index among that element's non-empty text nodes.
public struct TextAnchor: Codable, Equatable, Sendable {
    public var offset: Int
    public var path: String
    /// Text-node number as e-readers WRITE it: k-th non-empty text run of the element.
    public var node: Int
    /// Text-node number as CrossPoint READS it: 1 + direct child elements closed before it.
    public var readerNode: Int? = nil
    /// Where display text and raw source text diverge inside this node (collapsed whitespace):
    /// pairs [displayOffset, rawOffset] in node-relative units (raw = Unicode code points).
    public var gaps: [[Int]]? = nil

    public init(offset: Int, path: String, node: Int, readerNode: Int? = nil, gaps: [[Int]]? = nil) {
        self.offset = offset; self.path = path; self.node = node; self.readerNode = readerNode; self.gaps = gaps
    }

    /// Display offset within the node → raw code-point offset in the source text node.
    public func rawOffset(_ display: Int) -> Int {
        guard let bp = gaps?.last(where: { $0[0] <= display }) else { return display }
        return bp[1] + (display - bp[0])
    }

    /// Raw code-point offset in the source text node → display offset within the node.
    public func displayOffset(_ raw: Int) -> Int {
        guard let bp = gaps?.last(where: { $0[1] <= raw }) else { return raw }
        return bp[0] + max(0, raw - bp[1])
    }
}

public struct SourceRef: Codable, Equatable, Sendable {
    public var spineIndex: Int
    public var href: String
    /// KOReader-style element path, e.g. `/body/DocFragment[3]/body/div/p[12]`.
    public var xpointer: String
}

// MARK: - Timing (timing/chNNN.json)

public struct ChapterTiming: Codable, Equatable, Sendable {
    public var index: Int
    public var duration: TimeInterval
    /// Indexed by sentence id: start/end seconds inside the chapter audio.
    public var sentences: [SentenceTiming]

    public func sentence(at time: TimeInterval) -> Int? {
        // Binary search on start times.
        var lo = 0, hi = sentences.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if sentences[mid].start <= time { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found.map { sentences[$0].id }
    }
}

public struct SentenceTiming: Codable, Equatable, Sendable {
    public var id: Int
    public var start: TimeInterval
    public var end: TimeInterval
}

public extension BookManifest {
    /// Kokoro can narrate this book's language (English, Spanish). Others are text-only.
    var canNarrate: Bool { BookLanguage.hasVoice(language) }

    /// The imprint: which voice models narrated this book (usually one; two if the model
    /// changed while it was being narrated). Older bundles don't record it.
    var narrationModels: [String] {
        var seen: [String] = []
        for c in chapters where c.audioStatus == .ready {
            if let m = c.model, !seen.contains(m) { seen.append(m) }
        }
        return seen
    }

    /// Stand-in for a book whose files are gone (e.g. a restored reader window after deletion).
    static func missing(id: String) -> BookManifest {
        BookManifest(id: id, title: "This book was deleted", author: "", language: "en", sourceFileName: "",
                     koreaderDigest: "", accentColor: "#A7BFD6", createdAt: Date(), updatedAt: Date(),
                     revision: 0, chapters: [], files: [])
    }
}
