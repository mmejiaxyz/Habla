import Foundation
import SwiftUI
import HablaCore
#if canImport(UIKit)
import UIKit
#endif

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
    /// The paired Mac (nil until you pair).
    @Published public private(set) var paired: PairedMac? = PhoneStore.loadPaired()
    /// Habla Studios on this Wi-Fi (several Macs can be listed; only the paired one is used).
    @Published public private(set) var nearby: [ServiceBrowser.Service] = []
    @Published public private(set) var pairingBusy = false
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

    // MARK: Mac connection (paired, encrypted)

    /// The one Mac this iPhone is paired with. Other Macs on the same Wi-Fi are listed but
    /// never used until you pair with them; the connection is pinned to this Mac's certificate.
    public struct PairedMac: Codable, Equatable, Sendable {
        public var libraryID: String
        public var name: String
        /// SHA-256 of the Mac's TLS certificate ("" for a Mac without encryption).
        public var fingerprint: String
        public var lastURL: URL?
        public init(libraryID: String, name: String, fingerprint: String, lastURL: URL? = nil) {
            self.libraryID = libraryID; self.name = name; self.fingerprint = fingerprint; self.lastURL = lastURL
        }
    }

    var client: SyncClient? {
        guard case let .connected(_, url) = connection, let mac = paired, let token = Keychain.get(mac.libraryID) else { return nil }
        return SyncClient(baseURL: url, accessToken: token, session: session(for: mac))
    }

    private var sessions: [String: URLSession] = [:]
    func session(for mac: PairedMac) -> URLSession {
        if let s = sessions[mac.fingerprint] { return s }
        let s = PinnedTrust(fingerprint: mac.fingerprint.isEmpty ? nil : mac.fingerprint).session()
        sessions[mac.fingerprint] = s
        return s
    }

    static func loadPaired() -> PairedMac? {
        UserDefaults.standard.data(forKey: "habla.pairedMac").flatMap { try? JSONDecoder().decode(PairedMac.self, from: $0) }
    }

    func savePaired() {
        UserDefaults.standard.set(paired.flatMap { try? JSONEncoder().encode($0) }, forKey: "habla.pairedMac")
    }

    /// Starts looking for Macs (Bonjour) and syncs as soon as the paired one is found.
    public func start() {
        browser.stop()
        browser.onChange = { [weak self] services in
            Task { @MainActor in
                guard let self else { return }
                self.nearby = services.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                guard let mac = self.paired, let s = services.first(where: { $0.libraryID == mac.libraryID }) else { return }
                if case .connected(_, let url) = self.connection, url == s.url { return }
                self.connection = .connected(name: s.name, url: s.url)
                await self.sync()
            }
        }
        browser.start()
        Task { await sync() }
        checkForAppUpdate()
    }

    // MARK: Pairing

    var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    /// Pairs with a Mac found on the network (or typed address) using the code it shows.
    public func pair(at url: URL, code: String) async {
        guard !Pairing.normalize(code).isEmpty else { error = "Type the code shown in Habla on your Mac."; return }
        pairingBusy = true
        defer { pairingBusy = false }
        // First contact: record the certificate this Mac presents; the proof binds the code to it.
        let trust = PinnedTrust(fingerprint: nil)
        let probe = SyncClient(baseURL: url, session: trust.session())
        do {
            let hello = try await probe.hello()
            let fp = url.scheme == "https" ? (trust.seen ?? "") : ""
            try await finishPairing(url: url, hello: hello, fingerprint: fp, code: code, session: trust.session())
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// Pairs from the QR code (the camera opens a habla://pair link): the certificate is known
    /// in advance, so the connection is pinned from the first byte.
    public func pair(invite: PairingInvite) async {
        pairingBusy = true
        defer { pairingBusy = false }
        // Where is it? Bonjour (same library id), else the address in the QR code.
        var url = nearby.first { $0.libraryID == invite.libraryID }?.url
        for _ in 0..<20 where url == nil {
            try? await Task.sleep(nanoseconds: 250_000_000)
            url = nearby.first { $0.libraryID == invite.libraryID }?.url
        }
        if url == nil, let a = invite.address { url = URL(string: "https://\(a)") }
        guard let url else { error = "Couldn't find “\(invite.name)”. Is this iPhone on the same Wi-Fi as the Mac?"; return }
        let trust = PinnedTrust(fingerprint: invite.fingerprint)
        do {
            let hello = try await SyncClient(baseURL: url, session: trust.session()).hello()
            guard hello.libraryID == invite.libraryID else { throw SyncError.pairing("That code belongs to a different Mac.") }
            try await finishPairing(url: url, hello: hello, fingerprint: invite.fingerprint, code: invite.code, session: trust.session())
        } catch {
            self.error = Self.describe(error)
        }
    }

    private func finishPairing(url: URL, hello: ServerHello, fingerprint: String, code: String, session: URLSession) async throws {
        let client = SyncClient(baseURL: url, session: session)
        let r = try await client.pair(code: code, fingerprint: fingerprint, deviceID: deviceID, deviceName: deviceName)
        Keychain.set(r.token, for: r.libraryID)
        if let old = paired, old.libraryID != r.libraryID { Keychain.delete(old.libraryID) }
        paired = PairedMac(libraryID: r.libraryID, name: r.name, fingerprint: fingerprint, lastURL: url)
        savePaired()
        lastPush = nil   // a new Mac gets every position once
        connection = .connected(name: r.name, url: url)
        error = nil
        await sync()
    }

    /// Forgets the paired Mac on this iPhone (downloaded books stay).
    public func unpair() {
        if let mac = paired { Keychain.delete(mac.libraryID) }
        paired = nil
        savePaired()
        remote = []
        connection = .searching
        lastSync = nil
        reloadLocal()
    }

    /// Typed address → hello, so it can be offered for pairing like a Bonjour find.
    public func lookUp(address: String) async -> ServiceBrowser.Service? {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return nil }
        for scheme in ["https", "http"] {
            guard var c = URLComponents(string: a.contains("://") ? a : "\(scheme)://\(a)") else { continue }
            if c.port == nil { c.port = Int(SyncProtocol.defaultPort) }
            guard let url = c.url, url.host?.isEmpty == false else { continue }
            let probe = SyncClient(baseURL: url, session: PinnedTrust(fingerprint: nil).session(timeout: 5))
            if let hello = try? await probe.hello() {
                return ServiceBrowser.Service(name: hello.name, url: url, libraryID: hello.libraryID)
            }
        }
        error = "Habla isn’t running at “\(a)”. Check the address shown in Habla on your Mac."
        return nil
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
        guard let mac = paired else { connection = .searching; return }
        if client == nil, let url = mac.lastURL { connection = .connected(name: mac.name, url: url) }
        guard let client else {
            if case .searching = connection {} else { connection = .searching }
            return
        }
        do {
            remote = try await client.library()
            if case .connected(_, let url) = connection, paired?.lastURL != url { paired?.lastURL = url; savePaired() }
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
        } catch SyncError.notPaired {
            // The Mac forgot this iPhone: say so, keep the books.
            unpair()
            error = "Your Mac no longer recognises this iPhone. Pair again from the Mac screen."
        } catch {
            connection = .unreachable(Self.describe(error))
        }
        reloadLocal()
    }

    // MARK: Downloads

    /// Downloads (or updates) a book from the Mac. Interrupted downloads resume: files
    /// already verified are kept, and the manifest is written last.
    /// Re-checks every file of a book against the Mac (fixes silently damaged downloads).
    public func repair(_ id: String) async {
        guard let client else { error = "Open Habla on your Mac to repair this book."; return }
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
    public func previewState(remote: [LibraryEntry], connection: Connection, lastSync: Date?, downloading: [String: Double] = [:],
                             paired: PairedMac? = nil, nearby: [ServiceBrowser.Service] = []) {
        self.paired = paired
        self.nearby = nearby
        self.remote = remote
        self.connection = connection
        self.lastSync = lastSync
        self.downloading = downloading
        reloadLocal()
    }
}
