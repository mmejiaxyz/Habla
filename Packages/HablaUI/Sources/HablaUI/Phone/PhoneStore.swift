import Foundation
import SwiftUI
import HablaCore

/// The iPhone app's state: downloaded books, the Mac connection, sync and positions.
/// Everything works offline; the Mac is only needed to get books and share positions.
@MainActor
public final class PhoneStore: ObservableObject {
    public enum Connection: Equatable {
        case searching
        case connected(name: String, url: URL)
        case unreachable(String)
    }

    @Published public private(set) var books: [BookItem] = []
    @Published public private(set) var connection: Connection = .searching
    @Published public private(set) var lastSync: Date?
    @Published public private(set) var syncing = false
    @Published public var error: String?
    @Published public var manualAddress: String = UserDefaults.standard.string(forKey: "habla.manualAddress") ?? "" {
        didSet { UserDefaults.standard.set(manualAddress, forKey: "habla.manualAddress") }
    }
    @Published public var readerStyle: ReaderStyle = PhoneStore.loadStyle() {
        didSet { if let d = try? JSONEncoder().encode([readerStyle.theme.rawValue, "\(readerStyle.fontSize)"]) { UserDefaults.standard.set(d, forKey: "habla.style") } }
    }

    public let library: URL
    public let progress: ProgressStore
    public let deviceID: String
    var remote: [LibraryEntry] = []
    var downloading: [String: Double] = [:]
    /// Books being refreshed in the background (new chapters): they stay fully usable.
    @Published public private(set) var updating: Set<String> = []
    /// A newer Habla for iPhone published on GitHub (installed through AltStore).
    @Published public private(set) var appUpdate: AppUpdate?
    private var lastUpdateCheck: Date?
    /// Books added on the iPhone that still have to reach the Mac (ids; the EPUB is in Originals).
    @Published public private(set) var outbox: [String] = UserDefaults.standard.stringArray(forKey: "habla.outbox") ?? [] {
        didSet { UserDefaults.standard.set(outbox, forKey: "habla.outbox") }
    }
    @Published public private(set) var importing = 0
    private var lastPush: Date? = UserDefaults.standard.object(forKey: "habla.lastPush") as? Date
    private var lastURL: URL? = UserDefaults.standard.url(forKey: "habla.lastMac")
    private let browser = ServiceBrowser()
    private var pushTask: Task<Void, Never>?
    private var pendingPush = false

