import Foundation
import SwiftUI
import HablaCore
import Network
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
    /// The Mac of this account found on this Wi-Fi (its certificate verified and pinned).
    @Published public private(set) var homeMac: PairedMac? = PhoneStore.loadPaired()
    /// Habla Macs on this Wi-Fi (only those of this account are used).
    @Published public private(set) var nearby: [ServiceBrowser.Service] = []
    /// The account's name (from its QR code, then from the account itself).
    @Published public private(set) var accountName: String? = UserDefaults.standard.string(forKey: "habla.accountName")
    @Published public private(set) var hasAccount = false
    /// Books deleted from the account (hidden even if a Mac still lists them for a moment).
    private var deletedIDs: Set<String> = []
    @Published public var readerStyle: ReaderStyle = PhoneStore.loadStyle() {
        didSet { if let d = try? JSONEncoder().encode([readerStyle.theme.rawValue, "\(readerStyle.fontSize)"]) { UserDefaults.standard.set(d, forKey: "habla.style") } }
    }

    public let library: URL
    public let progress: ProgressStore
    public let markers: MarkerStore
    public let deviceID: String
    /// When the cloud bridge last synced (away from home), for the status line.
    @Published public private(set) var bridgeSynced: Date?
    private var bridgeSync: BridgeSync?
    private var bridgeRan: Date?
    /// One bridge sync at a time; a forced one asked for meanwhile runs right after.
    private var bridgeSyncing = false
    private var bridgeAgain = false
    /// Books being routed now (so two syncs never send the same book twice).
    private var routing: Set<String> = []
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
        markers = MarkerStore.forLibrary(library, deviceID: deviceID)
        migratePairing()
        hasAccount = accountConfig != nil
        // Only mobile data holds uploads back (Low Data Mode or a hotspot flag on Wi-Fi doesn't).
        pathMonitor.pathUpdateHandler = { [cheap = onCheapNetwork] p in cheap.value = p.status == .satisfied && !p.usesInterfaceType(.cellular) }
        pathMonitor.start(queue: DispatchQueue(label: "habla.path"))
        markers.onChange = { [weak self] in Task { @MainActor in self?.markersChanged() } }
        // Positions saved by an earlier version and never sent: send them on the next sync.
        if !UserDefaults.standard.bool(forKey: "habla.pendingMigrated") {
            UserDefaults.standard.set(true, forKey: "habla.pendingMigrated")
            progress.markPending(progress.changed(since: lastPush).map(\.bookID))
        }
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
        for e in remote where !localIDs.contains(e.id) && !deletedIDs.contains(e.id) {
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

    /// "Remove download": only from this iPhone (the account keeps the book; nobody sends it here again).
    public func delete(_ id: String) {
        try? FileManager.default.removeItem(at: BookBundle.url(for: id, in: library))
        reloadLocal()
        Task { await bridge?.setDeclined(id, true) }
    }

    /// Deletes the book from every device of the account.
    public func deleteEverywhere(_ id: String) {
        try? FileManager.default.removeItem(at: BookBundle.url(for: id, in: library))
        try? FileManager.default.removeItem(at: BookImporter.originalURL(for: id, in: library))
        outbox.removeAll { $0 == id }
        deletedIDs.insert(id)
        progress.remove(id)
        reloadLocal()
        guard let bridge else { return }
        Task {
            await bridge.recordDeleted(id)
            await syncBridge(atHome: client != nil, force: true)
        }
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
                self.deletedIDs.subtract(addedIDs)
                let bridge = self.bridge
                Task { for id in addedIDs { await bridge?.recordAdded(id) } }
                self.reloadLocal()
                if !failedNames.isEmpty { self.error = "Couldn't open \(failedNames.joined(separator: ", ")). Is it a DRM-free EPUB?" }
                Task {
                    if self.bridge != nil {
                        // The running device that finishes it first narrates it (often a Mac).
                        try? await self.bridge?.syncState()
                        for id in addedIDs { await self.route(id) }
                    } else {
                        // No bridge: narrate here when this iPhone has the voice; the Mac still gets the book.
                        for id in addedIDs where self.canNarrateOnPhone(id) { self.narrateOnPhone(id) }
                    }
                    await self.sendOutbox()
                }
            }
        }
    }

    /// When each waiting book was last sent (ids → time). The EPUB is only deleted from the
    /// iPhone once the book shows up in the Mac's library, so a failed import never loses it.
    private var sentAt: [String: Date] = (UserDefaults.standard.dictionary(forKey: "habla.outboxSent") as? [String: Date]) ?? [:] {
        didSet { UserDefaults.standard.set(sentAt, forKey: "habla.outboxSent") }
    }

    /// Sends waiting books to the Mac (runs on every sync too; quietly waits while it's away).
    func sendOutbox() async {
        guard !outbox.isEmpty else { return }
        // Arrived on the Mac: now the iPhone's copy of the original can go.
        for id in outbox where remote.contains(where: { $0.id == id }) {
            outbox.removeAll { $0 == id }
            sentAt[id] = nil
            try? FileManager.default.removeItem(at: BookImporter.originalURL(for: id, in: library))
        }
        guard let client else { return }
        for id in outbox {
            let epub = BookImporter.originalURL(for: id, in: library)
            guard FileManager.default.fileExists(atPath: epub.path) else { outbox.removeAll { $0 == id }; continue }
            // Sent recently and the Mac is still importing it: give it time before sending again.
            if let last = sentAt[id], Date().timeIntervalSince(last) < 3600, last <= Date() { continue }
            do {
                try await client.sendBook(epub, filename: (manifest(id)?.title ?? id) + ".epub")
                sentAt[id] = Date()
            } catch SyncError.rejected(let why) {
                outbox.removeAll { $0 == id }
                sentAt[id] = nil
                error = "“\(manifest(id)?.title ?? "A book")” stays on this iPhone: \(why)"
            } catch {
                return   // Mac gone or busy: try again on the next sync
            }
        }
    }

    /// Voice models that narrated the downloaded books (for About Habla).
    public var narrationModels: [String] {
        var seen: [String] = []
        for m in localManifests() {
            for x in m.narrationModels where !seen.contains(x) { seen.append(x) }
            if m.narrationModels.isEmpty, m.chapters.contains(where: { $0.audioStatus == .ready }), !seen.contains("Kokoro v1.0") { seen.append("Kokoro v1.0") }
        }
        return seen
    }

    public func isWaitingForMac(_ id: String) -> Bool { outbox.contains(id) && phoneNarration[id] == nil }

    // MARK: Narrating on this iPhone

    /// The on-device voice (Paradee, from ParadeeKit), set by the iPhone app at launch. Nil in
    /// tests, snapshots and on the Mac: then books are only narrated by the Mac.
    nonisolated(unsafe) public static var onDeviceVoice: (@Sendable () -> TTSEngine)?
    /// Books being narrated on this iPhone → fraction done (0…1).
    @Published public private(set) var phoneNarration: [String: Double] = [:]
    private var phoneQueue: [String] = []
    private var phoneTask: Task<Void, Never>?

    /// This iPhone can narrate the book: it has the voice, the book's language has one, and some
    /// chapters have no audio yet.
    public func canNarrateOnPhone(_ id: String) -> Bool {
        guard Self.onDeviceVoice != nil, let m = manifest(id), BookLanguage.hasVoice(m.language) else { return false }
        return m.chapters.contains { $0.audioStatus == .pending }
    }

    /// Narrates the book's missing chapters on this iPhone, one book at a time. Each chapter can
    /// be played as soon as it's done. Runs while Habla is open, and in the background while
    /// you're listening (the audio session keeps the app awake); otherwise it resumes next time.
    public func narrateOnPhone(_ id: String) {
        guard canNarrateOnPhone(id), phoneNarration[id] == nil else { return }
        phoneNarration[id] = 0
        phoneQueue.append(id)
        guard phoneTask == nil, let makeEngine = Self.onDeviceVoice else { return }
        let cache = library.deletingLastPathComponent().appendingPathComponent("SentenceCache", isDirectory: true)
        phoneTask = Task { [weak self] in
            let engine = makeEngine()
            let pipeline = RenderPipeline(engine: engine, cacheDirectory: cache)
            pipeline.cacheLimit = 300_000_000   // a phone's worth; the Mac keeps 2 GB
            while let self, let id = self.phoneQueue.first {
                await self.narrate(id, with: pipeline)
                self.phoneQueue.removeFirst()
                self.phoneNarration[id] = nil
                self.reloadLocal()
                if self.manifest(id)?.isFullyRendered == true, let bridge = self.bridge {
                    await bridge.markNarratedHere(id)            // the Macs get it with its audio
                    Task { await self.syncBridge(atHome: self.client != nil, force: true) }
                }
            }
            await engine.shutdown()   // frees the model's memory
            self?.phoneTask = nil
        }
    }

    private func narrate(_ id: String, with pipeline: RenderPipeline) async {
        let bundle = bundle(id)
        guard let m = manifest(id) else { return }
        let voice = m.voice.flatMap { BookLanguage.voice($0.voiceID, speaks: m.language) ? $0 : nil }
            ?? VoiceInfo(engine: "paradee", voiceID: BookLanguage.closestVoice(to: accountVoice, for: m.language))
        let pending = Set(m.chapters.filter { $0.audioStatus == .pending }.map(\.index))
        #if canImport(UIKit)
        // A little extra time if Habla goes to the background; when it runs out iOS pauses
        // Habla and narration carries on when it's back.
        let background = BackgroundTime("Narrating")
        defer { background.end() }
        #endif
        let started = Date()
        let voiced = SentenceCounter()
        defer {
            let n = voiced.count, secs = Date().timeIntervalSince(started)
            if n >= 20, secs > 0 { Self.narrationSpeed = Self.narrationSpeed.map { $0 * 0.7 + Double(n) / secs * 0.3 } ?? Double(n) / secs }
        }
        do {
            try await pipeline.render(bundle, voice: voice, only: pending) { [weak self] p in
                if !p.cacheHit { voiced.add() }
                let done = (Double(p.chaptersDone) + Double(p.sentence) / Double(max(1, p.sentenceCount))) / Double(max(1, p.chaptersTotal))
                let chapterFinished = p.sentence == p.sentenceCount
                Task { @MainActor in
                    guard let self else { return }
                    self.phoneNarration[id] = done
                    if chapterFinished { self.reloadLocal() }   // that chapter is playable now
                }
            }
        } catch is CancellationError {
        } catch {
            self.error = "Couldn't narrate “\(m.title)” on this iPhone: \(error)"
        }
    }

    // MARK: Positions

    /// Saves locally at once; sends to the Mac in the background (coalesced).
    public func savePosition(book: String, chapter: Int, sentence: Int, audioTime: TimeInterval?, mode: ReadingPosition.Mode) {
        let fraction = manifest(book)?.fraction(chapter: chapter, sentence: sentence)
        progress.record(ReadingPosition(bookID: book, chapter: chapter, sentence: sentence, audioTime: audioTime,
                                        mode: mode, deviceID: deviceID, fraction: fraction))
        if let i = books.firstIndex(where: { $0.id == book }) { books[i].position = progress.position(for: book) }
        schedulePush()
    }

    // MARK: Cloud bridge (away from home)

    /// The account (Keychain, this device only): bridge URL + library key.
    var accountConfig: BridgeConfig? {
        guard let s = Keychain.get("account") else { return nil }
        return try? JSONDecoder().decode(BridgeConfig.self, from: Data(s.utf8))
    }
    var accountKeys: BridgeKeys? { accountConfig.map { BridgeKeys(libraryKey: $0.libraryKey) } }

    /// iPhones paired before accounts existed: the bridge key the Mac gave them becomes the account.
    private func migratePairing() {
        guard Keychain.get("account") == nil, let mac = homeMac, let s = Keychain.get("bridge." + mac.libraryID) else { return }
        Keychain.set(s, for: "account")
        Keychain.delete("bridge." + mac.libraryID)
        Keychain.delete(mac.libraryID)
    }

    /// The account's QR code (a habla://account link). It works like a password.
    public var accountLink: URL? { accountConfig.map { AccountCode.url($0, name: accountName) } }

    /// Joins the account from its QR code (Camera → habla://account) or pasted code.
    @discardableResult
    public func joinAccount(_ text: String) -> Bool {
        guard let (config, name) = AccountCode.parse(text), let d = try? JSONEncoder().encode(config) else {
            error = "That isn’t a Habla account code."
            return false
        }
        if config != accountConfig {
            Keychain.set(String(decoding: d, as: UTF8.self), for: "account")
            bridgeSync = nil
            homeMac = nil; savePaired()
            remote = []
            connection = .searching
            lastSync = nil
            lastPush = nil                    // every position goes to the account once
        }
        if let name { accountName = name; UserDefaults.standard.set(name, forKey: "habla.accountName") }
        hasAccount = true
        error = nil
        reloadLocal()
        start()
        return true
    }

    /// A habla:// link from the Camera or the in-app scanner: an account to join, or a Mac
    /// (without an account) asking for this iPhone's account.
    public func handleLink(_ url: URL) {
        switch url.host {
        case "account": joinAccount(url.absoluteString)
        case "join":
            if let invite = PairingInvite(url: url) { Task { await giveAccount(to: invite) } }
        case "pair": error = "That’s an old pairing code. Update Habla on your Mac."
        default: error = "That isn’t a Habla code."
        }
    }

    @Published public private(set) var joining: String?
    @Published public var notice: String?

    /// Hands this iPhone's account to the Mac whose join QR code was scanned: over Wi-Fi,
    /// pinned to the certificate in the QR code, proving the one-time code.
    public func giveAccount(to invite: PairingInvite) async {
        guard let link = accountLink else {
            error = "This iPhone isn’t in an account yet. Scan the QR code on a Mac that has one."
            return
        }
        let macName = invite.name.replacingOccurrences(of: "Habla on ", with: "")
        joining = macName
        defer { joining = nil }
        var url = nearby.first { $0.libraryID == invite.libraryID }?.url
        for _ in 0..<20 where url == nil {
            try? await Task.sleep(nanoseconds: 250_000_000)
            url = nearby.first { $0.libraryID == invite.libraryID }?.url
        }
        if url == nil, let a = invite.address { url = URL(string: "https://\(a)") }
        guard let url else { error = "Couldn’t find \(macName). Is this iPhone on the same Wi-Fi?"; return }
        let session = PinnedTrust(fingerprint: invite.fingerprint).session()
        do {
            try await SyncClient(baseURL: url, session: session)
                .join(code: invite.code, fingerprint: invite.fingerprint, deviceID: deviceID, deviceName: deviceName, account: link)
            error = nil
            notice = "\(macName) joined \(accountName ?? "your account")."
            // The Mac restarts sharing with the account: connect once it's back.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await connectNearby()
            await syncAccount()
        } catch {
            self.error = Self.describe(error)
        }
    }

    /// Leaves the account on this iPhone (downloaded books stay).
    public func leaveAccount() {
        Keychain.delete("account")
        UserDefaults.standard.removeObject(forKey: "habla.accountName")
        try? FileManager.default.removeItem(at: library.deletingLastPathComponent().appendingPathComponent("bridge-state.json"))
        accountName = nil
        hasAccount = false
        bridgeSync = nil
        homeMac = nil; savePaired()
        remote = []
        connection = .searching
        lastSync = nil
        reloadLocal()
    }

    var bridge: BridgeSync? {
        if let bridgeSync { return bridgeSync }
        guard let config = accountConfig else { return nil }
        let b = BridgeSync(config: config, deviceID: deviceID, deviceName: deviceName, role: .phone, progress: progress,
                           markers: markers, library: library,
                           stateURL: library.deletingLastPathComponent().appendingPathComponent("bridge-state.json"))
        bridgeSync = b
        Task { await b.configure(log: { [weak self] msg in Task { @MainActor in self?.bridgeStatus = msg } }) }
        return b
    }

    /// What the cloud sync is doing, or why it stopped (shown on the Account screen).
    @Published public private(set) var bridgeStatus: String?

    /// Wi-Fi or wired, not mobile data or Low Data Mode: only then does this iPhone upload books.
    private let pathMonitor = NWPathMonitor()
    private let onCheapNetwork = Locked(false)

    /// Sentences per second this iPhone voices (measured; a guess until then).
    static var narrationSpeed: Double? {
        get { UserDefaults.standard.object(forKey: "habla.narrationSpeed") as? Double }
        set { UserDefaults.standard.set(newValue, forKey: "habla.narrationSpeed") }
    }

    var narratorStatus: NarratorStatus? {
        guard Self.onDeviceVoice != nil else { return nil }
        let queued = phoneQueue.compactMap { manifest($0) }.reduce(0) { sum, m in
            sum + m.chapters.filter { $0.audioStatus == .pending }.reduce(0) { $0 + $1.sentenceCount }
        }
        return NarratorStatus(sentencesPerSecond: Self.narrationSpeed ?? 0.2, queuedSentences: queued, measured: Self.narrationSpeed != nil)
    }

    /// Sends a new book to whichever running device would finish narrating it first: the paired
    /// Mac over Wi-Fi, the other Mac through the bridge, or this iPhone when no Mac is running.
    func route(_ id: String) async {
        guard let bridge, let m = manifest(id), !routing.contains(id) else { return }
        guard BookLanguage.hasVoice(m.language) else { return }
        routing.insert(id)
        defer { routing.remove(id) }          // read-only languages: the Mac just needs the text
        let sentences = m.chapters.filter { $0.audioStatus == .pending }.reduce(0) { $0 + $1.sentenceCount }
        await bridge.setNarrator(narratorStatus)
        guard let target = await bridge.chooseNarrator(sentences: sentences) else { return }   // nobody: keep the outbox
        if target == deviceID {
            outbox.removeAll { $0 == id }            // narrated here, then sent to the Macs with its audio
            narrateOnPhone(id)
        } else if let mac = homeMac, target == "mac-" + mac.libraryID, client != nil {
            return                                    // the paired Mac, right here on Wi-Fi: the outbox sends it
        } else {
            let epub = BookImporter.originalURL(for: id, in: library)
            guard FileManager.default.fileExists(atPath: epub.path) else { return }
            if (try? await bridge.sendEPUB(epub, id: id, filename: m.title + ".epub", to: target)) != nil {
                outbox.removeAll { $0 == id }
            }
        }
    }

    /// Bookmarks and underlines changed: the Mac at home gets them now (Wi-Fi, free); the
    /// bridge gets them with the place when the book or the app closes.
    public func markersChanged() {
        Task { if let client { try? await client.syncMarkers(markers) } }
    }

    /// A book (reader or player) closed, or Habla went to the background: the place and marks go
    /// to the bridge now, and only now.
    public func bookClosed() {
        guard bridge != nil else { return }
        #if canImport(UIKit)
        let time = BackgroundTime("Saving your place")
        #endif
        Task {
            await syncBridge(atHome: client != nil, force: true)
            #if canImport(UIKit)
            time.end()
            #endif
        }
    }

    /// "Sync now": the account's cloud side too.
    public func syncAccount() async { await syncBridge(atHome: client != nil, force: true) }

    /// Habla opened: what changed elsewhere (places, marks, new books) comes in.
    func bridgeOnOpen() {
        guard bridge != nil else { return }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)     // let the Mac at home be found first
            await syncBridge(atHome: client != nil, force: true)
        }
    }

    /// The account's voice (same on every device; set on the Mac).
    var accountVoice: String { UserDefaults.standard.string(forKey: "habla.voice") ?? "af_heart" }

    /// Away from the Mac: places, markers, new books and EPUBs go through the bridge.
    /// At home only places and markers are mirrored (books come over Wi-Fi, faster).
    func syncBridge(atHome: Bool, force: Bool = false) async {
        guard let bridge else { return }
        if bridgeSyncing { if force { bridgeAgain = true }; return }
        if !force, let last = bridgeRan, Date().timeIntervalSince(last) < 300 { return }
        bridgeSyncing = true
        bridgeRan = Date()
        defer {
            bridgeSyncing = false
            if bridgeAgain { bridgeAgain = false; Task { await syncBridge(atHome: client != nil, force: true) } }
        }
        do {
            await bridge.setNarrator(narratorStatus)
            try await bridge.syncState()
            UserDefaults.standard.set(await bridge.settings.voice, forKey: "habla.voice")
            if let name = await bridge.settings.name, name != accountName {
                accountName = name; UserDefaults.standard.set(name, forKey: "habla.accountName")
            }
            // Deleted on another device: deleted here too.
            for id in await bridge.booksDeletedElsewhere() {
                try? FileManager.default.removeItem(at: BookBundle.url(for: id, in: library))
                try? FileManager.default.removeItem(at: BookImporter.originalURL(for: id, in: library))
                outbox.removeAll { $0 == id }
                progress.remove(id)
            }
            deletedIDs = await bridge.deletedIDs
            reloadLocal()
            let arrived = await bridge.booksOnMac()
            for id in outbox where arrived.contains(id) {
                outbox.removeAll { $0 == id }; sentAt[id] = nil
                try? FileManager.default.removeItem(at: BookImporter.originalURL(for: id, in: library))
            }
            // Away from the paired Mac, books waiting for it go to the best running device instead.
            if !atHome { for id in outbox { await route(id) } }
            // Books narrated elsewhere (either Mac, or this iPhone's earlier work) arrive with audio.
            if !(try await bridge.receiveBooks()).isEmpty { reloadLocal() }
            for id in try await bridge.retarget() where canNarrateOnPhone(id) { narrateOnPhone(id) }
            // On the Mac's Wi-Fi, or any non-mobile network: books this iPhone holds go out.
            try await bridge.publishNewBooks(uploads: onCheapNetwork.value || client != nil)
            try await bridge.collect()
            bridgeSynced = Date()
            if bridgeStatus?.hasPrefix("Cloud sync stopped") == true { bridgeStatus = nil }
        } catch {
            // Offline or a free-tier cap: places stay saved here and go out next time.
            bridgeStatus = "Cloud sync stopped: \(Self.describe(error))"
        }
        reloadLocal()
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

    // MARK: Mac connection (same account, encrypted)

    /// A Mac of this account on this Wi-Fi. It proved it holds the account key for the
    /// certificate it showed, and the connection is pinned to that certificate.
    public struct PairedMac: Codable, Equatable, Sendable {
        public var libraryID: String
        public var name: String
        /// SHA-256 of the Mac's TLS certificate.
        public var fingerprint: String
        public var lastURL: URL?
        public init(libraryID: String, name: String, fingerprint: String, lastURL: URL? = nil) {
            self.libraryID = libraryID; self.name = name; self.fingerprint = fingerprint; self.lastURL = lastURL
        }
    }

    var client: SyncClient? {
        guard case let .connected(_, url) = connection, let mac = homeMac, let keys = accountKeys else { return nil }
        var c = SyncClient(baseURL: url, accessToken: keys.lanToken, session: session(for: mac))
        c.deviceID = deviceID; c.deviceName = deviceName
        return c
    }

    private var sessions: [String: URLSession] = [:]
    func session(for mac: PairedMac) -> URLSession {
        if let s = sessions[mac.fingerprint] { return s }
        let s = PinnedTrust(fingerprint: mac.fingerprint).session()
        sessions[mac.fingerprint] = s
        return s
    }

    static func loadPaired() -> PairedMac? {
        UserDefaults.standard.data(forKey: "habla.pairedMac").flatMap { try? JSONDecoder().decode(PairedMac.self, from: $0) }
    }

    func savePaired() {
        UserDefaults.standard.set(homeMac.flatMap { try? JSONEncoder().encode($0) }, forKey: "habla.pairedMac")
    }

    /// Asks a Mac to prove it belongs to this account, for the certificate this connection sees.
    /// Returns it (to pin) when it does.
    func verify(_ svc: ServiceBrowser.Service, keys: BridgeKeys) async -> PairedMac? {
        guard svc.url.scheme == "https" else { return nil }
        let nonce = Pairing.randomToken()
        let trust = PinnedTrust(fingerprint: nil)
        guard let hello = try? await SyncClient(baseURL: svc.url, session: trust.session(timeout: 8)).hello(nonce: nonce),
              let fp = trust.seen, let proof = hello.accountProof,
              proof.lowercased() == keys.lanProof(fingerprint: fp, nonce: nonce) else { return nil }
        return PairedMac(libraryID: hello.libraryID ?? svc.libraryID ?? "", name: hello.name, fingerprint: fp, lastURL: svc.url)
    }

    private var connecting = false

    /// Connects to a Mac of this account on this Wi-Fi (the one already used, if it's here).
    func connectNearby() async {
        guard let keys = accountKeys, !connecting else { return }
        let mine = nearby.filter { $0.account == keys.accountTag }
        if case .connected(_, let url) = connection, mine.contains(where: { $0.url == url }) { return }
        connecting = true
        defer { connecting = false }
        let ordered = mine.sorted { a, _ in a.libraryID == homeMac?.libraryID }
        for svc in ordered {
            guard let mac = await verify(svc, keys: keys) else { continue }
            homeMac = mac; savePaired()
            connection = .connected(name: mac.name, url: svc.url)
            await sync()
            return
        }
    }

    /// Starts looking for the account's Macs (Bonjour) and syncs as soon as one is found.
    public func start() {
        browser.stop()
        browser.onChange = { [weak self] services in
            Task { @MainActor in
                guard let self else { return }
                self.nearby = services.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                await self.connectNearby()
            }
        }
        browser.start()
        Task { await sync() }
        bridgeOnOpen()
        checkForAppUpdate()
    }

    // MARK: Live updates

    private var liveTask: Task<Void, Never>?

    /// While the app is open: a tiny library check every few seconds; a full sync as soon as
    /// something changed on the Mac (new book, new chapters), and a regular one for positions.
    public func startLiveUpdates(every seconds: Double = 4) {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                ticks += 1
                guard !self.syncing else { continue }
                guard let client = self.client else { continue }
                if let fresh = try? await client.library() {
                    let changed = fresh.map { "\($0.id):\($0.revision)" } != self.remote.map { "\($0.id):\($0.revision)" }
                    if changed || ticks % 8 == 0 { await self.sync() }
                } else if ticks % 4 == 0 {
                    await self.sync()   // Mac gone: let sync() update the status line
                }
            }
        }
    }

    public func stopLiveUpdates() { liveTask?.cancel(); liveTask = nil }

    var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
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
        guard hasAccount, let mac = homeMac else { connection = .searching; return }
        if client == nil, let url = mac.lastURL { connection = .connected(name: mac.name, url: url) }
        guard let client else {
            if case .searching = connection {} else { connection = .searching }
            return
        }
        do {
            remote = try await client.library()
            if case .connected(_, let url) = connection, homeMac?.lastURL != url { homeMac?.lastURL = url; savePaired() }
            let started = Date()
            try await client.syncProgress(progress, since: lastPush)
            lastPush = started; UserDefaults.standard.set(started, forKey: "habla.lastPush")
            try? await client.syncMarkers(markers)
            lastSync = Date()
            error = nil
            await sendOutbox()
            // Bring downloaded books up to date (new chapters narrated, voice changed…) in the
            // background: the library and "Sync now" are usable meanwhile.
            // A book narrated on this iPhone is only replaced by the Mac's copy when that copy has
            // at least as much audio, and never while the iPhone is still narrating it.
            let outdated = localManifests().filter { m in
                guard phoneNarration[m.id] == nil else { return false }
                let ready = m.chapters.filter { $0.audioStatus == .ready }.count
                return remote.contains { $0.id == m.id && $0.revision != m.revision && $0.readyChapters >= ready }
            }.map(\.id)
            if !outdated.isEmpty {
                Task { for id in outdated { try? await self.download(id, silent: true) } }
            }
        } catch SyncError.notPaired {
            // That Mac isn't in this account (any more): look for another one.
            homeMac = nil; savePaired()
            remote = []
            connection = .searching
            Task { await connectNearby() }
        } catch {
            connection = .unreachable(Self.describe(error))
        }
        reloadLocal()
    }

    // MARK: Downloads

    /// Downloads (or updates) a book from the Mac. Interrupted downloads resume: files
    /// already verified are kept, and the manifest is written last.
    /// Re-checks every file of a book against the Mac (fixes silently damaged downloads).
    /// Returns true when damaged files were actually replaced (then reloading helps).
    @discardableResult
    public func repair(_ id: String) async -> Bool {
        guard let client else { return false }
        updating.insert(id)
        defer { updating.remove(id); reloadLocal() }
        do { return try await client.syncBook(id, into: library, verify: true).filesDownloaded > 0 }
        catch { return false }
    }

    public func download(_ id: String, silent: Bool = false) async throws {
        guard let client, downloading[id] == nil, !updating.contains(id) else { return }
        if !silent { await bridge?.setDeclined(id, false) }
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
            } catch SyncError.unreachable where attempt < 3 {
                // Wi-Fi hiccup or the Mac busy: files already verified are kept, so this resumes.
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            } catch {
                if !silent { self.error = "Couldn't download: \(Self.describe(error))" }
                throw error
            }
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? SyncError { return e.description }
        if let e = error as? BridgeError { return e.description }
        return error.localizedDescription
    }
}

extension PhoneStore {
    /// Snapshot/preview support: state that normally comes from the network.
    public func previewState(remote: [LibraryEntry], connection: Connection, lastSync: Date?, downloading: [String: Double] = [:],
                             paired: PairedMac? = nil, nearby: [ServiceBrowser.Service] = []) {
        self.homeMac = paired
        self.hasAccount = paired != nil
        self.nearby = nearby
        self.remote = remote
        self.connection = connection
        self.lastSync = lastSync
        self.downloading = downloading
        reloadLocal()
    }
}

/// Counts sentences voiced (from the render callback's thread).
final class SentenceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

#if canImport(UIKit)
/// Extra time to finish work in the background. Handed back the moment iOS says it's up:
/// keeping it past that makes iOS end Habla (handed back, Habla is only paused).
@MainActor final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid
    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
