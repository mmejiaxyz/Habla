import Foundation
import CryptoKit

/// One file of a transfer, cut into sealed chunks of `BridgeKeys.chunkSize`.
public struct TransferFile: Codable, Equatable, Sendable {
    public var path: String
    public var size: Int
    public var sha256: String
    public var chunks: Int
}

/// Something passing through the bridge: a narrated book (Mac → phones) or an EPUB (phone → Mac).
public struct Transfer: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case book, epub }
    public var id: String
    public var kind: Kind
    public var bookID: String?
    public var revision: Int?
    public var filename: String?
    public var manifest: BookManifest?
    public var files: [TransferFile]
    public var createdAt: Date
    /// EPUB: the device chosen to narrate it, and the account voice to use.
    public var target: String? = nil
    public var voice: String? = nil

    func logical(_ file: TransferFile, chunk: Int) -> String {
        switch kind {
        case .book: return "book/\(bookID ?? id)/\(revision ?? 0)/\(file.path)#\(chunk)"
        case .epub: return "epub/\(id)#\(chunk)"
        }
    }
}

/// How fast a device narrates and how much it has queued, so new books go where they finish first.
public struct NarratorStatus: Codable, Equatable, Sendable {
    /// Measured on this device (sentences voiced per second of wall time).
    public var sentencesPerSecond: Double
    public var queuedSentences: Int
    public var measured: Bool
    public init(sentencesPerSecond: Double, queuedSentences: Int, measured: Bool) {
        self.sentencesPerSecond = sentencesPerSecond; self.queuedSentences = queuedSentences; self.measured = measured
    }
    /// Seconds until a book of `sentences` would be finished here.
    public func finish(_ sentences: Int) -> Double { Double(queuedSentences + sentences) / max(0.01, sentencesPerSecond) }
}

/// Settings shared by every device of the account (latest change wins).
public struct AccountSettings: Codable, Equatable, Sendable {
    /// The narration voice for every book on every device (Heart unless changed in Settings).
    public var voice: String
    public var changedAt: Date
    public init(voice: String, changedAt: Date) { self.voice = voice; self.changedAt = changedAt }
    public static let initial = AccountSettings(voice: "af_heart", changedAt: Date(timeIntervalSince1970: 0))
}

public struct HeldBook: Codable, Equatable, Sendable {
    public var bookID: String
    public var revision: Int
}

/// What each device publishes about itself (sealed; logical name `state/<deviceID>`).
public struct DeviceDocument: Codable, Equatable, Sendable {
    /// `helper`: a Mac that only narrates for the account. It never shows the books, never
    /// syncs places or marks, never receives finished books, and deletes what it narrated
    /// once every device has collected it.
    public enum Role: String, Codable, Sendable { case mac, phone, helper }
    public var v = 1
    public var deviceID: String
    public var deviceName: String
    public var kind: Role
    public var updatedAt: Date
    public var positions: [ReadingPosition]
    public var markers: [Marker]
    public var has: [HeldBook]
    public var outbox: [Transfer]
    /// Mac: the phones each book waits for. Phone: unused.
    public var recipients: [String]
    /// Transfer ids this device has fully received (EPUBs to narrate).
    public var received: [String]
    /// When this device last checked in (refreshed every few minutes while it runs).
    public var lastActive: Date? = nil
    /// Its narration speed and queue (nil: it can't narrate now, e.g. no voice installed).
    public var narrator: NarratorStatus? = nil
    public var settings: AccountSettings? = nil
}

