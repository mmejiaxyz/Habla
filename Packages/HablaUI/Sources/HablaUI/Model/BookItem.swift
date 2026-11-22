import Foundation
import HablaCore

/// What the screens show for a book. Built from a local bundle and/or the Mac's
/// library listing, plus the reading position.
public struct BookItem: Identifiable, Hashable, Sendable {
    public enum Availability: Hashable, Sendable {
        /// Downloaded to this device (iPhone) / in the library (Mac).
        case local
        /// On the Mac, not on this phone yet.
        case remote(bytes: Int)
        case downloading(fraction: Double)
    }

    public var id: String
    public var title: String
    public var author: String
    public var chapters: [ChapterItem]
    public var position: ReadingPosition?
    public var availability: Availability
    /// Narrated chapters / narratable chapters (front matter excluded).
    public var narrated: Int
    public var narratable: Int
    public var duration: TimeInterval
    public var revision: Int

    public init(id: String, title: String, author: String, chapters: [ChapterItem], position: ReadingPosition?,
                availability: Availability, narrated: Int, narratable: Int, duration: TimeInterval, revision: Int) {
        self.id = id; self.title = title; self.author = author; self.chapters = chapters; self.position = position
        self.availability = availability; self.narrated = narrated; self.narratable = narratable
        self.duration = duration; self.revision = revision
    }

    public init(manifest m: BookManifest, position: ReadingPosition?, availability: Availability = .local) {
        let chapters = m.chapters.map(ChapterItem.init(info:))
        self.init(id: m.id, title: m.title, author: m.author, chapters: chapters, position: position,
                  availability: availability,
                  narrated: m.chapters.filter { $0.audioStatus == .ready }.count,
                  narratable: m.chapters.filter { $0.audioStatus != .skipped }.count,
                  duration: m.totalDuration, revision: m.revision)
    }

    public init(entry e: LibraryEntry, position: ReadingPosition?, availability: Availability) {
        self.init(id: e.id, title: e.title, author: e.author, chapters: [], position: position,
                  availability: availability, narrated: e.readyChapters,
                  narratable: (e.language.map(BookLanguage.hasVoice) ?? true) ? e.chapterCount : 0,
                  duration: e.totalDuration, revision: e.revision)
    }

    // MARK: Derived

    public var progress: Double { position?.fraction ?? 0 }
    public var isStarted: Bool { position != nil }
    public var isFullyNarrated: Bool { narratable > 0 && narrated >= narratable }
    public var hasAudio: Bool { narrated > 0 }
    /// Nothing to narrate: the book's language has no voice yet (German, Russian, Ukrainian).
    public var isTextOnly: Bool { narratable == 0 }

    /// The chapter to resume: saved position, else the first non-front-matter chapter.
    public var resumeChapter: Int {
        if let c = position?.chapter, chapters.contains(where: { $0.index == c }) { return c }
        return chapters.first { !$0.isFrontMatter }?.index ?? chapters.first?.index ?? 0
    }

    public var currentChapter: ChapterItem? { chapters.first { $0.index == resumeChapter } }

    /// Narrated time left: the rest of the current chapter (from the audio position when
    /// listening) plus every later narrated chapter.
    public var minutesLeft: Int? {
        guard duration > 0 else { return nil }
        let current = resumeChapter
        let later = chapters.filter { $0.index > current }.compactMap(\.duration).reduce(0, +)
        let here = chapters.first { $0.index == current }?.duration ?? 0
        let elapsed = position?.mode == .listening ? (position?.audioTime ?? 0) : here / 2
        return Int(((later + max(0, here - elapsed)) / 60).rounded())
    }
}

public struct ChapterItem: Identifiable, Hashable, Sendable {
    public var index: Int
    public var title: String
    public var duration: TimeInterval?
    public var isFrontMatter: Bool
    public var hasAudio: Bool
    public var id: Int { index }

    public init(index: Int, title: String, duration: TimeInterval?, isFrontMatter: Bool, hasAudio: Bool) {
        self.index = index; self.title = title; self.duration = duration
        self.isFrontMatter = isFrontMatter; self.hasAudio = hasAudio
    }

    init(info c: ChapterInfo) {
        self.init(index: c.index, title: ChapterNaming.title(c), duration: c.duration, isFrontMatter: c.isFrontMatter,
                  hasAudio: c.audioStatus == .ready)
    }

    public var minutes: Int? { duration.map { max(1, Int(($0 / 60).rounded())) } }
}

/// How chapters are named on screen. Books often title chapters just "IV" or "12";
/// those read as "Chapter IV". Front matter keeps its own title.
public enum ChapterNaming {
    public static func title(_ raw: String, isFrontMatter: Bool) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isFrontMatter, !t.isEmpty else { return t.isEmpty ? "Untitled" : t }
        let core = t.trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
        let isRoman = core.count <= 8 && core.allSatisfy { "IVXLCDMivxlcdm".contains($0) }
        let isNumber = core.allSatisfy(\.isNumber)
        return (isRoman || isNumber) ? "Chapter \(core.uppercased())" : t
    }

    public static func title(_ info: ChapterInfo) -> String { title(info.title, isFrontMatter: info.isFrontMatter) }

    public static func title(of chapter: Int, in m: BookManifest?) -> String {
        guard let info = m?.chapters.first(where: { $0.index == chapter }) else { return "" }
        return title(info)
    }
}

public enum Format {
    public static func duration(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(max(m, 1)) min"
    }

    public static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    public static func bytes(_ b: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false   // "0 KB", not "Zero KB"
        return f.string(fromByteCount: Int64(b))
    }

    public static func ago(_ d: Date?) -> String {
        guard let d else { return "never" }
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 { return "\(Int(s / 3600)) h ago" }
        return d.formatted(date: .abbreviated, time: .omitted)
    }
}
