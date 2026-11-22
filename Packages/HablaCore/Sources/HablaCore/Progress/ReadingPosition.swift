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
    /// Books changed on this device and not yet acknowledged by the Mac (book → change number).
    /// Sync sends exactly these and takes the Mac's answer as final for everything else, so
    /// device clocks never decide what gets sent.
    private var pendingChanges: [String: Int] = [:]
    private var changeCounter = 0
    private var pendingURL: URL { fileURL.deletingPathExtension().appendingPathExtension("pending.json") }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        positions = [:]
        if let d = try? Data(contentsOf: fileURL.deletingPathExtension().appendingPathExtension("pending.json")),
           let ids = try? JSONDecoder().decode([String].self, from: d) {
            for id in ids { changeCounter += 1; pendingChanges[id] = changeCounter }
        }
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

    /// A place this device just reached (reading or listening). It always becomes this
    /// device's position, even if the clock was moved back: its time is pushed just past the
    /// one it replaces. It is sent to the Mac on the next sync.
    @discardableResult
    public func record(_ local: ReadingPosition) -> ReadingPosition {
        var p = local
        let saved: ReadingPosition = lock.withLock {
            if let old = positions[p.bookID], old.updatedAt >= p.updatedAt {
                p.updatedAt = old.updatedAt.addingTimeInterval(0.001)
            }
            positions[p.bookID] = p
            changeCounter += 1
            pendingChanges[p.bookID] = changeCounter
            return p
        }
        save()
        return saved
    }

    /// Local changes waiting for the Mac, with their change numbers.
    public var pending: [(position: ReadingPosition, change: Int)] {
        lock.withLock { pendingChanges.compactMap { id, n in positions[id].map { ($0, n) } } }
    }

    /// The Mac answered a pushed change: its winner becomes ours, unless the book moved again meanwhile.
    public func acknowledge(_ winner: ReadingPosition, change: Int) {
        lock.withLock {
            guard pendingChanges[winner.bookID] == change else { return }
            pendingChanges[winner.bookID] = nil
            positions[winner.bookID] = winner
        }
        save()
    }

    /// The Mac's position for a book this device hasn't changed since: taken as is.
    public func adopt(_ remote: ReadingPosition) {
        lock.withLock {
            guard pendingChanges[remote.bookID] == nil else { return }
            positions[remote.bookID] = remote
        }
        save()
    }

    /// Marks books as changed here (e.g. positions saved by an older version, never sent).
    public func markPending(_ bookIDs: [String]) {
        guard !bookIDs.isEmpty else { return }
        lock.withLock { for id in bookIDs where positions[id] != nil { changeCounter += 1; pendingChanges[id] = changeCounter } }
        save()
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
            try? JSONEncoder().encode(Array(pendingChanges.keys)).write(to: pendingURL, options: .atomic)
        }
    }

    /// Positions changed after a date (only those need sending).
    public func changed(since date: Date?) -> [ReadingPosition] {
        guard let date, date <= Date() else { return all }   // a date in the future = clock moved back
        return all.filter { $0.updatedAt > date }
    }
}
