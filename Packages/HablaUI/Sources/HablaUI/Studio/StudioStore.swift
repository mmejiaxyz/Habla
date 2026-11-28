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

    /// The books on this Mac (the account's library).
    @Published public private(set) var books: [BookManifest] = []
    private var allBooks: [BookManifest] { books }
    @Published public var selection: String?
    @Published public private(set) var importing: [String] = []
    @Published public var alert: String?
    @Published public private(set) var render: RenderState?
    /// Books moving through the cloud, newest first (for the Activity popover).
    @Published public private(set) var activityEvents: [ActivityItem] = []
    /// Which running device narrates each book.
    @Published public private(set) var narratingOn: [String: String] = [:]
    /// The cloud is paused until this date (a free-tier allowance used up).
    @Published public private(set) var cloudPausedUntil: Date?

    /// Narration order, kept across launches (the order the user queued books in).
    @Published public private(set) var queue: [String] = UserDefaults.standard.stringArray(forKey: "habla.queue") ?? [] {
        didSet { UserDefaults.standard.set(queue, forKey: "habla.queue") }
    }
    @Published public private(set) var paused: Bool = UserDefaults.standard.bool(forKey: "habla.paused") {
        didSet {
            UserDefaults.standard.set(paused, forKey: "habla.paused")
            if !paused { pauseReason = nil }
        }
    }
    /// Why narration is paused when Habla paused it (an error), so "Paused" isn't a mystery later.
    @Published public private(set) var pauseReason: String? = UserDefaults.standard.string(forKey: "habla.pauseReason") {
        didSet { UserDefaults.standard.set(pauseReason, forKey: "habla.pauseReason") }
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
        server.opdsKey = xteinkCredentials().map { LibraryServer.opdsKey(password: $0.password) }
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
        devices = registry.all
        reload()
        checkVoiceEngine()
    }

    // MARK: Account (Docs/cloud-bridge.md)

    public let markers: MarkerStore
    /// When this Mac last talked to the account, for Settings.
    @Published public private(set) var bridgeSynced: Date? = UserDefaults.standard.object(forKey: "habla.accountSynced") as? Date {
        didSet { UserDefaults.standard.set(bridgeSynced, forKey: "habla.accountSynced") }
    }
    @Published public private(set) var bridgeUsage: BridgeUsage?
    private var bridge: AccountSync?
    private var bridgeLoop: Task<Void, Never>?
    private var bridgeKick: Task<Void, Never>?
    private var listener: BridgeListener?
    private var wakeObserver: NSObjectProtocol?

    /// `Security/bridge.json` (0600): the Worker's address and the account key. Never leaves this
    /// Mac except sealed inside a one-time code.
    struct BridgeFile: Codable { var url: URL; var libraryKey: Data?; var enrollSecret: String? }
    var bridgeFileURL: URL { support.appendingPathComponent("Security/bridge.json") }

    private func saveBridgeFile(_ f: BridgeFile) {
        try? FileManager.default.createDirectory(at: bridgeFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(f) else { return }
        try? d.write(to: bridgeFileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bridgeFileURL.path)
    }

    private var currentBridgeConfig: BridgeConfig? {
        guard let file = (try? Data(contentsOf: bridgeFileURL)).flatMap({ try? JSONDecoder().decode(BridgeFile.self, from: $0) }),
              let key = file.libraryKey else { return nil }
        return BridgeConfig(url: file.url, libraryKey: key)
    }

    /// The Worker's address: built into the app (`HablaBridgeURL`), else the one this Mac used before.
    public var bridgeURL: URL? {
        if let s = Bundle.main.object(forInfoDictionaryKey: "HablaBridgeURL") as? String, let u = URL(string: s), u.scheme == "https" { return u }
        return (try? Data(contentsOf: bridgeFileURL)).flatMap { try? JSONDecoder().decode(BridgeFile.self, from: $0) }?.url
    }

    /// The account's name (synced to every device).
    @Published public private(set) var accountName: String? = UserDefaults.standard.string(forKey: "habla.accountName")
    /// The account's other devices, as the account last told this Mac.
    @Published public private(set) var accountDevices: [AccountDevice] = []

    /// A one-time code on screen for a new device (Add a device…).
    public struct ShownCode: Equatable {
        public var code: String
        public var link: URL
        public var expires: Date
    }
    @Published public private(set) var shownCode: ShownCode?

    public var bridgeReady: Bool { bridge != nil }

    public enum AccountError: Error, Equatable, CustomStringConvertible {
        case noServer, badCode, codeNotFound, alreadyInAccount, failed(String)
        public var description: String {
            switch self {
            case .noServer: return "This copy of Habla doesn't know where your account lives. Enter the server address."
            case .badCode: return "That isn't a code. It looks like XXXX-XXXX-XXXX."
            case .codeNotFound: return "That code didn't work: it was used, it expired (after 15 minutes), or a character is off."
            case .alreadyInAccount: return "This Mac is already in an account."
            case .failed(let m): return m
            }
        }
    }

    /// Creates the account here (needs the Worker's server key, which only you have).
    public func createAccount(name: String, serverKey: String, server: URL? = nil) async throws {
        guard currentBridgeConfig == nil else { throw AccountError.alreadyInAccount }
        guard let url = server ?? bridgeURL else { throw AccountError.noServer }
        do {
            let config = try await AccountSync.createAccount(at: url, serverKey: serverKey.trimmingCharacters(in: .whitespacesAndNewlines))
            adopt(config, name: name)
        } catch BridgeError.unauthorized { throw AccountError.failed("The server key isn't right.") }
        catch let e as BridgeError { throw AccountError.failed(e.description) }
    }

    /// Joins an account with the one-time code another of its devices shows.
    public func joinAccount(code typed: String, server: URL? = nil) async throws {
        guard currentBridgeConfig == nil else { throw AccountError.alreadyInAccount }
        guard let code = JoinCode(typed) else { throw AccountError.badCode }
        guard let url = server ?? bridgeURL else { throw AccountError.noServer }
        do {
            let (config, name) = try await AccountSync.join(code, at: url)
            adopt(config, name: name)
        } catch BridgeError.http(404) { throw AccountError.codeNotFound }
        catch BridgeError.corrupt { throw AccountError.codeNotFound }
        catch let e as BridgeError { throw AccountError.failed(e.description) }
    }

    /// Shows a fresh one-time code (and its QR code) for a new device: 15 minutes, works once.
    public func showJoinCode() async {
        guard let bridge else { return }
        do {
            let code = try await bridge.makeJoinCode()
            shownCode = ShownCode(code: code.display, link: code.link(bridge: bridge.config.url), expires: Date().addingTimeInterval(15 * 60))
        } catch {
            alert = "Couldn't make a code: \((error as? BridgeError)?.description ?? error.localizedDescription)"
        }
    }

    public func hideJoinCode() { shownCode = nil }

    /// Logs this Mac out: the account forgets it, the account key leaves this Mac, nothing
    /// syncs through the cloud any more. Its books stay (and still play and read).
    public func leaveAccount() async {
        if let bridge { try? await bridge.leave() }
        bridgeLoop?.cancel(); listener?.stop(); listener = nil; bridge = nil
        bridgeKick?.cancel(); bridgeKick = nil
        try? FileManager.default.removeItem(at: bridgeFileURL)
        try? FileManager.default.removeItem(at: accountStateURL)
        accountName = nil; UserDefaults.standard.removeObject(forKey: "habla.accountName")
        accountDevices = []; narratingOn = [:]; shownCode = nil
        bridgeSynced = nil; assignedHere = []
        setServerAccount(nil)
        objectWillChange.send()
    }

    /// Removes a device from the account (e.g. this Mac before a clean install).
    public func forgetDevice(_ d: AccountDevice) {
        guard let bridge else { return }
        accountDevices.removeAll { $0.id == d.id }
        Task {
            try? await bridge.removeDevice(d.id)
            accountDevices = await bridge.devices()
        }
    }

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
        if started { server.stop(); startServer() }
    }

    private func adopt(_ config: BridgeConfig, name: String?) {
        saveBridgeFile(BridgeFile(url: config.url, libraryKey: config.libraryKey, enrollSecret: nil))
        if let name, !name.isEmpty { accountName = name; UserDefaults.standard.set(name, forKey: "habla.accountName") }
        try? FileManager.default.removeItem(at: accountStateURL)
        bridgeLoop?.cancel(); listener?.stop(); listener = nil; bridge = nil
        startBridge()
        if let name = accountName, let bridge { Task { await bridge.setName(name); kickBridge(after: 1) } }
        objectWillChange.send()
    }

    var accountStateURL: URL { support.appendingPathComponent("account-state.json") }
    var bridgeDeviceID: String { "mac-" + StudioStore.libraryID() }

    /// Starts talking to the account: a live connection for nudges, a round at once, a safety
    /// round every 6 hours.
    private func startBridge() {
        guard let config = currentBridgeConfig else { return }
        setServerAccount(BridgeKeys(libraryKey: config.libraryKey))
        let b = AccountSync(config: config, deviceID: bridgeDeviceID, deviceName: server.serviceName, kind: .mac,
                            progress: progress, markers: markers, library: library, stateURL: accountStateURL)
        bridge = b
        let model = Self.kokoroModel
        Task {
            await b.configure(readiness: { m, voice in
                let left = m.chaptersToNarrate(voiceID: voice, model: model)
                let leftIDs = Set(left.map(\.index))
                return (m.chapters.filter { $0.audioStatus == .ready && !leftIDs.contains($0.index) }.count,
                        m.canNarrate ? left.reduce(0) { $0 + $1.sentenceCount } : 0)
            })
            await b.setActivityHandler { [weak self] item in Task { @MainActor in self?.activityEvents.note(item) } }
        }
        bridgeLoop = Task { [weak self] in
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

    /// Books the account gave this Mac to narrate (resumed at launch).
    private var assignedHere: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "habla.assignedHere") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "habla.assignedHere") }
    }

    /// The account decides who narrates while this Mac can reach it; offline for half an hour
    /// (or no account), this Mac narrates its own books.
    var accountDecides: Bool {
        guard bridge != nil, let at = bridgeSynced else { return false }
        return Date().timeIntervalSince(at) < 30 * 60
    }

    /// One round with the account: report, take what's offered, send what's asked, narrate what
    /// it gives this Mac, delete what was deleted elsewhere.
    func runBridge() async {
        guard let bridge else { return }
        do {
            await bridge.setNarrator(narratorStatus)
            await bridge.setEndpoints(serverAddress.map { [$0] } ?? [])
            await bridge.setBusy(Set(render.map { [$0.bookID] } ?? []))
            let r = try await bridge.sync()
            let s = await bridge.settings
            if s.voiceAt.timeIntervalSince1970 > 0, s.voice != defaultVoice { applyingAccountVoice = true; defaultVoice = s.voice; applyingAccountVoice = false }
            if let name = s.name, name != accountName { accountName = name; UserDefaults.standard.set(name, forKey: "habla.accountName") }
            else if s.name == nil, let name = accountName { await bridge.setName(name) }
            accountDevices = await bridge.devices()
            narratingOn = await bridge.narratingDevices()
            cloudPausedUntil = await bridge.pausedUntil
            for id in r.deleted { removeFromXteink(id); delete(id) }
            if !r.arrived.isEmpty { reload(); kickXteink() }
            // The account decides who narrates: what it gives this Mac is queued; what it gave
            // another device isn't narrated here too.
            let mine = Set(r.narrate)
            assignedHere = mine
            for id in r.narrate where !queue.contains(id) && render?.bookID != id && !stopped.contains(id) { narrate(id, unpause: false) }
            for id in queue where !mine.contains(id) && narratingOn[id] != nil {
                if render?.bookID == id { renderTask?.cancel() }
                queue.removeAll { $0 == id }
            }
            bridgeSynced = Date()
            bridgeUsage = try? await bridge.client.usage()
        } catch {
            cloudPausedUntil = await bridge.pausedUntil           // a cap reached: say so in Activity
            if !accountDecides { resumeUnfinished() }               // offline a while: narrate here
        }
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

    /// A reader window closed: its place and marks go out now.
    public func bookClosed() { Task { await runBridge() } }

    /// A book finished narrating or a setting changed: a round a few seconds later (coalesced).

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
            Task { @MainActor in self?.importFiles([file], fromPhone: true) }
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
        startServer()
        // The Xteink reads the Mac's places and sends its own here; they go on to the account
        // right away (it has no account of its own).
        server.onEReaderPosition = { [weak self] _ in
            Task { @MainActor in self?.reload(); self?.kickBridge(after: 2) }
        }
        if Features.xteink { startXteinkWatcher() }
        startLibraryWatcher()
        resumeUnfinished()
        upgradeAudioFormat()
        startBridge()
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
        books = server.manifests()
        let after = books.map { "\($0.id):\($0.revision)" }
        if after != lastLibraryStamp { lastLibraryStamp = after; kickBridge() }
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
                if let first = added.first { self.selection = first.id }
                // In an account, the account decides who narrates (usually this Mac) and offers the
                // book to every device. Without one (or offline a while), this Mac narrates it.
                if let bridge = self.bridge, self.accountDecides {
                    let ids = added.map(\.id)
                    Task { for id in ids { await bridge.recordAdded(id) }; self.kickBridge(after: 1) }
                } else {
                    if let bridge = self.bridge { let ids = added.map(\.id); Task { for id in ids { await bridge.recordAdded(id) } } }
                    if fromPhone || self.autoNarrate { for m in added { self.narrate(m.id) } }
                    if !added.isEmpty { self.kickBridge(after: 2) }
                }
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
        if everywhere {
            removeFromXteink(id)
            if let bridge { Task { await bridge.recordDeleted(id); kickBridge() } }
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

    /// Re-saves audio made with the older, larger setting as HE-AAC 24 kbps (about a third of
    /// the size), one book at a time in the background. Books being narrated are left for later.
    private func upgradeAudioFormat() {
        let candidates = allBooks.map(\.id)
        let lib = library
        Task.detached(priority: .utility) { [weak self] in
            for id in candidates {
                let busy = await MainActor.run { self?.render?.bookID == id || self?.queue.contains(id) == true || self?.deleting.contains(id) == true }
                if busy { continue }
                let bundle = BookBundle(url: BookBundle.url(for: id, in: lib))
                guard (try? AudioUpgrade.upgrade(bundle)) == true else { continue }
                await MainActor.run { self?.reload(); self?.kickBridge(after: 5) }
            }
        }
    }

    private func resumeUnfinished() {
        // In an account, only what the account gave this Mac (it decides who narrates).
        let decides = accountDecides, mine = assignedHere
        let skip = stopped.union(decides ? Set(allBooks.map(\.id)).subtracting(mine) : [])
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
        let gaps = retryingGaps.contains(id)
        let model = redo ? Self.kokoroModel : nil
        let narratable = m.chapters.filter { $0.audioStatus != .skipped }
        let total = narratable.reduce(0) { $0 + $1.sentenceCount }
        let remaining = Set(m.chaptersToNarrate(voiceID: voice.voiceID, model: model, retryGaps: gaps).map(\.index))
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
                try await pipeline.render(bundle, voice: voice, replaceOtherModels: redo, retryGaps: gaps) { p in
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
                            self.kickBridge(after: 5)        // and on its way to the other devices
                            if let fresh = self.allBooks.first(where: { $0.id == id }) {
                                let left = Set(fresh.chaptersToNarrate(voiceID: voice.voiceID, model: model, retryGaps: gaps).map(\.index))
                                done = narratable.filter { !left.contains($0.index) }.reduce(0) { $0 + $1.sentenceCount }
                            }
                        }
                    }
                }
                if pipeline.skippedSentences > 0 {
                    let n = pipeline.skippedSentences
                    failure = "“\(m.title)” is narrated, but \(n) sentence\(n == 1 ? "" : "s") couldn't be voiced and \(n == 1 ? "was" : "were") left as a short silence. Choose Retry silent parts on the book to try again; if it keeps happening, install the voice engine again."
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
                self.retryingGaps.remove(id)                      // one try per request: no loop
                if var failure {
                    self.alert = finished ? failure : "Narration stopped: \(failure)"
                    if !finished { self.paused = true; self.pauseReason = "stopped after an error. Choose Resume to try again"; return }
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

    /// Books whose silent sentences (the engine couldn't voice them) are being tried again.
    @Published public private(set) var retryingGaps: Set<String> = []

    /// Tries the silent sentences of a narrated book again (cached sentences make it quick).
    public func retryGaps(_ id: String) {
        guard let m = books.first(where: { $0.id == id }), m.canNarrate, m.silentSentences > 0 else { return }
        retryingGaps.insert(id)
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
        server.opdsKey = LibraryServer.opdsKey(password: c.password)
    }

    /// Books deleted from the account, still to take off the Xteink when it's next in reach.
    var xteinkRemovals: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "habla.xteinkRemove") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "habla.xteinkRemove") }
    }

    func removeFromXteink(_ id: String) {
        guard Features.xteink, books.contains(where: { $0.id == id }) else { return }
        var r = xteinkRemovals; r.insert(id); xteinkRemovals = r
        kickXteink()
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
            let target = macURL.absoluteString + "#keyed"   // set up before the catalog had a key: redo once
            if creds.configuredFor != target {
                xteink = .working("Setting up \(name)…")
                try await sync.configure(macBaseURL: macURL, username: creds.username, password: creds.password)
                creds.configuredFor = target
                saveXteinkCredentials(creds)
            }
            let signature = books.map { "\($0.id)" }.sorted().joined(separator: ",") + "@\(device.host)"
            let removals = xteinkRemovals
            if signature != lastPushSignature || !removals.isEmpty {
                xteink = .working("Checking \(name)…")
                if !removals.isEmpty {
                    let removed = try await sync.removeBooks(removals)
                    xteinkRemovals = xteinkRemovals.subtracting(removed)
                }
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

#endif