    public init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Habla", isDirectory: true)
        library = base.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        // Audio is re-downloadable: keep it out of iCloud backups.
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var lib = library; try? lib.setResourceValues(values)
        progress = ProgressStore(fileURL: base.appendingPathComponent("progress.json"))
        if let id = UserDefaults.standard.string(forKey: "habla.deviceID") { deviceID = id }
        else { deviceID = "iphone-" + UUID().uuidString.prefix(8).lowercased(); UserDefaults.standard.set(deviceID, forKey: "habla.deviceID") }
        reloadLocal()
    }

    static func loadStyle() -> ReaderStyle {
        guard let d = UserDefaults.standard.data(forKey: "habla.style"),
              let a = try? JSONDecoder().decode([String].self, from: d), a.count == 2,
              let t = ReaderTheme(rawValue: a[0]), let s = Double(a[1]) else { return ReaderStyle() }
        return ReaderStyle(theme: t, fontSize: CGFloat(s))
    }

    // MARK: Local library

    public func bundle(_ id: String) -> BookBundle { BookBundle(url: BookBundle.url(for: id, in: library)) }
    public func manifest(_ id: String) -> BookManifest? { try? bundle(id).manifest() }

    func localManifests() -> [BookManifest] {
        ((try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == BookBundle.fileExtension }
            .compactMap { try? BookBundle(url: $0).manifest() }
    }

    public func reloadLocal() {
        let local = localManifests()
        var items = local.map { BookItem(manifest: $0, position: progress.position(for: $0.id)) }
        let localIDs = Set(local.map(\.id))
        for e in remote where !localIDs.contains(e.id) {
            let avail: BookItem.Availability = downloading[e.id].map { .downloading(fraction: $0) } ?? .remote(bytes: e.totalBytes)
            items.append(BookItem(entry: e, position: progress.position(for: e.id), availability: avail))
        }
        for i in items.indices { if let f = downloading[items[i].id], items[i].availability == .local { items[i].availability = .downloading(fraction: f) } }
        // Most recently opened first, then new books, then the rest alphabetically.
        books = items.sorted { a, b in
            switch (a.position?.updatedAt, b.position?.updatedAt) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }

    public var current: BookItem? { books.first { $0.availability == .local && $0.isStarted } }

    public func delete(_ id: String) {
        try? FileManager.default.removeItem(at: BookBundle.url(for: id, in: library))
        reloadLocal()
    }

    // MARK: Adding books on the iPhone

    /// Imports EPUBs (Files picker, "Open in Habla", share sheet). The text is readable at once;
    /// the book goes to the Mac, which narrates it, and the audio arrives on the next sync.
    public func importBooks(_ urls: [URL]) {
        let epubs = urls.filter { $0.pathExtension.lowercased() == "epub" }
        guard !epubs.isEmpty else { error = "Only EPUB books can be added."; return }
        importing += epubs.count
        let lib = library
        Task.detached(priority: .userInitiated) {
            var added: [String] = [], failed: [String] = []
            for url in epubs {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    // Work on a private copy: the picked file may vanish (Inbox, iCloud placeholder).
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        .appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: tmp)
                    defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
                    let id = try DocumentDigest.sha256Prefix(of: tmp)
                    let existing = BookBundle.url(for: id, in: lib).appendingPathComponent(BookBundle.manifestFile)
                    if !FileManager.default.fileExists(atPath: existing.path) {
                        _ = try BookImporter().importEPUB(at: tmp, into: lib)
                    }
                    added.append(id)
                } catch {
                    failed.append(url.deletingPathExtension().lastPathComponent)
                }
                if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }   // "Open in" copies
            }
            let addedIDs = added, failedNames = failed
            await MainActor.run {
                self.importing -= epubs.count
                for id in addedIDs where !self.outbox.contains(id) && !self.remote.contains(where: { $0.id == id }) {
                    self.outbox.append(id)
                }
                self.reloadLocal()
                if !failedNames.isEmpty { self.error = "Couldn't open \(failedNames.joined(separator: ", ")). Is it a DRM-free EPUB?" }
                Task { await self.sendOutbox() }
            }
        }
    }

    /// Sends waiting books to the Mac (runs on every sync too; quietly waits while it's away).
    func sendOutbox() async {
        guard let client, !outbox.isEmpty else { return }
        for id in outbox {
            let epub = BookImporter.originalURL(for: id, in: library)
            guard FileManager.default.fileExists(atPath: epub.path) else { outbox.removeAll { $0 == id }; continue }
            do {
                try await client.sendBook(epub, filename: (manifest(id)?.title ?? id) + ".epub")
                outbox.removeAll { $0 == id }
                try? FileManager.default.removeItem(at: epub)   // the Mac keeps the original now
            } catch {
                return   // Mac gone or busy: try again on the next sync
            }
        }
    }

    public func isWaitingForMac(_ id: String) -> Bool { outbox.contains(id) }

    // MARK: Positions

    /// Saves locally at once; sends to the Mac in the background (coalesced).
    public func savePosition(book: String, chapter: Int, sentence: Int, audioTime: TimeInterval?, mode: ReadingPosition.Mode) {
        let fraction = manifest(book)?.fraction(chapter: chapter, sentence: sentence)
        progress.merge(ReadingPosition(bookID: book, chapter: chapter, sentence: sentence, audioTime: audioTime,
                                       mode: mode, deviceID: deviceID, fraction: fraction))
        if let i = books.firstIndex(where: { $0.id == book }) { books[i].position = progress.position(for: book) }
        schedulePush()
    }

    private func schedulePush() {
        pendingPush = true
        guard pushTask == nil else { return }
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            while self.pendingPush {
                self.pendingPush = false
                if let client = self.client {
                    let started = Date()
                    if (try? await client.syncProgress(self.progress, since: self.lastPush)) != nil {
                        self.lastPush = started; UserDefaults.standard.set(started, forKey: "habla.lastPush")
                    }
                }
            }
            self.pushTask = nil
        }
    }

    /// Where to resume a book: the newest saved place, unless it's just the player's own
    /// last save (then the player's exact audio time is better).
    public func resumePoint(for id: String, player: NarrationPlayer) -> ReadingPosition? {
        guard let p = progress.position(for: id) else { return nil }
        if player.bookID == id, p.mode == .listening, p.deviceID == deviceID,
           p.chapter == player.chapter, abs(p.sentence - player.sentence) < 3 { return nil }
        return p
    }

    // MARK: Mac connection

    var client: SyncClient? {
        if case let .connected(_, url) = connection { return SyncClient(baseURL: url, session: Self.session) }
        return nil
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 600
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()

    /// Starts looking for the Mac (Bonjour) and syncs as soon as it's found.
    public func start() {
        browser.stop()
        browser.onChange = { [weak self] services in
            Task { @MainActor in
                guard let self, let s = services.sorted(by: { $0.name < $1.name }).first else { return }
                if case .connected(_, let url) = self.connection, url == s.url { return }
                self.connection = .connected(name: s.name, url: s.url)
                await self.sync()
            }
        }
        browser.start()
        Task { await sync() }
        checkForAppUpdate()
    }

    /// At most every few hours; silent when offline.
    public func checkForAppUpdate() {
        if let last = lastUpdateCheck, Date().timeIntervalSince(last) < 4 * 3600 { return }
        lastUpdateCheck = Date()
        Task {
            let u = await AppUpdate.available()
            if u?.assets["Habla.ipa"] != nil { appUpdate = u }
        }
    }

    /// Opens Habla's AltStore source (it shows the Update button); the release page without AltStore.
    public static var altStoreURL: URL {
        var c = URLComponents(string: "altstore://source")!
        c.queryItems = [URLQueryItem(name: "url", value: AppUpdate.altStoreSource.absoluteString)]
        return c.url!
    }

    /// Full sync: find Mac → library list → update downloaded books → exchange positions.
    public func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        if client == nil, let url = manualURL() ?? lastURL { connection = .connected(name: url.host ?? "Mac", url: url) }
        guard let client else {
            if case .searching = connection {} else { connection = .searching }
            return
        }
        do {
            remote = try await client.library()
            if case .connected(_, let url) = connection { lastURL = url; UserDefaults.standard.set(url, forKey: "habla.lastMac") }
            let started = Date()
            try await client.syncProgress(progress, since: lastPush)
            lastPush = started; UserDefaults.standard.set(started, forKey: "habla.lastPush")
            lastSync = Date()
            error = nil
            await sendOutbox()
            // Bring downloaded books up to date (new chapters narrated, voice changed…) in the
            // background: the library and "Sync now" are usable meanwhile.
            let outdated = localManifests().filter { m in remote.contains { $0.id == m.id && $0.revision != m.revision } }.map(\.id)
            if !outdated.isEmpty {
                Task { for id in outdated { try? await self.download(id, silent: true) } }
            }
        } catch {
            connection = .unreachable(Self.describe(error))
        }
        reloadLocal()
    }

    func manualURL() -> URL? {
        let a = manualAddress.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return nil }
        let withScheme = a.contains("://") ? a : "http://\(a)"
        guard var c = URLComponents(string: withScheme) else { return nil }
        if c.port == nil { c.port = Int(SyncProtocol.defaultPort) }
        return c.url
    }

    public func connectManually() async {
        guard let url = manualURL(), url.host?.isEmpty == false else {
            error = "That doesn't look like an address. Type it as shown in Habla Studio, e.g. 192.168.1.20:8787."
            return
        }
        connection = .connected(name: url.host ?? "Mac", url: url)
        await sync()
    }

    // MARK: Downloads

    /// Downloads (or updates) a book from the Mac. Interrupted downloads resume: files
    /// already verified are kept, and the manifest is written last.
    /// Re-checks every file of a book against the Mac (fixes silently damaged downloads).
    public func repair(_ id: String) async {
        guard let client else { error = "Open Habla Studio on your Mac to repair this book."; return }
        updating.insert(id)
        defer { updating.remove(id); reloadLocal() }
        do { _ = try await client.syncBook(id, into: library, verify: true) }
        catch { self.error = "Couldn't repair the book: \(Self.describe(error))" }
    }

    public func download(_ id: String, silent: Bool = false) async throws {
        guard let client, downloading[id] == nil, !updating.contains(id) else { return }
        if silent { updating.insert(id) } else { downloading[id] = 0; reloadLocal() }
        defer { downloading[id] = nil; updating.remove(id); reloadLocal() }
        var attempt = 0
        while true {
            do {
                _ = try await client.syncBook(id, into: library) { done, total in
                    if silent { return }
                    Task { @MainActor in
                        self.downloading[id] = total > 0 ? Double(done) / Double(total) : 1
                        if let i = self.books.firstIndex(where: { $0.id == id }) {
                            self.books[i].availability = .downloading(fraction: self.downloading[id] ?? 0)
                        }
                    }
                }
                return
            } catch SyncError.integrity where attempt < 2 {
                attempt += 1
            } catch {
                if !silent { self.error = "Couldn't download: \(Self.describe(error))" }
                throw error
            }
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? SyncError { return e.description }
        return error.localizedDescription
    }
}

extension PhoneStore {
    /// Snapshot/preview support: state that normally comes from the network.
    public func previewState(remote: [LibraryEntry], connection: Connection, lastSync: Date?, downloading: [String: Double] = [:]) {
        self.remote = remote
        self.connection = connection
        self.lastSync = lastSync
        self.downloading = downloading
        reloadLocal()
    }
}
