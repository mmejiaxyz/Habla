#if os(macOS)
import Foundation
import SwiftUI
import AVFoundation
import CryptoKit
import HablaCore

/// Habla Studio (Mac): library, narration queue (Kokoro), the sync server for the iPhone,
/// and automatic Xteink setup + delivery. Shares its folders with the `habla` CLI.
@MainActor
public final class StudioStore: ObservableObject {
    public struct RenderState: Equatable {
        public var bookID: String
        public var chapterIndex: Int
        public var chapterTitle: String
        public var sentence: Int
        public var sentenceCount: Int
        public var chaptersDone: Int
        public var chaptersTotal: Int
        /// Sentences narrated in the whole book so far (for a smooth progress bar).
        public var bookSentencesDone: Int
        public var bookSentencesTotal: Int
        public var secondsLeft: TimeInterval?
        public init(bookID: String, chapterIndex: Int = 0, chapterTitle: String, sentence: Int, sentenceCount: Int,
                    chaptersDone: Int, chaptersTotal: Int, bookSentencesDone: Int = 0, bookSentencesTotal: Int = 0,
                    secondsLeft: TimeInterval? = nil) {
            self.bookID = bookID; self.chapterIndex = chapterIndex; self.chapterTitle = chapterTitle
            self.sentence = sentence; self.sentenceCount = sentenceCount
            self.chaptersDone = chaptersDone; self.chaptersTotal = chaptersTotal
            self.bookSentencesDone = bookSentencesDone; self.bookSentencesTotal = bookSentencesTotal
            self.secondsLeft = secondsLeft
        }
    }

    public enum VoiceEngineState: Equatable { case checking, ready, missing, installing(String), failed(String) }

    public enum XteinkState: Equatable {
        case looking
        case found(name: String, detail: String)
        case working(String)
        case done(String)
        case failed(String)
    }

    /// This Mac's own books (what the shelf, its phones and its other Macs see).
    @Published public private(set) var books: [BookManifest] = []
    /// Every book in the folder, including ones narrated here for someone else's library.
    private var allBooks: [BookManifest] = []
    @Published public var selection: String?
    @Published public private(set) var importing: [String] = []
    @Published public var alert: String?
    @Published public private(set) var render: RenderState?
    @Published public private(set) var queue: [String] = []
    @Published public private(set) var paused: Bool = UserDefaults.standard.bool(forKey: "habla.paused") {
        didSet { UserDefaults.standard.set(paused, forKey: "habla.paused") }
    }
    @Published public private(set) var voiceEngine: VoiceEngineState = .checking
    @Published public private(set) var voiceEngineLog: [String] = []
    @Published public private(set) var voices: [String] = StudioStore.defaultVoices
    /// The account's voice: the same on every device (Heart unless changed in Settings).
    @Published public var defaultVoice: String = UserDefaults.standard.string(forKey: "habla.voice") ?? "af_heart" {
        didSet {
            UserDefaults.standard.set(defaultVoice, forKey: "habla.voice")
            guard defaultVoice != oldValue, !applyingAccountVoice, let bridge else { return }
            let v = defaultVoice
            Task { await bridge.setVoice(v); kickBridge() }
        }
    }
    private var applyingAccountVoice = false

