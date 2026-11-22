#if os(macOS)
import Foundation
import SwiftUI
import AVFoundation
import HablaCore

/// Habla Studio (Mac): library, Kokoro narration queue, the sync server for the iPhone,
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

    public enum KokoroState: Equatable { case checking, ready, missing, installing(String), failed(String) }

    public enum XteinkState: Equatable {
        case looking
        case found(name: String, detail: String)
        case working(String)
        case done(String)
        case failed(String)
    }

    @Published public private(set) var books: [BookManifest] = []
    @Published public var selection: String?
    @Published public private(set) var importing: [String] = []
    @Published public var alert: String?
    @Published public private(set) var render: RenderState?
    @Published public private(set) var queue: [String] = []
    @Published public private(set) var paused: Bool = UserDefaults.standard.bool(forKey: "habla.paused") {
        didSet { UserDefaults.standard.set(paused, forKey: "habla.paused") }
    }
    @Published public private(set) var kokoro: KokoroState = .checking
    @Published public private(set) var kokoroLog: [String] = []
    @Published public private(set) var voices: [String] = StudioStore.defaultVoices
    @Published public var defaultVoice: String = UserDefaults.standard.string(forKey: "habla.voice") ?? "af_heart" {
        didSet { UserDefaults.standard.set(defaultVoice, forKey: "habla.voice") }
    }
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

    static let defaultVoices = ["af_heart", "af_bella", "af_nicole", "af_sarah", "am_michael", "am_fenrir",
                                "bf_emma", "bf_isabella", "bm_george", "bm_fable"]

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
        devices = registry.all
        reload()
        checkKokoro()
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

    /// What new narration uses right now, e.g. "Kokoro v1.0 · fast (int8) · 2 workers".
    public var engineDescription: String {
        let model = KokoroEngine.Configuration(toolsDirectory: kokoroDirectory).model.lastPathComponent
        let workers = EnginePool.recommendedWorkers(fastModel: model == KokoroEngine.Configuration.fastModel)
        return "\(KokoroEngine.describe(modelFile: model)) · \(workers) worker\(workers == 1 ? "" : "s")"
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

    /// Kokoro workers for narration: two on Macs with enough cores and memory (~40% faster).
    func makeEngine() -> EnginePool {
        let cfg = KokoroEngine.Configuration(toolsDirectory: kokoroDirectory)
        let fast = cfg.model.lastPathComponent == KokoroEngine.Configuration.fastModel
        return EnginePool((0..<EnginePool.recommendedWorkers(fastModel: fast)).map { _ in KokoroEngine(configuration: cfg) })
    }

    public var kokoroDirectory: URL { support.appendingPathComponent("kokoro", isDirectory: true) }

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
        Task {
            do {
                let port = try await server.start()
                // Another program kept the usual port: still works (iPhones find this Mac by name).
                refreshAddress()
            } catch {
                alert = "Couldn't start sharing on Wi-Fi: \(error.localizedDescription)"
            }
        }
        if Features.xteink { startXteinkWatcher() }
        startLibraryWatcher()
        resumeUnfinished()
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
            let known = await MainActor.run { Set(self.books.map(\.id)) }
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
                // Books from the iPhone are always narrated: nobody is at the Mac to start them.
                if self.autoNarrate || fromPhone { for m in added { self.narrate(m.id) } }
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

    public func delete(_ id: String) {
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
        return BookLanguage.voice(chosen, speaks: m.language) ? chosen : BookLanguage.defaultVoice(for: m.language)
    }

    /// Voices offered for a book (its language's voices).
    public func voices(for m: BookManifest) -> [String] { BookLanguage.voices(for: m.language) }

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
        // No voice for this language (German, Russian, Ukrainian): the book stays text-only.
        if let m = books.first(where: { $0.id == id }), !m.canNarrate { return }
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
        for m in books where m.voice != nil && !m.chaptersToNarrate(voiceID: voice(for: m)).isEmpty
                                && !queue.contains(m.id) && !skip.contains(m.id) {
            queue.append(m.id)
        }
        pump()
    }

    private func pump() {
        guard renderTask == nil, !paused, let id = queue.first else { return }
        guard kokoro == .ready else { return }
        guard let m = books.first(where: { $0.id == id }), !deleting.contains(id) else { queue.removeFirst(); pump(); return }
        let engine = self.engine ?? makeEngine()
        self.engine = engine
        let pipeline = RenderPipeline(engine: engine, cacheDirectory: support.appendingPathComponent("SentenceCache"))
        let bundle = BookBundle(url: BookBundle.url(for: id, in: library))
        let voice = VoiceInfo(engine: "kokoro", voiceID: voice(for: m))
        let narratable = m.chapters.filter { $0.audioStatus != .skipped }
        let total = narratable.reduce(0) { $0 + $1.sentenceCount }
        let remaining = Set(m.chaptersToNarrate(voiceID: voice.voiceID).map(\.index))
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
                try await pipeline.render(bundle, voice: voice) { p in
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
                            if let fresh = self.books.first(where: { $0.id == id }) {
                                let left = Set(fresh.chaptersToNarrate(voiceID: voice.voiceID).map(\.index))
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
                if let a = self.activity { ProcessInfo.processInfo.endActivity(a); self.activity = nil }
                self.renderTask = nil
                self.render = nil
                self.reload()
                let finished = self.books.first { $0.id == id }.map { $0.chaptersToNarrate(voiceID: voice.voiceID).isEmpty } ?? true
                if let failure {
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
        guard kokoro == .ready, previewing == nil else { return }
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
              FileManager.default.fileExists(atPath: kokoroDirectory.path) else { return }
        let installed = kokoroDirectory.appendingPathComponent("kokoro_worker.py")
        if (try? Data(contentsOf: installed)) != (try? Data(contentsOf: bundled)) {
            try? FileManager.default.removeItem(at: installed)
            try? FileManager.default.copyItem(at: bundled, to: installed)
        }
    }

    // MARK: Kokoro install

    /// Ready only if the files exist AND the Python environment can actually load Kokoro.
    public func checkKokoro() {
        let cfg = KokoroEngine.Configuration(toolsDirectory: kokoroDirectory)
        let fm = FileManager.default
        guard [cfg.python, cfg.worker, cfg.model, cfg.voicesFile].allSatisfy({ fm.fileExists(atPath: $0.path) }) else {
            if case .installing = kokoro {} else { kokoro = .missing }
            return
        }
        // A truncated model passes the import check but can't narrate: catch it here.
        func size(_ u: URL) -> Int { (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0 }
        let modelOK = cfg.model.lastPathComponent == KokoroEngine.Configuration.fastModel ? size(cfg.model) >= 90_000_000 : size(cfg.model) >= 300_000_000
        guard modelOK, size(cfg.voicesFile) >= 28_000_000 else {
            kokoro = .failed("The voice files are incomplete. Install the voice engine again.")
            return
        }
        kokoro = .checking
        Task.detached {
            let p = Process()
            p.executableURL = cfg.python
            p.arguments = ["-I", "-c", "import kokoro_onnx, soundfile, numpy"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            let ok = (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
            await MainActor.run {
                self.kokoro = ok ? .ready : .failed("The voice engine is installed but doesn't start. Install it again.")
                if ok { self.pump(); self.upgradeToFastModel() }
            }
        }
    }

    /// Installs made before the switch have only the full model: fetch the fast one quietly.
    /// Narration switches over at the next book (or next launch); the full model is then removed.
    private var upgrading = false
    func upgradeToFastModel() {
        let models = kokoroDirectory.appendingPathComponent("models", isDirectory: true)
        let fast = models.appendingPathComponent(KokoroEngine.Configuration.fastModel)
        let full = models.appendingPathComponent(KokoroEngine.Configuration.fullModel)
        let fm = FileManager.default
        if fm.fileExists(atPath: fast.path) {
            if fm.fileExists(atPath: full.path), render == nil { try? fm.removeItem(at: full) }
            return
        }
        guard !upgrading else { return }
        upgrading = true
        Task {
            defer { upgrading = false }
            let url = URL(string: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/\(KokoroEngine.Configuration.fastModel)")!
            guard let (tmp, resp) = try? await URLSession.shared.download(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  ((try? fm.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0) >= 92_000_000 else { return }
            try? fm.removeItem(at: fast)
            guard (try? fm.moveItem(at: tmp, to: fast)) != nil else { return }
            // New workers pick the fast model; the running ones finish their current book.
            if render == nil, let old = engine { engine = nil; await old.shutdown() }
            if render == nil { try? fm.removeItem(at: full) }
        }
    }

    public func installKokoro(script: URL) {
        kokoro = .installing("Starting…")
        kokoroLog = []
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script.path, kokoroDirectory.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let lines = String(decoding: h.availableData, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty }
            guard !lines.isEmpty else { return }
            Task { @MainActor in
                self.kokoroLog = Array((self.kokoroLog + lines).suffix(40))
                if let step = lines.last(where: { $0.hasPrefix("STEP ") }) { self.kokoro = .installing(String(step.dropFirst(5))) }
            }
        }
        p.terminationHandler = { proc in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .components(separatedBy: "\n").filter { !$0.isEmpty }
                self.kokoroLog = Array((self.kokoroLog + rest).suffix(40))
                if proc.terminationStatus == 0 { self.kokoro = .missing; self.checkKokoro() }
                else {
                    let last = self.kokoroLog.last { !$0.hasPrefix("STEP ") } ?? ""
                    self.kokoro = .failed("Install failed. \(last.isEmpty ? "Check your internet connection and try again." : last)")
                }
            }
        }
        do { try p.run() } catch { kokoro = .failed(error.localizedDescription) }
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
                let result = try await sync.pushBooks(from: library) { title in
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
