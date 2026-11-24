import Foundation

/// A place the reader marked in a book: a **bookmark** (a sentence) or an **underline** (a span
/// inside a sentence). Anchored to sentences, so it survives text size, theme and re-layout.
/// Removing one leaves a tombstone (`deleted`) so the removal reaches every device.
public struct Marker: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case bookmark, underline }

    public var id: UUID
    public var bookID: String
    public var kind: Kind
    public var chapter: Int
    public var sentence: Int
    /// Underline span, in UTF-16 units inside the sentence's text.
    public var offset: Int?
    public var length: Int?
    /// The underlined words, or the start of the bookmarked sentence.
    public var text: String
    public var note: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deleted: Bool
    public var deviceID: String

    public init(id: UUID = UUID(), bookID: String, kind: Kind, chapter: Int, sentence: Int, offset: Int? = nil,
                length: Int? = nil, text: String, note: String? = nil, createdAt: Date = Date(), deviceID: String) {
        self.id = id; self.bookID = bookID; self.kind = kind; self.chapter = chapter; self.sentence = sentence
        self.offset = offset; self.length = length; self.text = String(text.prefix(kind == .bookmark ? 160 : 2000))
        self.note = note; self.createdAt = createdAt; self.updatedAt = createdAt; self.deleted = false; self.deviceID = deviceID
    }

    /// Latest edit wins; on a tie a removal wins (a mark never comes back by accident).
    static func newer(_ a: Marker, _ b: Marker) -> Marker {
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt ? a : b }
        return a.deleted ? a : b
    }
}

/// Every book's markers in one small JSON file (`markers.json`, next to the library). Thread-safe.
public final class MarkerStore: @unchecked Sendable {
    public let fileURL: URL
    public let deviceID: String
    private let lock = NSLock()
    private var byID: [UUID: Marker] = [:]
    /// Called after any change (on the caller's thread).
    public var onChange: (@Sendable () -> Void)?

    public init(fileURL: URL, deviceID: String) {
        self.fileURL = fileURL
        self.deviceID = deviceID
        if let data = try? Data(contentsOf: fileURL), let list = try? JSON.decoder.decode([Marker].self, from: data) {
            for m in list { byID[m.id] = m }
        } else {
            migrateUnderlines()
        }
    }

    /// The one store of a library folder (`<library>/../markers.json`), shared by the reader and sync.
    /// The first caller names the device; later callers get the same store.
    public static func forLibrary(_ library: URL, deviceID: String? = nil) -> MarkerStore {
        let url = library.standardizedFileURL.deletingLastPathComponent().appendingPathComponent("markers.json")
        return cacheLock.withLock {
            if let s = cache[url] { return s }
            let s = MarkerStore(fileURL: url, deviceID: deviceID ?? UserDefaults.standard.string(forKey: "habla.deviceID") ?? "device")
            cache[url] = s
            return s
        }
    }
    nonisolated(unsafe) private static var cache: [URL: MarkerStore] = [:]
    private static let cacheLock = NSLock()

    /// The reader's underlines used to live in `annotations.json` (book → underlines).
    private func migrateUnderlines() {
        struct OldUnderline: Decodable { var id: UUID; var chapter: Int; var sentence: Int; var offset: Int; var length: Int; var text: String; var created: Date }
        let old = fileURL.deletingLastPathComponent().appendingPathComponent("annotations.json")
        guard let data = try? Data(contentsOf: old),
              let books = try? JSONDecoder().decode([String: [OldUnderline]].self, from: data) else { return }
        for (book, list) in books {
            for u in list {
                byID[u.id] = Marker(id: u.id, bookID: book, kind: .underline, chapter: u.chapter, sentence: u.sentence,
                                    offset: u.offset, length: u.length, text: u.text, createdAt: u.created, deviceID: deviceID)
            }
        }
        save()
    }

    /// Live markers of a book (optionally one chapter), in reading order.
    public func markers(book: String, chapter: Int? = nil, kind: Marker.Kind? = nil) -> [Marker] {
        lock.withLock {
            byID.values.filter { !$0.deleted && $0.bookID == book && (chapter == nil || $0.chapter == chapter) && (kind == nil || $0.kind == kind) }
        }.sorted { ($0.chapter, $0.sentence, $0.offset ?? -1) < ($1.chapter, $1.sentence, $1.offset ?? -1) }
    }

    /// Everything, tombstones included (what sync sends).
    public var all: [Marker] { lock.withLock { Array(byID.values) } }

    public func add(_ m: Marker) {
        var m = m
        m.deviceID = deviceID
        lock.withLock { byID[m.id] = m }
        changed()
    }

    public func update(_ m: Marker) {
        var m = m
        m.updatedAt = Date(); m.deviceID = deviceID
        lock.withLock { byID[m.id] = m }
        changed()
    }

    public func remove(_ id: UUID) {
        let done: Bool = lock.withLock {
            guard var m = byID[id], !m.deleted else { return false }
            m.deleted = true; m.updatedAt = Date(); m.deviceID = deviceID
            byID[id] = m
            return true
        }
        if done { changed() }
    }

    /// Takes markers from another device; returns whether anything changed here.
    @discardableResult
    public func merge(_ incoming: [Marker]) -> Bool {
        let limit = Date().addingTimeInterval(5)
        let changedAny: Bool = lock.withLock {
            var any = false
            for var m in incoming {
                m.updatedAt = min(m.updatedAt, limit)               // a clock that ran ahead can't win forever
                let w = byID[m.id].map { Marker.newer($0, m) } ?? m
                if w != byID[m.id] { byID[m.id] = w; any = true }
            }
            return any
        }
        if changedAny { changed() }
        return changedAny
    }

    private func changed() { save(); onChange?() }

    private func save() {
        lock.withLock {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let list = byID.values.sorted { $0.id.uuidString < $1.id.uuidString }
            try? JSON.encoder.encode(list).write(to: fileURL, options: .atomic)
        }
    }
}
