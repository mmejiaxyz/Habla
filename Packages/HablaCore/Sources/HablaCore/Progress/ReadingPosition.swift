import Foundation

/// Where you are in a book. Shared by listening and reading, so switching
/// modes (or devices) lands on the same sentence.
public struct ReadingPosition: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Hashable, Sendable { case listening, reading }

    public var bookID: String
    public var chapter: Int
    public var sentence: Int
    /// Seconds into the chapter audio, when known (more precise than the sentence start).
    public var audioTime: TimeInterval?
    public var mode: Mode
    public var updatedAt: Date
    public var deviceID: String
    /// 0…1 through the whole book, for display and KOReader's `percentage`.
    public var fraction: Double?

    public init(bookID: String, chapter: Int, sentence: Int, audioTime: TimeInterval? = nil,
                mode: Mode, updatedAt: Date = Date(), deviceID: String, fraction: Double? = nil) {
        self.bookID = bookID; self.chapter = chapter; self.sentence = sentence; self.audioTime = audioTime
        self.mode = mode; self.updatedAt = updatedAt; self.deviceID = deviceID; self.fraction = fraction
    }

    /// Latest update wins; ties go to the larger position so nothing moves backwards.
    public static func merge(_ a: ReadingPosition?, _ b: ReadingPosition?) -> ReadingPosition? {
        guard let a else { return b }
        guard let b else { return a }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt ? a : b }
        return (a.chapter, a.sentence) >= (b.chapter, b.sentence) ? a : b
    }
}

public extension BookManifest {
    /// Fraction of the book's words before a position (front matter excluded).
    func fraction(chapter: Int, sentence: Int) -> Double {
        let body = chapters.filter { !$0.isFrontMatter }
        let total = body.reduce(0) { $0 + $1.sentenceCount }
        guard total > 0 else { return 0 }
        let before = body.filter { $0.index < chapter }.reduce(0) { $0 + $1.sentenceCount }
        let inChapter = body.contains { $0.index == chapter } ? sentence : 0
        return min(1, Double(before + inChapter) / Double(total))
    }
}

/// Positions persisted as one small JSON file. Thread-safe.
public final class ProgressStore: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    private var positions: [String: ReadingPosition]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        positions = [:]
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // Entry by entry: one bad record must never cost every other book its place.
        if let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (id, value) in raw {
                guard let d = try? JSONSerialization.data(withJSONObject: value),
                      var p = try? JSON.decoder.decode(ReadingPosition.self, from: d) else { continue }
                p.updatedAt = min(p.updatedAt, Date())          // a clock that ran ahead can't win forever
                positions[id] = p
            }
            if positions.count < raw.count { keepCopy(of: data) }
        } else {
            keepCopy(of: data)                                   // unreadable file: keep it aside, start fresh
        }
    }

    private func keepCopy(of data: Data) {
        let copy = fileURL.deletingPathExtension().appendingPathExtension("damaged.json")
        try? data.write(to: copy, options: .atomic)
    }

    public func position(for bookID: String) -> ReadingPosition? {
        lock.withLock { positions[bookID] }
    }

    public var all: [ReadingPosition] { lock.withLock { Array(positions.values) } }

    /// Merges an incoming position (local save or from another device); returns the winner.
    @discardableResult
    public func merge(_ incoming: ReadingPosition) -> ReadingPosition {
        var incoming = incoming
        incoming.updatedAt = min(incoming.updatedAt, Date().addingTimeInterval(5))
        let winner: ReadingPosition = lock.withLock {
            let w = ReadingPosition.merge(positions[incoming.bookID], incoming)!
            positions[incoming.bookID] = w
            return w
        }
        save()
        return winner
    }

    public func remove(_ bookID: String) {
        _ = lock.withLock { positions.removeValue(forKey: bookID) }
        save()
    }

    /// Written under the lock, so an older snapshot can never overwrite a newer one.
    private func save() {
        lock.withLock {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSON.encoder.encode(positions).write(to: fileURL, options: .atomic)
        }
    }

    /// Positions changed after a date (only those need sending).
    public func changed(since date: Date?) -> [ReadingPosition] {
        guard let date else { return all }
        return all.filter { $0.updatedAt > date }
    }
}