/// Sync through the Cloudflare bridge (Docs/cloud-bridge.md). Every byte leaves this device sealed.
public actor BridgeSync {
    public let client: BridgeClient
    let keys: BridgeKeys
    public let deviceID: String
    let deviceName: String
    let role: DeviceDocument.Role
    let progress: ProgressStore
    let markers: MarkerStore
    let library: URL
    let stateURL: URL
    /// Where EPUBs sent to this device for narrating land, and who imports them.
    var inbox: URL?
    var onEPUB: (@Sendable (URL, String?) -> Void)?
    /// Helper: a book it narrated reached every device; remove the local copy.
    var onJobDone: (@Sendable (String) -> Void)?
    /// Books narrated here for another library: this sync never lists, sends or reports them.
    var hidden: @Sendable () -> Set<String> = { [] }
    var log: @Sendable (String) -> Void = { _ in }

    /// Kept between launches: what other devices said last, our own transfers, what was sent.
    struct Saved: Codable {
        var etags: [String: String] = [:]
        var docs: [String: DeviceDocument] = [:]
        var outbox: [Transfer] = []
        var received: [String] = []
        /// Mac: the newest revision of each book already sent (so only new books travel).
        var published: [String: Int] = [:]
        var uploadedHash: String?
        var settings: AccountSettings = .initial
        /// When each device last checked in (from the Worker's listing).
        var seen: [String: Date] = [:]
        /// Devices listening on the bridge at the last look (their live connection is open).
        var online: Set<String> = []
        var pausedUntil: Date?
        /// Books installed from another device (never sent on again from here).
        var receivedBooks: [String: Int] = [:]
        /// Phone: books it narrated itself (the only ones it sends).
        var narratedHere: [String] = []
        /// Helper: books it was sent to narrate (the only ones it keeps, until collected).
        var jobs: [String] = []
    }
    var saved: Saved
    public var pausedUntil: Date? { saved.pausedUntil }
    /// The account's settings as last merged (voice).
    public var settings: AccountSettings { saved.settings }

    /// Changed in Settings on this device: it becomes every device's setting.
    public func setVoice(_ voice: String) {
        guard voice != saved.settings.voice else { return }
        saved.settings = AccountSettings(voice: voice, changedAt: Date())
        save()
    }
    var narrator: NarratorStatus?
    /// A device counts as running if it checked in this recently.
    static let activeWindow: TimeInterval = 5 * 60      // without a live connection

    static let transitLifetime: TimeInterval = 14 * 86400

    public init(config: BridgeConfig, deviceID: String, deviceName: String, role: DeviceDocument.Role,
                progress: ProgressStore, markers: MarkerStore, library: URL, stateURL: URL, session: URLSession = .shared) {
        keys = BridgeKeys(libraryKey: config.libraryKey)
        client = BridgeClient(baseURL: config.url, token: keys.token, device: keys.objectName("state/\(deviceID)"), session: session)
        self.deviceID = deviceID; self.deviceName = deviceName; self.role = role
        self.progress = progress; self.markers = markers; self.library = library; self.stateURL = stateURL
        saved = (try? Data(contentsOf: stateURL)).flatMap { try? JSON.decoder.decode(Saved.self, from: $0) } ?? Saved()
    }

    public func configure(inbox: URL? = nil, onEPUB: (@Sendable (URL, String?) -> Void)? = nil,
                          onJobDone: (@Sendable (String) -> Void)? = nil,
                          hidden: @escaping @Sendable () -> Set<String> = { [] },
                          log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.inbox = inbox; self.onEPUB = onEPUB; self.onJobDone = onJobDone; self.hidden = hidden; self.log = log
    }

    /// This device's narration speed and queue, published with the next sync.
    public func setNarrator(_ status: NarratorStatus?) { narrator = status }

    /// Phone: a book it narrated itself, to send to the other devices.
    public func markNarratedHere(_ id: String) {
        if !saved.narratedHere.contains(id) { saved.narratedHere.append(id); save() }
    }

    // MARK: - Positions and markers

    /// Reads what changed on other devices, merges it, and publishes this device's document.
    public func syncState() async throws {
        try await guarded {
            try await self.pull()
            try await self.pushOwnDocument()
        }
    }

    /// Fresh documents of the other devices (only those whose etag moved are downloaded).
    func pull() async throws {
        let objects = try await client.list(.state)
        let ownName = keys.objectName("state/\(deviceID)")
        var seen = Set<String>()
        saved.online = Set(objects.filter { $0.online == true }.map(\.name))
        for o in objects where o.name != ownName {
            seen.insert(o.name)
            if let at = o.seen.flatMap(Self.iso) { saved.seen[o.name] = at }
            guard o.etag == nil || o.etag != saved.etags[o.name] || saved.docs[o.name] == nil else { continue }
            let (data, etag) = try await client.get(.state, o.name, etag: saved.docs[o.name] == nil ? nil : saved.etags[o.name])
            guard let data else { continue }
            // Sealed under "state"; the document must name the device whose slot it sits in.
            guard let plain = try? keys.open(data, logical: "state"),
                  let doc = try? JSON.decoder.decode(DeviceDocument.self, from: plain),
                  keys.objectName("state/\(doc.deviceID)") == o.name else { log("bridge: skipped an unreadable document"); continue }
            saved.docs[o.name] = doc
            saved.etags[o.name] = etag ?? o.etag
            if role != .helper {                                 // a helper never takes places or marks
                for p in doc.positions { progress.merge(p) }
                markers.merge(doc.markers)
            }
            if let s = doc.settings, s.changedAt > saved.settings.changedAt { saved.settings = s }
        }
        for gone in saved.docs.keys where !seen.contains(gone) { saved.docs[gone] = nil; saved.etags[gone] = nil; saved.seen[gone] = nil }
        save()
    }

    func ownDocument() -> DeviceDocument {
        if role == .helper {
            return DeviceDocument(deviceID: deviceID, deviceName: deviceName, kind: role, updatedAt: Date(), positions: [], markers: [],
                                  has: [], outbox: saved.outbox, recipients: recipients(), received: saved.received,
                                  lastActive: nil, narrator: narrator, settings: nil)
        }
        return DeviceDocument(deviceID: deviceID, deviceName: deviceName, kind: role, updatedAt: Date(),
                       positions: progress.all.sorted { $0.bookID < $1.bookID },
                       markers: markers.all.sorted { $0.id.uuidString < $1.id.uuidString },
                       has: localBooks().map { HeldBook(bookID: $0.id, revision: $0.revision) }.sorted { $0.bookID < $1.bookID },
                       outbox: saved.outbox, recipients: recipients(), received: saved.received,
                       lastActive: nil, narrator: narrator, settings: saved.settings)
    }

    /// Uploads this device's document when its content changed.
    func pushOwnDocument() async throws {
        var doc = ownDocument()
        doc.updatedAt = Date(timeIntervalSince1970: 0)
        let hash = SHA256.hash(data: try JSON.encoder.encode(doc)).map { String(format: "%02x", $0) }.joined()
        guard hash != saved.uploadedHash else { return }          // nothing new: no upload
        doc.updatedAt = Date()
        let sealed = try keys.seal(try JSON.encoder.encode(doc), logical: "state", padTo: BridgeKeys.statePadding)
        try await client.put(.state, keys.objectName("state/\(deviceID)"), sealed)
        saved.uploadedHash = hash
        save()
    }

    var others: [DeviceDocument] { Array(saved.docs.values) }

    /// Phone: the books the Mac has (an EPUB sent through the bridge has arrived once it's here).
    #if DEBUG
    func recordJobForTest(_ id: String) { saved.jobs.append(id) }
    #endif

    /// Helper: books it is narrating or delivering.
    public var jobs: [String] { saved.jobs }

    public func booksOnMac() -> Set<String> { Set(others.filter { $0.kind == .mac }.flatMap { $0.has.map(\.bookID) }) }

    /// Every other device holding this library's key that checked in during the last 30 days.
    func recipients() -> [String] {
        others.filter { d in
            guard d.kind != .helper else { return false }        // helpers don't keep books
            let at = saved.seen[keys.objectName("state/\(d.deviceID)")] ?? d.updatedAt
            return Date().timeIntervalSince(at) < 30 * 86400
        }.map(\.deviceID).sorted()
    }

    /// Running = its live connection is open right now (a sleeping Mac isn't), or it checked
    /// in within the last few minutes.
    func isActive(_ d: DeviceDocument, now: Date = Date()) -> Bool {
        let name = keys.objectName("state/\(d.deviceID)")
        if saved.online.contains(name) { return true }
        return now.timeIntervalSince(saved.seen[name] ?? .distantPast) < Self.activeWindow
    }

    static func iso(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Which device should narrate a new book of `sentences`: the running Mac (or this device)
    /// that would finish it first. A remote Mac must win clearly (moving the EPUB costs time).
    public func chooseNarrator(sentences: Int, excluding: Set<String> = []) -> String? {
        var best: (id: String, time: Double)? = narrator.map { (deviceID, $0.finish(sentences)) }
        for d in others where d.kind != .phone && isActive(d) && !excluding.contains(d.deviceID) {
            guard let n = d.narrator else { continue }
            let t = n.finish(sentences) * 1.1 + 60
            if best == nil || t < best!.time { best = (d.deviceID, t) }
        }
        return best?.id
    }

    public func deviceName(_ id: String) -> String? { id == deviceID ? deviceName : others.first { $0.deviceID == id }?.deviceName }

    // MARK: - Books, Mac → phones

    /// Mac: sends every finished book the phones don't have yet, if it fits the free storage.
    /// Returns the ids sent. Books that don't fit wait for a later call.
    @discardableResult
    public func publishNewBooks() async throws -> [String] {
        var sent: [String] = []
        try await guarded {
            let targets = self.recipients()
            guard !targets.isEmpty else { return }
            let held = self.others.filter { targets.contains($0.deviceID) }
            // A Mac sends what it narrated (or imported, text-only); a phone only what it narrated.
            let mine = self.localBooks().filter { m in
                m.isFullyRendered && self.saved.receivedBooks[m.id] != m.revision
                    && (self.role == .mac || (self.role == .phone ? self.saved.narratedHere : self.saved.jobs).contains(m.id))
            }
            for m in mine {
                guard m.revision > (self.saved.published[m.id] ?? 0),
                      !held.allSatisfy({ $0.has.contains { $0.bookID == m.id && $0.revision >= m.revision } }) else { continue }
                let size = m.files.reduce(0) { $0 + $1.size }
                let usage = try await self.client.usage()
                guard usage.freeBytes > size + size / 10 else { self.log("bridge: waiting for room to send \(m.id)"); continue }
                let transfer = Transfer(id: "\(m.id)-\(m.revision)", kind: .book, bookID: m.id, revision: m.revision, filename: nil, manifest: m,
                                        files: m.files.map { TransferFile(path: $0.path, size: $0.size, sha256: $0.sha256, chunks: Self.chunks($0.size)) },
                                        createdAt: Date())
                let bundle = BookBundle(url: BookBundle.url(for: m.id, in: self.library))
                try await self.upload(transfer) { bundle.fileURL($0.path) }
                for old in self.saved.outbox where old.bookID == m.id { try await self.deleteChunks(old) }
                self.saved.outbox.removeAll { $0.bookID == m.id }
                self.saved.outbox.append(transfer)
                self.saved.published[m.id] = m.revision
                self.save()
                sent.append(m.id)
                try await self.pushOwnDocument()
            }
        }
        return sent
    }

    // MARK: - Books, received on a phone

    /// Installs books other devices sent that have more audio than the local copy (or the same
    /// audio, newer). Returns their ids.
    @discardableResult
    public func receiveBooks() async throws -> [String] {
        guard role != .helper else { return [] }
        var installed: [String] = []
        try await guarded {
            let local = Dictionary(self.localBooks().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            func ready(_ m: BookManifest) -> Int { m.chapters.filter { $0.audioStatus == .ready }.count }
            for doc in self.others {
                for t in doc.outbox where t.kind == .book {
                    guard let m = t.manifest, m.id == t.bookID, !installed.contains(m.id) else { continue }
                    if let mine = local[m.id] {
                        guard ready(m) > ready(mine) || (ready(m) == ready(mine) && m.revision > mine.revision) else { continue }
                    }
                    do {
                        try await self.install(t, manifest: m)
                        installed.append(m.id)
                        self.saved.receivedBooks[m.id] = m.revision
                        self.save()
                    }
                    catch BridgeError.corrupt { self.log("bridge: a book didn't verify; it was left out") }
                }
            }
            if !installed.isEmpty { try await self.pushOwnDocument() }
        }
        return installed
    }

    /// Writes each file only after its bytes match the manifest; the manifest goes last, so a
    /// stopped transfer never leaves a broken book. Files that already match aren't downloaded.
    func install(_ t: Transfer, manifest m: BookManifest) async throws {
        guard BookBundle.isSafeRelativePath(m.id), !m.id.contains("/"),
              m.files.allSatisfy({ BookBundle.isSafeRelativePath($0.path) }) else { throw BridgeError.corrupt }
        let bundle = BookBundle(url: BookBundle.url(for: m.id, in: library))
        let fm = FileManager.default
        let old = try? bundle.manifest()
        let oldHashes = Dictionary((old?.files ?? []).map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        for f in t.files {
            let dest = bundle.fileURL(f.path)
            if oldHashes[f.path] == f.sha256, (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) == f.size { continue }
            let temp = try await download(t, f)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: temp) } else { try fm.moveItem(at: temp, to: dest) }
        }
        let keep = Set(m.files.map(\.path))
        for f in old?.files ?? [] where !keep.contains(f.path) { try? fm.removeItem(at: bundle.fileURL(f.path)) }
        try bundle.write(m, to: BookBundle.manifestFile, pretty: true)
    }

    // MARK: - EPUBs, phone → Mac

    /// Phone: sends an EPUB to the Mac through the bridge. `id` is the inbox id the LAN path uses.
    public func sendEPUB(_ file: URL, id: String, filename: String, to target: String? = nil) async throws {
        guard !saved.outbox.contains(where: { $0.id == id }) else { return }
        try await guarded {
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            let t = Transfer(id: id, kind: .epub, bookID: nil, revision: nil, filename: filename, manifest: nil,
                             files: [TransferFile(path: "book.epub", size: size, sha256: try BookBundle.sha256(of: file), chunks: Self.chunks(size))],
                             createdAt: Date(), target: target, voice: saved.settings.voice)
            try await self.upload(t) { _ in file }
            self.saved.outbox.append(t)
            self.save()
            try await self.pushOwnDocument()
        }
    }

    /// Mac: collects EPUBs phones sent, into the inbox (then `onEPUB` imports them).
    @discardableResult
    public func receiveEPUBs() async throws -> [URL] {
        guard let inbox else { return [] }
        var files: [URL] = []
        try await guarded {
            for doc in self.others {
                for t in doc.outbox where t.kind == .epub && !self.saved.received.contains(t.id)
                    && (t.target == self.deviceID || (t.target == nil && self.role == .mac)) {
                    guard t.id.count == 16, t.id.allSatisfy(\.isHexDigit), let f = t.files.first else { continue }
                    do {
                        let temp = try await self.download(t, f)
                        var name = (t.filename ?? "\(t.id).epub").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                        if name.hasPrefix(".") || name.isEmpty { name = "\(t.id).epub" }
                        let folder = inbox.appendingPathComponent(t.id, isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let dest = folder.appendingPathComponent(name)
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.moveItem(at: temp, to: dest)
                        self.saved.received.append(t.id)
                        if self.role == .helper { self.saved.jobs.append(t.id) }
                        self.save()
                        files.append(dest)
                        self.onEPUB?(dest, t.voice)
                    } catch BridgeError.corrupt { self.log("bridge: an EPUB from the phone didn't verify") }
                }
            }
            if !files.isEmpty { try await self.pushOwnDocument() }
        }
        return files
    }

    /// EPUBs this device sent whose narrator went quiet before collecting them: they go to the
    /// next best running device. Returns the ids this device should now narrate itself.
    public func retarget() async throws -> [String] {
        var mine: [String] = []
        try await guarded {
            let received = Set(self.others.flatMap(\.received))
            var changed = false
            for (i, t) in self.saved.outbox.enumerated() where t.kind == .epub && !received.contains(t.id) {
                guard let target = t.target, target != self.deviceID,
                      Date().timeIntervalSince(t.createdAt) > 20 * 60,
                      !(self.others.first { $0.deviceID == target }.map { self.isActive($0) } ?? false) else { continue }
                let next = self.chooseNarrator(sentences: 0, excluding: [target])
                if next == self.deviceID {
                    mine.append(t.id)
                    try await self.deleteChunks(t)
                    self.saved.outbox[i].target = nil
                    self.saved.outbox[i].files = []                  // nothing left to collect
                } else if let next {
                    self.saved.outbox[i].target = next
                    self.saved.outbox[i].createdAt = Date()
                } else { continue }
                changed = true
            }
            self.saved.outbox.removeAll { $0.kind == .epub && $0.files.isEmpty }
            if changed { self.save(); try await self.pushOwnDocument() }
        }
        return mine
    }

    // MARK: - Cleaning up

    /// Deletes what every recipient has collected (or what waited 14 days). Positions and
    /// markers stay; books and EPUBs never linger.
    public func collect() async throws {
        try await guarded {
            let now = Date()
            let macReceived = Set(self.others.flatMap(\.received))
            let phones = self.others.filter { self.recipients().contains($0.deviceID) }
            var keep: [Transfer] = []
            for t in self.saved.outbox {
                let expired = now.timeIntervalSince(t.createdAt) > Self.transitLifetime
                let delivered: Bool
                switch t.kind {
                case .book: delivered = !phones.isEmpty && phones.allSatisfy { $0.has.contains { $0.bookID == t.bookID && $0.revision >= (t.revision ?? 0) } }
                case .epub: delivered = macReceived.contains(t.id)
                }
                if expired || delivered {
                    try await self.deleteChunks(t)
                    if self.role == .helper, t.kind == .book, let id = t.bookID, self.saved.jobs.contains(id) {
                        self.saved.jobs.removeAll { $0 == id }
                        self.onJobDone?(id)                          // nothing stays on a helper
                    }
                } else { keep.append(t) }
            }
            if keep != self.saved.outbox {
                self.saved.outbox = keep
                self.save()
                try await self.pushOwnDocument()
            }
        }
    }

    // MARK: - Helpers

    static func chunks(_ size: Int) -> Int { max(1, (size + BridgeKeys.chunkSize - 1) / BridgeKeys.chunkSize) }

    func localBooks() -> [BookManifest] {
        let items = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
        let hidden = hidden()
        return items.filter { $0.pathExtension == BookBundle.fileExtension }.compactMap { try? BookBundle(url: $0).manifest() }
            .filter { !hidden.contains($0.id) }
    }

    /// Uploads every chunk not already on the bridge (a stopped upload resumes).
    func upload(_ t: Transfer, source: (TransferFile) -> URL) async throws {
        let present = Set(try await client.list(.transit).map(\.name))
        for f in t.files {
            let handle = try FileHandle(forReadingFrom: source(f))
            defer { try? handle.close() }
            for i in 0..<f.chunks {
                let logical = t.logical(f, chunk: i)
                let name = keys.objectName(logical)
                guard !present.contains(name) else { continue }
                try handle.seek(toOffset: UInt64(i * BridgeKeys.chunkSize))
                let plain = try handle.read(upToCount: BridgeKeys.chunkSize) ?? Data()
                try await client.put(.transit, name, try keys.seal(plain, logical: logical, padTo: BridgeKeys.chunkPadding))
            }
        }
    }

    /// Reassembles one file into a temporary file and checks its SHA-256.
    func download(_ t: Transfer, _ f: TransferFile) async throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let out = try FileHandle(forWritingTo: temp)
        var hasher = SHA256()
        do {
            for i in 0..<f.chunks {
                let logical = t.logical(f, chunk: i)
                guard let blob = try await client.get(.transit, keys.objectName(logical)).data else { throw BridgeError.corrupt }
                let plain = try keys.open(blob, logical: logical)
                hasher.update(data: plain)
                try out.write(contentsOf: plain)
            }
            try out.close()
        } catch {
            try? out.close(); try? FileManager.default.removeItem(at: temp)
            throw error
        }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == f.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: temp)
            throw BridgeError.corrupt
        }
        return temp
    }

    func deleteChunks(_ t: Transfer) async throws {
        for f in t.files { for i in 0..<f.chunks { try await client.delete(.transit, keys.objectName(t.logical(f, chunk: i))) } }
    }

    /// Skips everything while a free-tier cap is reached, and starts the pause when one is hit.
    func guarded(_ work: () async throws -> Void) async throws {
        if let until = saved.pausedUntil, until > Date() { return }
        do { try await work() }
        catch BridgeError.capReached(let cap) {
            saved.pausedUntil = Self.resume(after: cap)
            save()
            log("bridge: \(cap) cap reached, paused until \(saved.pausedUntil!)")
            throw BridgeError.capReached(cap)
        }
    }

    /// Daily caps reset at midnight UTC, monthly ones on the 1st; storage frees as phones collect.
    static func resume(after cap: String, now: Date = Date()) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        switch cap {
        case "classA", "classB":
            let start = utc.date(from: utc.dateComponents([.year, .month], from: now)) ?? now
            return utc.date(byAdding: .month, value: 1, to: start) ?? now.addingTimeInterval(86400)
        case "requests": return utc.startOfDay(for: now).addingTimeInterval(86400)
        default: return now.addingTimeInterval(3 * 3600)
        }
    }

    func save() {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSON.encoder.encode(saved).write(to: stateURL, options: .atomic)
    }
}