    /// Help narrate only: this Mac narrates books for the account's other devices but never shows
    /// them, never syncs places or marks, and keeps nothing once they're delivered.
    @Published public var helperOnly: Bool = UserDefaults.standard.bool(forKey: "habla.helperOnly") {
        didSet {
            guard helperOnly != oldValue else { return }
            UserDefaults.standard.set(helperOnly, forKey: "habla.helperOnly")
            if helperOnly { server.stop() } else { startServer() }
            bridgeLoop?.cancel(); listener?.stop(); listener = nil; bridge = nil
            try? FileManager.default.removeItem(at: support.appendingPathComponent("bridge-state.json"))
            startBridge()
        }
    }
    /// Books that were on this Mac before a helper job named them: never deleted by helping.
    private var helperKeep: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "habla.helperKeep") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "habla.helperKeep") }
    }
    /// Helper: books being narrated or waiting to be collected (no titles shown).
    @Published public private(set) var helperJobs = 0
    @Published public var autoNarrate: Bool = UserDefaults.standard.object(forKey: "habla.autoNarrate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoNarrate, forKey: "habla.autoNarrate") }
    }
    @Published public private(set) var phoneLastSeen: Date?
    /// Devices paired with this Mac (only they can see the library or send books).
    @Published public private(set) var devices: [PairedDevice] = []
    /// The pairing code on screen right now (nil when not pairing).
    @Published public private(set) var pairingCode: PairingCode?
    /// False if the encryption certificate couldn't be made (pairing still required).
    @Published public private(set) var encrypted = false

    public struct PairingCode: Equatable {
        public var code: String
        public var expires: Date
        public var invite: URL
        public init(code: String, expires: Date, invite: URL) { self.code = code; self.expires = expires; self.invite = invite }
    }
    @Published public private(set) var serverAddress: String?
    @Published public private(set) var onWiFi = true
    @Published public private(set) var xteink: XteinkState = .looking
    @Published public private(set) var xteinkLastSync: Date? = UserDefaults.standard.object(forKey: "habla.xteinkLast") as? Date
    @Published public private(set) var previewing: String?

    public let support: URL
    public let library: URL
    public let progress: ProgressStore
    let server: LibraryServer
    private var engine: EnginePool?
    private var renderTask: Task<Void, Never>?
    private var xteinkTask: Task<Void, Never>?
    private var xteinkKick = false
    private var xteinkFailures = 0
    private var lastPushSignature: String?
    private var previewPlayer: AVAudioPlayer?
    private var activity: NSObjectProtocol?
    private var recentSentenceTimes: [TimeInterval] = []

    static let defaultVoices = BookLanguage.voices(for: "en", narrator: .kokoro)

    /// Books the user stopped (cancelled) — not auto-resumed on launch.
    private var stopped: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "habla.stopped") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "habla.stopped") }
    }

    public init(support: URL? = nil) {
        self.support = support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Habla Studio", isDirectory: true)
        library = self.support.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        progress = ProgressStore(fileURL: self.support.appendingPathComponent("progress.json"))
        markers = MarkerStore.forLibrary(library, deviceID: "mac-" + StudioStore.libraryID())
        server = LibraryServer(library: library, progress: progress,
                               serviceName: "Habla on \(Host.current().localizedName ?? "Mac")")
        // Privacy: only paired devices get in; traffic is encrypted and pinned to this Mac.
        registry = DeviceRegistry(fileURL: self.support.appendingPathComponent("devices.json"))
        server.koreaderKeyMD5 = xteinkCredentials().map { KOReaderDigest.filename($0.password) }
        server.registry = registry
        server.pairing = pairingWindow
        server.libraryID = StudioStore.libraryID()
        server.allowEReaders = Features.xteink
        if #available(macOS 15.0, *),
           let tls = try? TLSIdentity.loadOrCreate(in: self.support.appendingPathComponent("Security", isDirectory: true)) {
            server.tlsIdentity = tls.identity
            server.tlsFingerprint = tls.fingerprint
            encrypted = true
        }
        server.markers = markers
        server.account.value = currentBridgeConfig.map { BridgeKeys(libraryKey: $0.libraryKey) }
        let hidden = hiddenIDs
        server.isHidden = { hidden.contains($0) }
        hiddenIDs.set(Set(guestBooks.keys))
        helping = loadHelping()
        devices = registry.all
        reload()
        checkVoiceEngine()
    }

    // MARK: Cloud bridge (Docs/cloud-bridge.md)

    public let markers: MarkerStore
    /// When the cloud bridge last synced, for Settings.
    @Published public private(set) var bridgeSynced: Date?
    @Published public private(set) var bridgeUsage: BridgeUsage?
    private var bridge: BridgeSync?
    private var bridgeLoop: Task<Void, Never>?
    private var bridgeKick: Task<Void, Never>?

    /// `Security/bridge.json`: the Worker URL, the library key (made here once) and, until this
    /// Mac has enrolled, the Worker's enrollment secret. Never leaves this Mac except to paired phones.
    struct BridgeFile: Codable { var url: URL; var libraryKey: Data?; var enrollSecret: String? }
    var bridgeFileURL: URL { support.appendingPathComponent("Security/bridge.json") }

    private func saveBridgeFile(_ f: BridgeFile) {
        guard let d = try? JSONEncoder().encode(f) else { return }
        try? d.write(to: bridgeFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bridgeFileURL.path)
    }

    /// The code another Mac pastes to join this library's bridge (it holds the library key:
    /// treat it like a password).
    public var bridgeLinkCode: String? { accountLink?.absoluteString }

    // MARK: Account (one library on every device)

    /// The account's name (synced to every device).
    @Published public private(set) var accountName: String? = UserDefaults.standard.string(forKey: "habla.accountName")
    /// The account's other devices, as the bridge last saw them.
    @Published public private(set) var accountDevices: [AccountDevice] = []

    /// The account's QR code / code to paste: a habla://account link (works like a password).
    public var accountLink: URL? { currentBridgeConfig.map { AccountCode.url($0, name: accountName) } }

    /// Renames the account on every device.
    public func renameAccount(_ name: String) {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !n.isEmpty else { return }
        accountName = n
        UserDefaults.standard.set(n, forKey: "habla.accountName")
        guard let bridge else { return }
        Task { await bridge.setName(n); kickBridge() }
    }

    /// The Wi-Fi server answers the account's devices (and advertises its tag): restart it
    /// when the account changes.
    private func setServerAccount(_ keys: BridgeKeys?) {
        guard server.account.value?.lanToken != keys?.lanToken else { return }
        server.account.value = keys
        if started && !helperOnly { server.stop(); startServer() }
    }

    public var bridgeReady: Bool { bridge != nil }

    /// Joins the bridge of another Mac from its link code. Returns false for a bad code.
    @discardableResult
    public func joinBridge(code: String) -> Bool {
        guard let (config, name) = AccountCode.parse(code) else { return false }
        if let name { accountName = name; UserDefaults.standard.set(name, forKey: "habla.accountName") }
        try? FileManager.default.createDirectory(at: bridgeFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        saveBridgeFile(BridgeFile(url: config.url, libraryKey: config.libraryKey, enrollSecret: nil))
        try? FileManager.default.removeItem(at: support.appendingPathComponent("bridge-state.json"))
        bridgeLoop?.cancel(); listener?.stop(); listener = nil; bridge = nil
        startBridge()
        objectWillChange.send()
        return true
    }

    /// Sets the bridge up (once), then syncs through it every 5 minutes.
    private func startBridge() {
        guard var file = (try? Data(contentsOf: bridgeFileURL)).flatMap({ try? JSONDecoder().decode(BridgeFile.self, from: $0) }) else { return }
        if file.libraryKey == nil { file.libraryKey = BridgeKeys.newLibraryKey(); saveBridgeFile(file) }
        guard let key = file.libraryKey else { return }
        let config = BridgeConfig(url: file.url, libraryKey: key)
        server.bridgeConfig = { config }
        setServerAccount(BridgeKeys(libraryKey: key))
        let b = BridgeSync(config: config, deviceID: "mac-" + StudioStore.libraryID(), deviceName: server.serviceName,
                           role: helperOnly ? .helper : .mac,
                           progress: progress, markers: markers, library: library,
                           stateURL: support.appendingPathComponent("bridge-state.json"))
        let registry = registry
        let hidden = hiddenIDs
        bridge = b
        bridgeLoop = Task { [weak self] in
            _ = registry
            await b.configure(inbox: self?.server.inbox, onEPUB: { file, voice in
                Task { @MainActor in
                    guard let self, let id = try? DocumentDigest.sha256Prefix(of: file) else { return }
                    // Narrated with the account voice the sender used.
                    if let voice { UserDefaults.standard.set(voice, forKey: "habla.voice.\(id)") }
                    // A book this Mac was narrating for someone else, now added by you: it's yours too.
                    if self.guestBooks[id] != nil { self.guestBooks[id] = nil }
                    if self.books.contains(where: { $0.id == id }) {
                        // Already here: narrate this copy, and never delete it when the job ends.
                        if self.helperOnly { var k = self.helperKeep; k.insert(id); self.helperKeep = k }
                        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                        self.narrate(id)
                    } else {
                        self.importFiles([file], fromPhone: true)
                    }
                }
            }, onJobDone: { id in
                Task { @MainActor in
                    guard let self else { return }
                    if self.helperKeep.contains(id) { var k = self.helperKeep; k.remove(id); self.helperKeep = k }
                    else { self.delete(id) }                     // delivered: nothing stays on a helper
                }
            }, hidden: { hidden.all })
            if let secret = file.enrollSecret {
                do {
                    try await b.client.enroll(tokenHash: BridgeKeys(libraryKey: key).tokenHash, secret: secret)
                    file.enrollSecret = nil
                    self?.saveBridgeFile(file)
                } catch { return }                       // retried at the next launch
            }
            // Listen: a nudge the moment another device changes something (and on every
            // reconnect after sleep or a network change). A safety look every 6 hours.
            let listener = BridgeListener(config: config, deviceID: "mac-" + StudioStore.libraryID()) {
                Task { @MainActor in self?.kickBridge(after: 2) }
            }
            await MainActor.run { self?.listener?.stop(); self?.listener = listener }
            listener.start()
            while !Task.isCancelled {
                await self?.runBridge()
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
            listener.stop()
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.listener?.reconnect(now: true) }   // the old connection died in sleep
            }
        }
    }
    private var listener: BridgeListener?
    private var wakeObserver: NSObjectProtocol?

    /// Places, markers, EPUBs from phones, new books out, collected books deleted.
    func runBridge() async {
        guard let bridge else { return }
        do {
            await bridge.setNarrator(narratorStatus)
            try await bridge.syncState()
            let account = await bridge.settings.voice
            if account != defaultVoice { applyingAccountVoice = true; defaultVoice = account; applyingAccountVoice = false }
            if let name = await bridge.settings.name, name != accountName {
                accountName = name; UserDefaults.standard.set(name, forKey: "habla.accountName")
            } else if await bridge.settings.name == nil, let name = accountName {
                await bridge.setName(name)                          // named here before the account knew
            }
            accountDevices = await bridge.devices()
            // Deleted on another device: deleted here too.
            for id in await bridge.booksDeletedElsewhere() { delete(id) }
            try await bridge.receiveEPUBs()
            let arrived = try await bridge.receiveBooks()
            if !arrived.isEmpty {
                reload()
                // A book only an iPhone had (part narrated): this Mac finishes it.
                for id in arrived where books.first(where: { $0.id == id })?.isFullyRendered == false && !helperOnly { narrate(id) }
            }
            for id in try await bridge.retarget() { narrate(id) }      // its narrator went quiet: do it here
            try await bridge.publishNewBooks()
            try await bridge.collect()
            helperJobs = await bridge.jobs.count
            bridgeSynced = Date()
            bridgeUsage = try? await bridge.client.usage()
        } catch {
            // Offline or a free-tier cap: everything waits here for the next round.
        }
    }

    var bridgeDeviceID: String { "mac-" + StudioStore.libraryID() }

    // MARK: Helping someone else's library

    /// Someone else's library this Mac narrates for (`Security/helping.json`, 0600). Its books
    /// are narrated here but hidden from this Mac's shelf, its phones, its other Macs and the
    /// Xteink, and deleted once their devices have them.
    public struct HelpedLibrary: Codable, Identifiable, Equatable {
        public var name: String
        var url: URL
        var libraryKey: Data
        public var id: String { SHA256.hash(data: libraryKey).prefix(6).map { String(format: "%02x", $0) }.joined() }
        var config: BridgeConfig { BridgeConfig(url: url, libraryKey: libraryKey) }
    }
    @Published public private(set) var helping: [HelpedLibrary] = []
    /// Books narrating or waiting to be collected, per helped library (no titles).
    @Published public private(set) var helpingJobs: [String: Int] = [:]
    private var helpingRuns: [String: (sync: BridgeSync, loop: Task<Void, Never>, listener: BridgeListener)] = [:]
    private var helpingKick: Task<Void, Never>?
    /// Guest book id → the helped library it belongs to.
    private var guestBooks: [String: String] = (UserDefaults.standard.dictionary(forKey: "habla.guestBooks") as? [String: String]) ?? [:] {
        didSet {
            UserDefaults.standard.set(guestBooks, forKey: "habla.guestBooks")
            hiddenIDs.set(Set(guestBooks.keys))
            if guestBooks != oldValue { reload() }
        }
    }
    let hiddenIDs = HiddenIDs()

    var helpingFileURL: URL { support.appendingPathComponent("Security/helping.json") }

    private func loadHelping() -> [HelpedLibrary] {
        (try? Data(contentsOf: helpingFileURL)).flatMap { try? JSONDecoder().decode([HelpedLibrary].self, from: $0) } ?? []
    }
    private func saveHelping() {
        try? FileManager.default.createDirectory(at: helpingFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(helping) else { return }
        try? d.write(to: helpingFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: helpingFileURL.path)
    }

    public enum HelpError: Error, Equatable { case notALinkCode, ownLibrary, already }

    /// Starts narrating for someone else's library from the link code their Mac shows.
    public func startHelping(name: String, code: String) throws {
        guard let config = AccountCode.parse(code)?.config else { throw HelpError.notALinkCode }
        if let mine = currentBridgeConfig, mine.libraryKey == config.libraryKey { throw HelpError.ownLibrary }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = HelpedLibrary(name: trimmed.isEmpty ? "Someone" : trimmed, url: config.url, libraryKey: config.libraryKey)
        guard !helping.contains(where: { $0.id == h.id }) else { throw HelpError.already }
        helping.append(h)
        saveHelping()
        runHelping(h)
    }

    /// Stops helping: its sync ends, and its books still here (unfinished or uncollected) go.
    public func stopHelping(_ h: HelpedLibrary) {
        if let run = helpingRuns.removeValue(forKey: h.id) { run.loop.cancel(); run.listener.stop() }
        helping.removeAll { $0.id == h.id }
        saveHelping()
        helpingJobs[h.id] = nil
        try? FileManager.default.removeItem(at: helpingStateURL(h))
        for (id, owner) in guestBooks where owner == h.id { delete(id) }
    }

    private func helpingStateURL(_ h: HelpedLibrary) -> URL { support.appendingPathComponent("helping-\(h.id).json") }

    private func startAllHelping() { for h in helping where helpingRuns[h.id] == nil { runHelping(h) } }

    private func runHelping(_ h: HelpedLibrary) {
        let sync = BridgeSync(config: h.config, deviceID: bridgeDeviceID, deviceName: server.serviceName, role: .helper,
                              progress: progress, markers: markers, library: library, stateURL: helpingStateURL(h))
        let listener = BridgeListener(config: h.config, deviceID: bridgeDeviceID) { [weak self] in
            Task { @MainActor in self?.kickHelping(after: 2) }
        }
        let hid = h.id
        let loop = Task { [weak self] in
            await sync.configure(inbox: self?.server.inbox, onEPUB: { file, voice in
                Task { @MainActor in
                    guard let self, let id = try? DocumentDigest.sha256Prefix(of: file) else { return }
                    if let voice { UserDefaults.standard.set(voice, forKey: "habla.voice.\(id)") }
                    if self.allBooks.contains(where: { $0.id == id }) {
                        // Already here (yours: it stays visible and is never deleted; or theirs,
                        // sent again): narrate this copy.
                        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                        self.narrate(id)
                    } else {
                        self.guestBooks[id] = hid                // hidden before it exists on disk
                        self.importFiles([file], fromPhone: true)
                    }
                }
            }, onJobDone: { id in
                Task { @MainActor in
                    guard let self, self.guestBooks[id] == hid else { return }
                    self.delete(id)                              // delivered: nothing of theirs stays
                }
            })
            listener.start()
            while !Task.isCancelled {
                await self?.helpRound(sync, id: hid)
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
            listener.stop()
        }
        helpingRuns[h.id] = (sync, loop, listener)
    }

    /// One round for a helped library: check in with this Mac's speed, take EPUBs sent to it,
    /// pick up books whose narrator went quiet, send finished ones, let collected ones go.
    private func helpRound(_ sync: BridgeSync, id hid: String) async {
        do {
            await sync.setNarrator(narratorStatus)
            try await sync.syncState()
            try await sync.receiveEPUBs()
            for id in try await sync.retarget() { narrate(id) }
            try await sync.publishNewBooks()
            try await sync.collect()
            helpingJobs[hid] = await sync.jobs.count
        } catch {
            // Offline or a cap: the next round tries again.
        }
    }

    /// The library changed (a guest book finished a chapter or the whole book): tell helped libraries.
    func kickHelping(after seconds: Double = 5) {
        guard !helpingRuns.isEmpty, helpingKick == nil else { return }
        helpingKick = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self else { return }
            self.helpingKick = nil
            for (hid, run) in self.helpingRuns { await self.helpRound(run.sync, id: hid) }
        }
    }

    /// Makes this Mac's own library on the bridge from someone's invite code (only when it has none).
    public func startLibrary(invite code: String) async throws {
        guard let invite = BridgeCode.parseInvite(code) else { throw HelpError.notALinkCode }
        guard currentBridgeConfig == nil else { throw HelpError.already }
        let key = BridgeKeys.newLibraryKey()
        let keys = BridgeKeys(libraryKey: key)
        try await BridgeClient(baseURL: invite.url, token: keys.token).enroll(tokenHash: keys.tokenHash, invite: invite.invite)
        try? FileManager.default.createDirectory(at: bridgeFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        saveBridgeFile(BridgeFile(url: invite.url, libraryKey: key, enrollSecret: nil))
        try? FileManager.default.removeItem(at: support.appendingPathComponent("bridge-state.json"))
        startBridge()
        objectWillChange.send()
    }

    /// A one-time code (7 days) for someone else's Mac to start its own library on this bridge.
    public func makeInvite() async throws -> String {
        guard let config = currentBridgeConfig else { throw HelpError.notALinkCode }
        let invite = try await BridgeClient(baseURL: config.url, token: BridgeKeys(libraryKey: config.libraryKey).token).createInvite()
        guard let code = BridgeCode.invite(.init(url: config.url, invite: invite)) else { throw HelpError.notALinkCode }
        return code
    }

    private var currentBridgeConfig: BridgeConfig? {
        guard let file = (try? Data(contentsOf: bridgeFileURL)).flatMap({ try? JSONDecoder().decode(BridgeFile.self, from: $0) }),
              let key = file.libraryKey else { return nil }
        return BridgeConfig(url: file.url, libraryKey: key)
    }

    /// An error message about a guest book, without its title.
    nonisolated static func untitled(_ message: String, _ title: String) -> String {
        message.replacingOccurrences(of: "“\(title)”", with: "it").replacingOccurrences(of: title, with: "it")
    }

    /// Sentences per second this Mac voices (measured while narrating; a guess until then).
    static var narrationSpeed: Double? {
        get { UserDefaults.standard.object(forKey: "habla.narrationSpeed") as? Double }
        set { UserDefaults.standard.set(newValue, forKey: "habla.narrationSpeed") }
    }

    /// What other devices need to decide where a new book is narrated fastest.
    var narratorStatus: NarratorStatus? {
        guard voiceEngine == .ready else { return nil }
        let queued = queue.compactMap { id in allBooks.first { $0.id == id } }.reduce(0) { sum, m in
            let left = Set(m.chaptersToNarrate(voiceID: voice(for: m)).map(\.index))
            return sum + m.chapters.filter { left.contains($0.index) }.reduce(0) { $0 + $1.sentenceCount }
        }
        return NarratorStatus(sentencesPerSecond: Self.narrationSpeed ?? 1.0, queuedSentences: queued, measured: Self.narrationSpeed != nil)
    }

    /// A new book dropped on this Mac: narrate it here, or on the running device that finishes it first.
    func narrateHereOrElsewhere(_ m: BookManifest) {
        guard let bridge, BookLanguage.hasVoice(m.language) else { narrate(m.id); return }
        let sentences = m.chapters.filter { $0.audioStatus == .pending }.reduce(0) { $0 + $1.sentenceCount }
        let epub = BookImporter.originalURL(for: m.id, in: library)
        let me = bridgeDeviceID
        Task {
            await bridge.setNarrator(narratorStatus)
            try? await bridge.syncState()                              // fresh check-ins
            guard let target = await bridge.chooseNarrator(sentences: sentences), target != me,
                  FileManager.default.fileExists(atPath: epub.path) else { narrate(m.id); return }
            do {
                try await bridge.sendEPUB(epub, id: m.id, filename: m.title + ".epub", to: target)
                narratingElsewhere[m.id] = await bridge.deviceName(target) ?? "another Mac"
            } catch { narrate(m.id) }
        }
    }

    /// Books another device is narrating (id → its name); they arrive with their audio.
    @Published public private(set) var narratingElsewhere: [String: String] = [:]

    /// A reader window closed: its place and marks go out now.
    public func bookClosed() { Task { await runBridge() } }

    /// A book finished narrating or a setting changed: run the bridge a minute later (coalesced).
    func kickBridge(after seconds: Double = 5) {
        guard bridge != nil, bridgeKick == nil else { return }
        bridgeKick = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await self?.runBridge()
            self?.bridgeKick = nil
        }
    }

    let registry: DeviceRegistry
    let pairingWindow = PairingWindow()
    private var pairingTimer: Task<Void, Never>?

    /// Random, stable id for this Mac's library (tells iPhones which Mac is theirs).
    static func libraryID() -> String {
        if let id = UserDefaults.standard.string(forKey: "habla.libraryID") { return id }
        var bytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let id = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(id, forKey: "habla.libraryID")
        return id
    }

    // MARK: Pairing

    /// Shows a fresh code + QR for 10 minutes.
    public func startPairing() {
        let code = pairingWindow.open()
        refreshPairing()
        _ = code
        pairingTimer?.cancel()
        pairingTimer = Task { [weak self] in
            // Expire the sheet's code on time.
            try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            self?.refreshPairing()
        }
    }

    public func stopPairing() { pairingWindow.close(); refreshPairing() }

    private var joinTask: Task<Void, Never>?

    /// No account yet: keeps a fresh join QR code on screen (a new one when it expires or is
    /// used up) until an iPhone hands this Mac its account.
    public func showJoinCode() {
        joinTask?.cancel()
        joinTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.currentBridgeConfig == nil else { break }
                if self.pairingWindow.current == nil { self.pairingWindow.open() }
                self.refreshPairing()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            self?.pairingWindow.close()
            self?.refreshPairing()
        }
    }

    public func hideJoinCode() { joinTask?.cancel(); joinTask = nil; stopPairing() }

    /// An iPhone scanned the join QR code and handed over its account.
    func adoptAccount(_ config: BridgeConfig, name: String?) {
        guard currentBridgeConfig == nil else { return }
        try? FileManager.default.createDirectory(at: bridgeFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        saveBridgeFile(BridgeFile(url: config.url, libraryKey: config.libraryKey, enrollSecret: nil))
        if let name { accountName = name; UserDefaults.standard.set(name, forKey: "habla.accountName") }
        try? FileManager.default.removeItem(at: support.appendingPathComponent("bridge-state.json"))
        hideJoinCode()
        startBridge()
        objectWillChange.send()
    }

    public func forget(_ device: PairedDevice) {
        registry.forget(device.id)
        devices = registry.all
    }

    private func refreshPairing() {
        devices = registry.all
        guard let c = pairingWindow.current else { pairingCode = nil; return }
        let invite = PairingInvite(libraryID: server.libraryID ?? "", name: server.serviceName, address: serverAddress,
                                   fingerprint: server.tlsFingerprint ?? String(repeating: "0", count: 64), code: c.code)
        pairingCode = PairingCode(code: c.code, expires: c.expires, invite: invite.url)
    }

    public var serverName: String { server.serviceName }

    /// The model that narrates on this Mac (stamped on every chapter it makes).
    static let kokoroModel = KokoroEngine.describe(modelFile: KokoroEngine.Configuration.fastModel)

    /// What new narration uses right now, e.g. "Kokoro v1.0 · fast (int8) · 2 workers".
    public var engineDescription: String {
        let workers = EnginePool.kokoroWorkers()
        return "\(Self.kokoroModel) · \(workers) worker\(workers == 1 ? "" : "s")"
    }

    /// Credits for the About Habla panel: version, voice engine, and the models behind the library.
    public var aboutCredits: String {
        var seen: [String] = []
        for m in books {
            for x in m.narrationModels where !seen.contains(x) { seen.append(x) }
            if m.narrationModels.isEmpty, m.chapters.contains(where: { $0.audioStatus == .ready }), !seen.contains("Kokoro v1.0") { seen.append("Kokoro v1.0") }
        }
        return Imprint.about(models: seen, engine: engineDescription).dropFirst().joined(separator: "\n")
    }

    /// Kokoro workers for narration (two on most Macs).
    func makeEngine() -> EnginePool {
        let cfg = KokoroEngine.Configuration(toolsDirectory: voiceDirectory)
        return EnginePool((0..<EnginePool.kokoroWorkers()).map { _ in KokoroEngine(configuration: cfg) })
    }

    public var voiceDirectory: URL { support.appendingPathComponent("kokoro", isDirectory: true) }

    // MARK: Lifecycle

    private var started = false
    private var devicesRefreshed = Date.distantPast
    private var serving: NSObjectProtocol?

    public func start() {
        guard !started else { return }   // window reopened: keep the one server / watcher
        started = true
        refreshWorker()
        // Keep serving at full speed with no window open (no App Nap); the Mac may still sleep.
        serving = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                        reason: "Sharing your library with your iPhone")
        server.onInbox = { [weak self] file in
            Task { @MainActor in
                // Your iPhone added a book this Mac narrates for someone else: it's yours too now.
                if let self, let id = try? DocumentDigest.sha256Prefix(of: file), self.guestBooks[id] != nil {
                    self.guestBooks[id] = nil
                    self.narrate(id)
                }
                self?.importFiles([file], fromPhone: true)
            }
        }
        importInboxLeftovers()
        server.onDevice = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.phoneLastSeen = Date()
                if Date().timeIntervalSince(self.devicesRefreshed) > 30 { self.devicesRefreshed = Date(); self.devices = self.registry.all }
            }
        }
        pairingWindow.onChange = { [weak self] in Task { @MainActor in self?.refreshPairing() } }
        server.onJoin = { [weak self] config, name in Task { @MainActor in self?.adoptAccount(config, name: name) } }
        if !helperOnly { startServer() }                 // a helper doesn't share a library on Wi-Fi
        if Features.xteink { startXteinkWatcher() }
        startLibraryWatcher()
        resumeUnfinished()
        startBridge()
        startAllHelping()
    }

    private func startServer() {
        Task {
            do {
                let port = try await server.start()
                // Another program kept the usual port: still works (iPhones find this Mac by name).
                refreshAddress()
            } catch {
                alert = "Couldn't start sharing on Wi-Fi: \(error.localizedDescription)"
            }
        }
    }

    /// Books the iPhone sent while an import was interrupted (app quit, crash).
    private func importInboxLeftovers() {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: server.inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != "Failed" }
            .flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.pathExtension.lowercased() == "epub" }
        if !files.isEmpty { importFiles(files, fromPhone: true) }
    }

    private func refreshAddress() {
        let ip = LocalNetwork.primaryIPv4()
        onWiFi = ip != nil
        if let port = server.port { serverAddress = ip.map { "\($0):\(port)" } }
        refreshPairing()   // an open pairing QR code gets the address too
    }

    public func reload() {
        allBooks = server.allManifests()
        books = allBooks.filter { guestBooks[$0.id] == nil }
        for (id, _) in narratingElsewhere where books.first(where: { $0.id == id })?.isFullyRendered == true { narratingElsewhere[id] = nil }
        let after = allBooks.map { "\($0.id):\($0.revision)" }
        if after != lastLibraryStamp { lastLibraryStamp = after; kickBridge(); kickHelping() }
        if selection == nil || !books.contains(where: { $0.id == selection }) { selection = books.first?.id }
    }

    /// Picks up books added or changed outside the app (the `habla` CLI, Finder) and network changes.
    private func startLibraryWatcher() {
        Task { [weak self] in
            var last = ""
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                self.refreshAddress()
                let names = ((try? FileManager.default.contentsOfDirectory(atPath: self.library.path)) ?? []).sorted()
                let stamp = names.map { n -> String in
                    let d = (try? FileManager.default.attributesOfItem(atPath: self.library.appendingPathComponent(n).appendingPathComponent(BookBundle.manifestFile).path))?[.modificationDate] as? Date
                    return "\(n)@\(d?.timeIntervalSince1970 ?? 0)"
                }.joined(separator: "|")
                if stamp != last { if !last.isEmpty { self.reload() }; last = stamp }
            }
        }
    }

    private var lastLibraryStamp: [String] = []

    public var selected: BookManifest? { books.first { $0.id == selection } }

    public func item(_ m: BookManifest) -> BookItem { BookItem(manifest: m, position: progress.position(for: m.id)) }

    // MARK: Import

    /// `fromPhone`: sent by the iPhone — no alerts for duplicates, and the inbox copy is removed afterwards.
    public func importFiles(_ urls: [URL], fromPhone: Bool = false) {
        guard fromPhone || !helperOnly else { alert = "This Mac only helps narrate. Add books on your other devices."; return }
        let epubs = urls.filter { $0.pathExtension.lowercased() == "epub" }
        let rejected = urls.count - epubs.count
        guard !epubs.isEmpty else {
            if rejected > 0 { alert = "Only EPUB files can be added (\(rejected) other file\(rejected == 1 ? "" : "s") ignored)." }
            return
        }
        importing += epubs.map(\.lastPathComponent)
        let lib = library
        let inbox = server.inbox.standardizedFileURL.path
        let previous = importChain
        // One import at a time (two quick drops of the same file must not race).
        importChain = Task.detached(priority: .userInitiated) {
            await previous?.value
            let known = await MainActor.run { Set(self.allBooks.map(\.id)) }
            var added: [BookManifest] = [], duplicates: [String] = [], failures: [String] = []
            for url in epubs {
                var imported = true
                do {
                    let id = try DocumentDigest.sha256Prefix(of: url)
                    let manifestPath = BookBundle.url(for: id, in: lib).appendingPathComponent(BookBundle.manifestFile).path
                    if known.contains(id) || FileManager.default.fileExists(atPath: manifestPath) {
                        duplicates.append((try? BookBundle(url: BookBundle.url(for: id, in: lib)).manifest().title) ?? url.lastPathComponent)
                    } else {
                        added.append(try BookImporter().importEPUB(at: url, into: lib).manifest())
                    }
                } catch {
                    imported = false
                    failures.append("\(url.deletingPathExtension().lastPathComponent): \(StudioStore.describe(error))")
                }
                if url.standardizedFileURL.path.hasPrefix(inbox + "/") {
                    let folder = url.deletingLastPathComponent()
                    if !imported {
                        // Keep what the iPhone sent: never lose the only copy of a book.
                        let failed = URL(fileURLWithPath: inbox).appendingPathComponent("Failed", isDirectory: true)
                        try? FileManager.default.createDirectory(at: failed, withIntermediateDirectories: true)
                        try? FileManager.default.moveItem(at: url, to: failed.appendingPathComponent("\(Date().timeIntervalSince1970)-\(url.lastPathComponent)"))
                    }
                    try? FileManager.default.removeItem(at: folder)
                }
                let name = url.lastPathComponent
                await MainActor.run { self.importing.removeAll { $0 == name } }
            }
            await MainActor.run {
                self.reload()
                if let bridge = self.bridge { let ids = added.map(\.id); Task { for id in ids { await bridge.recordAdded(id) } } }
                if let first = added.first { self.selection = first.id }
                // Books from the iPhone are always narrated: nobody is at the Mac to start them.
                // A book sent here to narrate (from the iPhone or the other Mac) is narrated here;
                // one dropped on this Mac goes to whichever running device finishes it first.
                if fromPhone { for m in added { self.narrate(m.id) } }
                else if self.autoNarrate { for m in added { self.narrateHereOrElsewhere(m) } }
                if !added.isEmpty { self.kickXteink() }
                var lines: [String] = []
                if !duplicates.isEmpty && !fromPhone { lines.append("Already in your library: \(duplicates.joined(separator: ", ")).") }
                if !failures.isEmpty { lines.append("Couldn't add:\n" + failures.joined(separator: "\n")) }
                if rejected > 0 { lines.append("\(rejected) file\(rejected == 1 ? " wasn't an EPUB and was" : "s weren't EPUBs and were") ignored.") }
                if !lines.isEmpty {
                    if !added.isEmpty { lines.insert("Added \(added.count) book\(added.count == 1 ? "" : "s").", at: 0) }
                    self.alert = lines.joined(separator: "\n\n")
                }
            }
        }
    }

    private var importChain: Task<Void, Never>?

    nonisolated static func describe(_ error: Error) -> String {
        if let e = error as? EPUBError { return e.description }
        if let e = error as? ZipError { return "\(e.description) — the file may be damaged." }
        if let e = error as? TTSError { return e.description }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return "Your Mac is out of disk space." }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return "Your Mac is out of disk space." }
        return ns.localizedDescription
    }

    /// `everywhere`: the user deleted it, so it goes from every device of the account too.
    public func delete(_ id: String, everywhere: Bool = false) {
        if everywhere, guestBooks[id] == nil, let bridge {
            Task { await bridge.recordDeleted(id); kickBridge() }
        }
        queue.removeAll { $0 == id }          // first, so the finishing render can't pick it up again
        deleting.insert(id)
        Task {
            if render?.bookID == id {
                renderTask?.cancel()
                await renderTask?.value       // let the narration stop before removing its files
            }
            queue.removeAll { $0 == id }
            try? FileManager.default.removeItem(at: BookBundle.url(for: id, in: library))
            try? FileManager.default.removeItem(at: BookImporter.originalURL(for: id, in: library))
            progress.remove(id)
            var s = stopped; s.remove(id); stopped = s
            if guestBooks[id] != nil { guestBooks[id] = nil }   // files gone: nothing left to hide
            deleting.remove(id)
            reload()
            pump()
        }
    }

    private var deleting: Set<String> = []

    // MARK: Narration queue

    /// The voice the user picked for this book (overrides the one it was narrated with).
    /// The voice for a book: the one chosen for it, else the default, always in the book's language.
    public func voice(for m: BookManifest) -> String {
        let chosen = UserDefaults.standard.string(forKey: "habla.voice.\(m.id)") ?? m.voice?.voiceID ?? defaultVoice
        return BookLanguage.closestVoice(to: chosen, for: m.language, narrator: .kokoro)
    }

    /// Voices offered for a book (its language's voices).
    public func voices(for m: BookManifest) -> [String] { BookLanguage.voices(for: m.language, narrator: .kokoro) }

    public func setVoice(_ v: String, for m: BookManifest) {
        UserDefaults.standard.set(v, forKey: "habla.voice.\(m.id)")
        objectWillChange.send()
        guard m.voice != nil || queue.contains(m.id) else { return }   // never narrated: just remember it
        if render?.bookID == m.id {
            // Restart with the new voice (finished sentences of the old voice stay cached).
            renderTask?.cancel()
            Task { await renderTask?.value; self.narrate(m.id, unpause: false) }
        } else if m.voice?.voiceID != v {
            narrate(m.id, unpause: false)   // a setting change never resumes paused narration
        }
    }

    /// Queues a book. `unpause`: the user asked for narration now (the default).
    public func narrate(_ id: String, unpause: Bool = true) {
        // No voice for this language (German, Russian, Ukrainian, French, Hindi): the book stays
        // text-only. Unknown ids are refused too, so nothing can reach the queue un-checked.
        guard let m = allBooks.first(where: { $0.id == id }), m.canNarrate else { return }
        var s = stopped; s.remove(id); stopped = s
        if !queue.contains(id) { queue.append(id) }
        if unpause { paused = false }
        pump()
    }

    public func pauseNarration() {
        paused = true
        renderTask?.cancel()
    }

    /// Resumes narration, starting with `id` when given (the book whose Resume was pressed).
    public func resumeNarration(_ id: String? = nil) {
        if let id, queue.contains(id), render?.bookID != id {
            queue.removeAll { $0 == id }
            queue.insert(id, at: 0)
        }
        paused = false
        pump()
    }

    public func cancelNarration(_ id: String) {
        var s = stopped; s.insert(id); stopped = s
        if render?.bookID == id { renderTask?.cancel() }
        queue.removeAll { $0 == id }
    }

    private func resumeUnfinished() {
        let skip = stopped
        // Only languages with a voice may be narrated: a French/Hindi/German book narrated in an
        // earlier version must keep playing its existing audio, never be re-narrated in English.
        for m in allBooks where m.canNarrate && m.voice != nil && !m.chaptersToNarrate(voiceID: voice(for: m)).isEmpty
                                && !queue.contains(m.id) && !skip.contains(m.id) {
            queue.append(m.id)
        }
        pump()
    }

    private func pump() {
        guard renderTask == nil, !paused, let id = queue.first else { return }
        guard voiceEngine == .ready else { return }
        guard let m = allBooks.first(where: { $0.id == id }), !deleting.contains(id) else { queue.removeFirst(); pump(); return }
        let engine = self.engine ?? makeEngine()
        self.engine = engine
        let pipeline = RenderPipeline(engine: engine, cacheDirectory: support.appendingPathComponent("SentenceCache"))
        let bundle = BookBundle(url: BookBundle.url(for: id, in: library))
        let voice = VoiceInfo(engine: "kokoro", voiceID: voice(for: m))
        let redo = renarrating.contains(id)
        let model = redo ? Self.kokoroModel : nil
        let narratable = m.chapters.filter { $0.audioStatus != .skipped }
        let total = narratable.reduce(0) { $0 + $1.sentenceCount }
        let remaining = Set(m.chaptersToNarrate(voiceID: voice.voiceID, model: model).map(\.index))
        var done = narratable.filter { !remaining.contains($0.index) }.reduce(0) { $0 + $1.sentenceCount }
        recentSentenceTimes = []
        var lastTick = Date()
        render = RenderState(bookID: id, chapterTitle: "Starting…", sentence: 0, sentenceCount: 0, chaptersDone: 0,
                             chaptersTotal: 0, bookSentencesDone: done, bookSentencesTotal: total)
        // Keep the Mac awake while narrating (the display may still sleep).
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Narrating a book")

        renderTask = Task {
            var failure: String?
            do {
                try await pipeline.render(bundle, voice: voice, replaceOtherModels: redo) { p in
                    Task { @MainActor in
                        done += 1
                        let now = Date()
                        if !p.cacheHit {
                            self.recentSentenceTimes.append(now.timeIntervalSince(lastTick))
                            if self.recentSentenceTimes.count > 120 { self.recentSentenceTimes.removeFirst() }
                        }
                        lastTick = now
                        let avg = self.recentSentenceTimes.count >= 30
                            ? self.recentSentenceTimes.reduce(0, +) / Double(self.recentSentenceTimes.count) : nil
                        self.render = RenderState(
                            bookID: id, chapterIndex: p.chapterIndex, chapterTitle: ChapterNaming.title(p.chapterTitle, isFrontMatter: false),
                            sentence: p.sentence, sentenceCount: p.sentenceCount, chaptersDone: p.chaptersDone, chaptersTotal: p.chaptersTotal,
                            bookSentencesDone: min(done, total), bookSentencesTotal: total,
                            secondsLeft: avg.map { $0 * Double(max(0, total - done)) })
                        if p.sentence == p.sentenceCount {   // chapter finished → visible to the iPhone now
                            self.reload()
                            if let fresh = self.allBooks.first(where: { $0.id == id }) {
                                let left = Set(fresh.chaptersToNarrate(voiceID: voice.voiceID, model: model).map(\.index))
                                done = narratable.filter { !left.contains($0.index) }.reduce(0) { $0 + $1.sentenceCount }
                            }
                        }
                    }
                }
                if pipeline.skippedSentences > 0 {
                    failure = "“\(m.title)” is narrated, but \(pipeline.skippedSentences) sentence\(pipeline.skippedSentences == 1 ? "" : "s") couldn't be voiced and \(pipeline.skippedSentences == 1 ? "was" : "were") left as a short silence. Choose Narrate again later to retry them; if it keeps happening, install the voice engine again."
                }
            } catch is CancellationError {
            } catch {
                failure = StudioStore.describe(error)
            }
            await MainActor.run {
                if self.recentSentenceTimes.count >= 30 {
                    let sps = Double(self.recentSentenceTimes.count) / self.recentSentenceTimes.reduce(0, +)
                    StudioStore.narrationSpeed = StudioStore.narrationSpeed.map { $0 * 0.7 + sps * 0.3 } ?? sps
                }
                if let a = self.activity { ProcessInfo.processInfo.endActivity(a); self.activity = nil }
                self.renderTask = nil
                self.render = nil
                self.reload()
                let finished = self.allBooks.first { $0.id == id }.map { $0.chaptersToNarrate(voiceID: voice.voiceID, model: model).isEmpty } ?? true
                if finished { self.renarrating.remove(id) }
                if var failure {
                    if self.guestBooks[id] != nil { failure = "A book you're narrating for someone else: " + StudioStore.untitled(failure, m.title) }
                    self.alert = finished ? failure : "Narration stopped: \(failure)"
                    if !finished { self.paused = true; return }
                }
                if finished, self.queue.first == id { self.queue.removeFirst() }
                if self.queue.isEmpty { Task { await engine.shutdown() }; self.engine = nil }
                if finished { self.kickXteink() }
                self.pump()
            }
        }
    }

    // MARK: Voice preview

    public func preview(_ voice: String) {
        guard voiceEngine == .ready, previewing == nil else { return }
        previewing = voice
        let engine = self.engine ?? makeEngine()
        self.engine = engine
        Task {
            defer { Task { @MainActor in self.previewing = nil } }
            do {
                let text = "It was a bright cold day in April, and the clocks were striking thirteen. She smiled, and turned the page."
                let audio = try await engine.synthesize(text, voice: VoiceInfo(engine: "kokoro", voiceID: voice))
                guard !audio.samples.isEmpty else { return }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("habla-preview-\(voice).caf")
                let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audio.sampleRate, channels: 1, interleaved: false)!
                let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
                let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(audio.samples.count))!
                buf.frameLength = buf.frameCapacity
                audio.samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: audio.samples.count) }
                try file.write(from: buf)
                await MainActor.run {
                    self.previewPlayer = try? AVAudioPlayer(contentsOf: url)
                    self.previewPlayer?.play()
                }
            } catch {
                await MainActor.run { self.alert = "Preview failed: \(StudioStore.describe(error))" }
            }
        }
    }

    /// After an app update, use the bundled worker script (the model stays).
    private func refreshWorker() {
        guard let bundled = Bundle.main.url(forResource: "kokoro_worker", withExtension: "py"),
              FileManager.default.fileExists(atPath: voiceDirectory.path) else { return }
        let installed = voiceDirectory.appendingPathComponent("kokoro_worker.py")
        if (try? Data(contentsOf: installed)) != (try? Data(contentsOf: bundled)) {
            try? FileManager.default.removeItem(at: installed)
            try? FileManager.default.copyItem(at: bundled, to: installed)
        }
    }

    // MARK: Voice engine (Kokoro)

    /// Where Paradee lived while it was the Mac's voice (removed once Kokoro is ready).
    var oldParadeeDirectory: URL { support.appendingPathComponent("voice", isDirectory: true) }

    /// Ready only if the files exist AND Kokoro loads offline from this Mac.
    public func checkVoiceEngine() {
        let cfg = KokoroEngine.Configuration(toolsDirectory: voiceDirectory)
        let fm = FileManager.default
        guard [cfg.python, cfg.worker, cfg.model, cfg.voicesFile].allSatisfy({ fm.fileExists(atPath: $0.path) }) else {
            if case .installing = voiceEngine { return }
            voiceEngine = .missing
            // This Mac had Paradee: install Kokoro without asking again.
            if fm.fileExists(atPath: oldParadeeDirectory.path), let script = Bundle.main.url(forResource: "install", withExtension: "sh") {
                installVoiceEngine(script: script)
            }
            return
        }
        voiceEngine = .checking
        Task.detached {
            let p = Process()
            p.executableURL = cfg.python
            p.arguments = ["-I", "-c", "import sys, kokoro_onnx, numpy; kokoro_onnx.Kokoro(sys.argv[1], sys.argv[2])",
                           cfg.model.path, cfg.voicesFile.path]
            p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            let ok = (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
            await MainActor.run {
                self.voiceEngine = ok ? .ready : .failed("The voice engine is installed but doesn't start. Install it again.")
                if ok { self.pump(); self.removeOldParadee() }
            }
        }
    }

    /// Paradee (~250 MB) is no longer used on the Mac once Kokoro works.
    private func removeOldParadee() {
        guard render == nil, FileManager.default.fileExists(atPath: oldParadeeDirectory.path) else { return }
        try? FileManager.default.removeItem(at: oldParadeeDirectory)
    }

    // MARK: Re-narrate

    /// Books being narrated again with Kokoro (chapters another model made are redone).
    @Published public private(set) var renarrating: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "habla.renarrate") ?? []) {
        didSet { UserDefaults.standard.set(Array(renarrating), forKey: "habla.renarrate") }
    }

    /// Has chapters narrated by another model (Paradee): offer "Re-narrate with Kokoro".
    public func canRenarrate(_ m: BookManifest) -> Bool {
        m.canNarrate && !renarrating.contains(m.id) && m.narrated(byOtherThan: Self.kokoroModel)
    }

    /// Narrates the book again with Kokoro. Its old audio keeps playing until each chapter is replaced.
    public func renarrate(_ id: String) {
        guard let m = books.first(where: { $0.id == id }), canRenarrate(m) else { return }
        renarrating.insert(id)
        narrate(id)
    }

    /// Every book with Paradee audio.
    public var renarratable: [BookManifest] { books.filter(canRenarrate) }
    public func renarrateAll() { for m in renarratable { renarrate(m.id) } }

    public func installVoiceEngine(script: URL) {
        voiceEngine = .installing("Starting…")
        voiceEngineLog = []
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script.path, voiceDirectory.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let lines = String(decoding: h.availableData, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty }
            guard !lines.isEmpty else { return }
            Task { @MainActor in
                self.voiceEngineLog = Array((self.voiceEngineLog + lines).suffix(40))
                if let step = lines.last(where: { $0.hasPrefix("STEP ") }) { self.voiceEngine = .installing(String(step.dropFirst(5))) }
            }
        }
        p.terminationHandler = { proc in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .components(separatedBy: "\n").filter { !$0.isEmpty }
                self.voiceEngineLog = Array((self.voiceEngineLog + rest).suffix(40))
                if proc.terminationStatus == 0 { self.voiceEngine = .checking; self.engine = nil; self.checkVoiceEngine() }
                else {
                    let last = self.voiceEngineLog.last { !$0.hasPrefix("STEP ") && !$0.contains("HF_TOKEN") } ?? ""
                    self.voiceEngine = .failed("Install failed. \(last.isEmpty ? "Check your internet connection and try again." : last)")
                }
            }
        }
        do { try p.run() } catch { voiceEngine = .failed(error.localizedDescription) }
    }

    // MARK: Xteink

    struct XteinkCredentials: Codable { var username: String; var password: String; var configuredFor: String? }

    func xteinkCredentials() -> XteinkCredentials? {
        guard let d = try? Data(contentsOf: support.appendingPathComponent("xteink.json")) else { return nil }
        if let c = try? JSONDecoder().decode(XteinkCredentials.self, from: d) { return c }
        if let c = try? JSONDecoder().decode([String: String].self, from: d), let u = c["username"], let p = c["password"] {
            return XteinkCredentials(username: u, password: p)
        }
        return nil
    }

    func saveXteinkCredentials(_ c: XteinkCredentials) {
        try? JSONEncoder().encode(c).write(to: support.appendingPathComponent("xteink.json"), options: .atomic)
        server.koreaderKeyMD5 = KOReaderDigest.filename(c.password)
    }

    /// Ask the watcher to check right away (after an import, a finished narration, "Send now").
    public func kickXteink() { xteinkKick = true; lastPushSignature = nil; xteinkFailures = 0 }

    private func startXteinkWatcher() {
        xteinkTask = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                guard let self else { return }
                let found = await CrossPointDevice.discover(timeout: 1.2)
                if let device = found.first {
                    misses = 0
                    await self.serviceXteink(device)
                } else {
                    misses += 1
                    // Keep a failure visible until something succeeds; otherwise go back to "looking".
                    // Keep a failure visible for a while (~1 min), then go back to "looking".
                    if misses > 1, case .failed = self.xteink, misses < 10 {} else if misses > 1 { self.xteink = .looking }
                }
                // Every ~6 s; back off after repeated failures (30 s), immediately when kicked.
                let rounds = self.xteinkFailures >= 2 ? 60 : 12
                for _ in 0..<rounds where !self.xteinkKick { try? await Task.sleep(nanoseconds: 500_000_000) }
                self.xteinkKick = false
            }
        }
    }

    /// Configure once (and again if the Mac's address changed), then deliver missing books.
    private func serviceXteink(_ device: CrossPointDevice) async {
        guard let port = server.port else { return }
        guard let ip = LocalNetwork.primaryIPv4() else {
            xteink = .failed("This Mac isn't on Wi-Fi.")
            return
        }
        let macURL = URL(string: "http://\(ip):\(port)")!
        let sync = XteinkSync(device: device)
        do {
            let status = try await device.status()
            let name = "Xteink \(status.device ?? "")".trimmingCharacters(in: .whitespaces)
            var creds = xteinkCredentials() ?? XteinkCredentials(username: "habla", password: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased())
            if creds.configuredFor != macURL.absoluteString {
                xteink = .working("Setting up \(name)…")
                try await sync.configure(macBaseURL: macURL, username: creds.username, password: creds.password)
                creds.configuredFor = macURL.absoluteString
                saveXteinkCredentials(creds)
            }
            let signature = books.map { "\($0.id)" }.sorted().joined(separator: ",") + "@\(device.host)"
            if signature != lastPushSignature {
                xteink = .working("Checking \(name)…")
                let result = try await sync.pushBooks(from: library, only: Set(books.map(\.id))) { title in
                    Task { @MainActor in self.xteink = .working("Sending “\(title)”…") }
                }
                xteinkLastSync = Date()
                UserDefaults.standard.set(xteinkLastSync, forKey: "habla.xteinkLast")
                if let f = result.failed.first {
                    xteinkFailures += 1
                    xteink = .failed("Couldn't send “\(f.title)” (\(f.reason)). Retrying…")
                } else {
                    lastPushSignature = signature
                    xteinkFailures = 0
                    let n = result.sent.count + result.alreadyThere.count
                    xteink = .done(result.sent.isEmpty ? "\(n) book\(n == 1 ? "" : "s") on \(name) · up to date"
                                                        : "Sent \(result.sent.count) · \(n) on \(name)")
                }
            } else if case .working = xteink {
                xteink = .done("Up to date")
            }
        } catch {
            xteinkFailures += 1
            xteink = .failed("\((error as? SyncError)?.description ?? StudioStore.describe(error)). Retrying…")
        }
    }

    /// Snapshot/preview support.
    public func previewState(render: RenderState?, queue: [String], phoneLastSeen: Date?, xteink: XteinkState, server: String?) {
        self.render = render; self.queue = queue; self.phoneLastSeen = phoneLastSeen
        self.xteink = xteink; self.serverAddress = server
    }
}

/// Ids of guest books, readable from the server's queue and the bridge actor.
final class HiddenIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []
    func set(_ new: Set<String>) { lock.withLock { ids = new } }
    func contains(_ id: String) -> Bool { lock.withLock { ids.contains(id) } }
    var all: Set<String> { lock.withLock { ids } }
}
#endif
