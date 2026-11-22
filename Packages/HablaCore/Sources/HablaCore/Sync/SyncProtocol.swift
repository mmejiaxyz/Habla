import Foundation

/// The Mac ⇄ iPhone sync contract (HTTP over the local network, found via Bonjour).
///
///   GET  /v1/library                  → [LibraryEntry]
///   GET  /v1/books/{id}/manifest      → BookManifest
///   GET  /v1/books/{id}/files/{path}  → raw file (only paths listed in the manifest)
///   GET  /v1/progress                 → [ReadingPosition]
///   PUT  /v1/progress                 ← ReadingPosition, → winning ReadingPosition
///
/// If the server has an access token, requests must send `X-Habla-Token`.
public enum SyncProtocol {
    public static let bonjourType = "_habla._tcp"
    public static let defaultPort: UInt16 = 8787
    public static let tokenHeader = "X-Habla-Token"
    public static let version = 1
}

public struct LibraryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var author: String
    public var accentColor: String
    public var revision: Int
    public var chapterCount: Int
    public var readyChapters: Int
    public var totalDuration: TimeInterval
    public var totalBytes: Int

    public init(manifest m: BookManifest) {
        id = m.id; title = m.title; author = m.author; accentColor = m.accentColor; revision = m.revision
        chapterCount = m.chapters.count
        readyChapters = m.chapters.filter { $0.audioStatus == .ready }.count
        totalDuration = m.totalDuration
        totalBytes = m.files.reduce(0) { $0 + $1.size }
    }
}
