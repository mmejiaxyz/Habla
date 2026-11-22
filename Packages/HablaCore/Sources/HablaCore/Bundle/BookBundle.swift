import Foundation
import CryptoKit

/// A processed book on disk: `<id>.habla/` containing manifest, text, audio, timing.
/// The Mac writes bundles; the iPhone receives copies of them via sync.
public struct BookBundle: Sendable {
    public static let fileExtension = "habla"
    public static let manifestFile = "manifest.json"

    public let url: URL

    public init(url: URL) { self.url = url }

    public static func url(for id: String, in library: URL) -> URL {
        library.appendingPathComponent("\(id).\(fileExtension)", isDirectory: true)
    }

    /// A path a manifest may name: relative, inside the bundle, no `..`/`.` steps, no
    /// backslashes or NULs. Anything else could write outside the library when syncing.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\\"), !path.contains("\u{0}") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    public func fileURL(_ path: String) -> URL { url.appendingPathComponent(path) }

    public static func textPath(_ i: Int) -> String { String(format: "text/ch%03d.json", i) }
    public static func audioPath(_ i: Int) -> String { String(format: "audio/ch%03d.m4a", i) }
    public static func timingPath(_ i: Int) -> String { String(format: "timing/ch%03d.json", i) }

    // MARK: Reading

    public func manifest() throws -> BookManifest {
        try JSON.decoder.decode(BookManifest.self, from: Data(contentsOf: fileURL(Self.manifestFile)))
    }

    public func chapterText(_ info: ChapterInfo) throws -> ChapterText {
        try JSON.decoder.decode(ChapterText.self, from: Data(contentsOf: fileURL(info.textFile)))
    }

    public func timing(_ info: ChapterInfo) throws -> ChapterTiming? {
        guard let path = info.timingFile, FileManager.default.fileExists(atPath: fileURL(path).path) else { return nil }
        return try JSON.decoder.decode(ChapterTiming.self, from: Data(contentsOf: fileURL(path)))
    }

    // MARK: Writing

    public func write<T: Encodable>(_ value: T, to path: String, pretty: Bool = false) throws {
        let dest = fileURL(path)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (pretty ? JSON.prettyEncoder : JSON.encoder).encode(value).write(to: dest, options: .atomic)
    }

    /// Re-indexes every file (sizes + hashes), bumps the revision and saves the manifest.
    @discardableResult
    public func commit(_ manifest: BookManifest) throws -> BookManifest {
        var m = manifest
        m.files = try indexFiles(previous: manifest.files, since: manifest.updatedAt)
        m.revision += 1
        m.updatedAt = Date()
        try write(m, to: Self.manifestFile, pretty: true)
        return m
    }

    func indexFiles(previous: [FileEntry], since: Date? = nil) throws -> [FileEntry] {
        let known = Dictionary(previous.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) else { return [] }
        let base = url.standardizedFileURL.path
        var out: [FileEntry] = []
        for case let file as URL in walker {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            var rel = String(file.standardizedFileURL.path.dropFirst(base.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            if rel == Self.manifestFile || rel.hasPrefix(".") || rel.contains("/.") { continue }
            // Work files from an interrupted render are never part of the book.
            if rel.hasSuffix(".part") || rel.hasSuffix(".writing.m4a") { continue }
            // Unchanged since the last commit: same size and exactly the same modification time
            // as recorded then. (Comparing against the commit date broke when the clock moved back.)
            let mod = values.contentModificationDate
            if let k = known[rel], k.size == values.fileSize, let kMod = k.modified, let mod,
               abs(kMod.timeIntervalSince(mod)) < 0.002 {   // manifests keep milliseconds
                out.append(k); continue
            }
            _ = since
            out.append(FileEntry(path: rel, size: values.fileSize ?? 0, sha256: try Self.sha256(of: file), modified: mod))
        }
        return out.sorted { $0.path < $1.path }
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Single-file export (AirDrop / Files fallback)

    /// Packs the bundle into one `.habla` file (a ZIP) for AirDrop or the Files app.
    public func exportArchive() throws -> Data {
        let m = try manifest()
        var zip = ZipWriter()
        zip.add(Self.manifestFile, data: try Data(contentsOf: fileURL(Self.manifestFile)))
        for f in m.files { zip.add(f.path, data: try Data(contentsOf: fileURL(f.path))) }
        return zip.finalize()
    }

    /// Unpacks a `.habla` archive into `library`, replacing any older copy.
    @discardableResult
    public static func importArchive(_ data: Data, into library: URL) throws -> BookBundle {
        let zip = try ZipArchive(data: data)
        let manifest = try JSON.decoder.decode(BookManifest.self, from: zip.read(manifestFile))
        let dest = url(for: manifest.id, in: library)
        let staging = library.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        for path in zip.entries.keys where !path.hasSuffix("/") {
            guard !path.contains("..") else { continue }
            let target = staging.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try zip.read(path).write(to: target)
        }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: staging, to: dest)
        return BookBundle(url: dest)
    }
}

public enum JSON {
    /// ISO 8601 with milliseconds: positions saved within the same second must still order correctly.
    static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
    static let encodeDate: JSONEncoder.DateEncodingStrategy = .custom { date, enc in
        var c = enc.singleValueContainer()
        try c.encode(formatter().string(from: date))
    }
    static let decodeDate: JSONDecoder.DateDecodingStrategy = .custom { dec in
        let c = try dec.singleValueContainer()
        let s = try c.decode(String.self)
        if let d = formatter().date(from: s) ?? ISO8601DateFormatter().date(from: s) { return d }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = encodeDate
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    public static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = encodeDate
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = decodeDate
        return d
    }()
}
