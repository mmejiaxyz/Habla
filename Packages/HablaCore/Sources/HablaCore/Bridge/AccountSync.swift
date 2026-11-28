import Foundation
import CryptoKit

// The device side of the account (Docs/cloud-bridge.md): report what this device holds, do
// what the account says (upload an EPUB or audio, narrate a book), take what the others offer
// (EPUBs become books here: the text is built from them; audio is installed on matching text).

public enum DeviceKind: String, Codable, Sendable { case mac, phone }

/// How fast a device narrates and how much it has queued, so the account can give each book
/// to the device that finishes it first.
public struct NarratorStatus: Codable, Equatable, Sendable {
    public var sentencesPerSecond: Double
    public var queuedSentences: Int
    public var measured: Bool
    public init(sentencesPerSecond: Double, queuedSentences: Int, measured: Bool) {
        self.sentencesPerSecond = sentencesPerSecond; self.queuedSentences = queuedSentences; self.measured = measured
    }
}

/// Settings shared by every device of the account (latest change of each wins).
public struct AccountSettings: Codable, Equatable, Sendable {
    public var voice: String = "af_heart"
    public var voiceAt: Date = Date(timeIntervalSince1970: 0)
    public var name: String?
    public var nameAt: Date?
    public init() {}
}

/// Another device of the account, for the device list.
public struct AccountDevice: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: DeviceKind
    public var lastSeen: Date
    public var online: Bool
    public var books: Int
    /// Wi-Fi addresses a Mac serves books at (host:port).
    public var endpoints: [String]
}

/// A book of the account this device doesn't have yet (or has less audio of).
public struct OfferedBook: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var author: String
    /// Its EPUB is in the cloud now (otherwise it waits for a device that has it).
    public var epubReady: Bool
    /// Narrated chapters waiting in the cloud.
    public var audioChapters: Int
}

/// What a round changed here.
public struct SyncResult: Sendable, Equatable {
    /// Books the account gives this device to narrate.
    public var narrate: [String] = []
    /// Books that arrived or got more audio.
    public var arrived: [String] = []
    /// Books deleted on another device (delete them here).
    public var deleted: [String] = []
}

public actor AccountSync {
    public let client: BridgeClient
    let keys: BridgeKeys
    public let config: BridgeConfig
    /// This device's own id (e.g. "mac-…") and the opaque id the account knows it by.
    public let deviceID: String
    public let serverID: String
    let deviceName: String
    let kind: DeviceKind
    let progress: ProgressStore
    let markers: MarkerStore
    let library: URL
    let stateURL: URL

    var narrator: NarratorStatus?
    var endpoints: [String] = []
    /// Books being narrated here right now: no audio is installed into them meanwhile.
    var busy: Set<String> = []
    /// How much of a book is narrated here (chapters with audio, sentences still to narrate).
    var readiness: @Sendable (BookManifest, String) -> (ready: Int, left: Int) = AccountSync.defaultReadiness
    var log: @Sendable (String) -> Void = { _ in }
    var onActivity: (@Sendable (ActivityItem) -> Void)?
    var onProgress: (@Sendable (String, Double) -> Void)?

    struct Saved: Codable {
        var known: Set<String> = []
        var added: [String: Date] = [:]
        var deletions: [String: Date] = [:]
        var declined: Set<String> = []
        var requested: Set<String> = []
        var placesHash: String?
        var seen: [String: Int] = [:]
        var settings = AccountSettings()
        var sentVoiceAt: Date?
        var sentNameAt: Date?
        var devices: [AccountDevice] = []
        var offers: [OfferedBook] = []
        var narratingOn: [String: String] = [:]
        var pausedUntil: Date?
        var lastSync: Date?

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            known = try c.decodeIfPresent(Set<String>.self, forKey: .known) ?? []
            added = try c.decodeIfPresent([String: Date].self, forKey: .added) ?? [:]
            deletions = try c.decodeIfPresent([String: Date].self, forKey: .deletions) ?? [:]
            declined = try c.decodeIfPresent(Set<String>.self, forKey: .declined) ?? []
            requested = try c.decodeIfPresent(Set<String>.self, forKey: .requested) ?? []
            placesHash = try c.decodeIfPresent(String.self, forKey: .placesHash)
            seen = try c.decodeIfPresent([String: Int].self, forKey: .seen) ?? [:]
            settings = try c.decodeIfPresent(AccountSettings.self, forKey: .settings) ?? AccountSettings()
            sentVoiceAt = try c.decodeIfPresent(Date.self, forKey: .sentVoiceAt)
            sentNameAt = try c.decodeIfPresent(Date.self, forKey: .sentNameAt)
            devices = try c.decodeIfPresent([AccountDevice].self, forKey: .devices) ?? []
            offers = try c.decodeIfPresent([OfferedBook].self, forKey: .offers) ?? []
            narratingOn = try c.decodeIfPresent([String: String].self, forKey: .narratingOn) ?? [:]
            pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
            lastSync = try c.decodeIfPresent(Date.self, forKey: .lastSync)
        }
    }
    var saved: Saved
    /// What the report in flight carried (acknowledged once the account answers).
    var sending: (places: String?, voiceAt: Date?, nameAt: Date?) = (nil, nil, nil)

    public init(config: BridgeConfig, deviceID: String, deviceName: String, kind: DeviceKind,
                progress: ProgressStore, markers: MarkerStore, library: URL, stateURL: URL, session: URLSession = .shared) {
        self.config = config
        keys = BridgeKeys(libraryKey: config.libraryKey)
        serverID = keys.objectName("device/\(deviceID)")
        client = BridgeClient(baseURL: config.url, token: keys.token, device: serverID, session: session)
        self.deviceID = deviceID; self.deviceName = deviceName; self.kind = kind
        self.progress = progress; self.markers = markers; self.library = library; self.stateURL = stateURL
        saved = (try? Data(contentsOf: stateURL)).flatMap { try? JSON.decoder.decode(Saved.self, from: $0) } ?? Saved()
    }

    // MARK: - Setting up

    /// Makes a new account (needs the Worker's server key).
    public static func createAccount(at url: URL, serverKey: String, session: URLSession = .shared) async throws -> BridgeConfig {
        let key = BridgeKeys.newLibraryKey()
        let keys = BridgeKeys(libraryKey: key)
        try await BridgeClient(baseURL: url, token: keys.token, session: session).createAccount(tokenHash: keys.tokenHash, serverKey: serverKey)
        return BridgeConfig(url: url, libraryKey: key)
    }

    /// Joins an account with a one-time code another of its devices shows.
    public static func join(_ code: JoinCode, at url: URL, session: URLSession = .shared) async throws -> (config: BridgeConfig, name: String?) {
        let p = try await BridgeClient.join(code, at: url, session: session)
        return (BridgeConfig(url: url, libraryKey: p.libraryKey), p.name)
    }

    /// A fresh one-time code for a new device (15 minutes, works once).
    public func makeJoinCode() async throws -> JoinCode {
        let code = JoinCode.random()
        try await client.offer(code, payload: .init(libraryKey: config.libraryKey, name: saved.settings.name))
        return code
    }

    public func configure(readiness: (@Sendable (BookManifest, String) -> (ready: Int, left: Int))? = nil,
                          log: @escaping @Sendable (String) -> Void = { _ in }) {
        if let readiness { self.readiness = readiness }
        self.log = log
    }
    public func setActivityHandler(_ h: (@Sendable (ActivityItem) -> Void)?) { onActivity = h }
    public func setProgressHandler(_ h: (@Sendable (String, Double) -> Void)?) { onProgress = h }
    public func setNarrator(_ status: NarratorStatus?) { narrator = status }
    public func setEndpoints(_ list: [String]) { endpoints = list.sorted() }
    public func setBusy(_ ids: Set<String>) { busy = ids }

    // MARK: - What the apps read

    public var settings: AccountSettings { saved.settings }
    public var pausedUntil: Date? { saved.pausedUntil }
    public var lastSync: Date? { saved.lastSync }
    public func devices() -> [AccountDevice] { saved.devices }
    /// Which other device narrates each book (book id → its name).
    public func narratingDevices() -> [String: String] { saved.narratingOn }
    /// Books of the account not here yet (or with more audio in the cloud).
    public func offers() -> [OfferedBook] { saved.offers }
    public func isDeclined(_ id: String) -> Bool { saved.declined.contains(id) }

    /// Changed in Settings here: it becomes every device's.
    public func setVoice(_ voice: String) {
        guard voice != saved.settings.voice else { return }
        saved.settings.voice = voice; saved.settings.voiceAt = Date(); save()
    }

    public func setName(_ name: String) {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !n.isEmpty, n != saved.settings.name else { return }
        saved.settings.name = n; saved.settings.nameAt = Date(); save()
    }

    /// The user added this book here (an import): it's offered to every device, and brings it
    /// back if it was deleted before.
    public func recordAdded(_ id: String) {
        saved.added[id] = Date(); saved.deletions[id] = nil; saved.declined.remove(id)
        saved.known.remove(bookKey(id)); save()
    }

    /// The user deleted this book: it goes from every device.
    public func recordDeleted(_ id: String) {
        saved.deletions[id] = Date(); saved.added[id] = nil; saved.declined.remove(id); save()
    }

    /// An iPhone's "Remove download" (local only: nobody sends it here) or downloaded again.
    public func setDeclined(_ id: String, _ declined: Bool) {
        if declined { saved.declined.insert(id) } else { saved.declined.remove(id) }
        save()
    }

    /// Download tapped for a book whose audio isn't in the cloud any more: a holder sends it again.
    public func request(_ id: String) { saved.requested.insert(id); saved.declined.remove(id); save() }

    public func removeDevice(_ id: String) async throws {
        try await client.removeDevice(id)
        saved.devices.removeAll { $0.id == id }
        save()
    }

    // MARK: - A round

    public enum Downloads: Sendable, Equatable {
        case all
        /// Only these books (an iPhone on mobile data: what the user said yes to).
        case only(Set<String>)
        case none
        func allows(_ id: String) -> Bool {
            switch self { case .all: return true; case .only(let s): return s.contains(id); case .none: return false }
        }
    }

    /// One round with the account. `skipAudio`: books whose audio comes another way (Wi-Fi).
    @discardableResult
    public func sync(downloads: Downloads = .all, uploads: Bool = true, skipAudio: Set<String> = []) async throws -> SyncResult {
        var result = SyncResult()
        if let until = saved.pausedUntil, until > Date() { return result }
        do {
            var view = try await round(uploaded: [])
            result = apply(view)
            var changed = false
            if try await fetch(view, downloads: downloads, skipAudio: skipAudio, into: &result) { changed = true }
            var uploaded: [Uploaded] = []
            if uploads { uploaded = try await performUploads(view) }
            if changed || !uploaded.isEmpty {
                view = try await round(uploaded: uploaded)
                let again = apply(view)
                result.narrate = again.narrate
                result.deleted = Array(Set(result.deleted + again.deleted))
            }
            saved.lastSync = Date(); save()
        } catch BridgeError.capReached(let cap) {
            saved.pausedUntil = Self.resume(after: cap); save()
            log("cloud: \(cap) cap reached, paused until \(saved.pausedUntil!)")
            throw BridgeError.capReached(cap)
        }
        return result
    }

    // MARK: Wire format

    struct Holding: Codable { var key: String; var epub: Bool; var ready: Int; var left: Int }
    struct Added: Codable { var key: String; var meta: String; var sentences: Int; var narratable: Bool; var at: Int64 }
    struct Deleted: Codable { var key: String; var at: Int64 }
    struct Uploaded: Codable { var key: String; var kind: String; var names: [String]; var pack: String; var ready: Int? }
    struct Setting: Codable { var data: String; var at: Int64 }
    struct WireNarrator: Codable { var sps: Double; var queued: Int }
    struct Report: Codable {
        var kind: String; var info: String; var narrator: WireNarrator?
        var books: [Holding]; var added: [Added]; var deleted: [Deleted]; var uploaded: [Uploaded]
        var requested: [String]; var declined: [String]; var places: String?; var seen: [String: Int]
        var settings: [String: Setting]
    }
    struct View: Decodable {
        struct Device: Decodable { var id: String; var kind: String; var info: String?; var online: Bool; var lastSeen: Int64; var narrator: WireNarrator? }
        struct Pack: Decodable { var pack: String; var names: [String]; var ready: Int? }
        struct HolderState: Decodable { var epub: Bool; var ready: Int; var left: Int }
        struct Book: Decodable {
            var key: String; var meta: String?; var sentences: Int?; var narrator: String?; var deletedAt: Int64?
            var epub: Pack?; var audio: Pack?; var holders: [String: HolderState]
        }
        struct Place: Decodable { var device: String; var version: Int; var data: String }
        struct Tasks: Decodable { struct Upload: Decodable { var key: String; var kind: String }; var upload: [Upload]; var narrate: [String] }
        var devices: [Device]; var books: [Book]; var places: [Place]; var settings: [String: Setting]; var tasks: Tasks
    }

    struct DeviceInfo: Codable { var deviceID: String; var name: String; var endpoints: [String] }
    struct BookMeta: Codable { var id: String; var title: String; var author: String; var language: String }
    struct Places: Codable { var positions: [ReadingPosition]; var markers: [Marker] }
    struct EPUBPack: Codable { var file: TransferFile }
    struct AudioPack: Codable { var chapters: [AudioChapter] }
    struct AudioChapter: Codable {
        var index: Int
        /// The chapter's text fingerprint: audio goes only onto identical text.
        var text: String
        var audio: TransferFile
        var timing: TransferFile?
        var duration: TimeInterval?
        var voiceID: String?
        var model: String?
        var planVersion: Int?
        var silentSentences: Int?
    }

    // MARK: Report → view

    func round(uploaded: [Uploaded]) async throws -> View {
        let report = try buildReport(uploaded: uploaded)
        let data = try await client.sync(try JSONEncoder().encode(report))
        do { return try JSONDecoder().decode(View.self, from: data) } catch { throw BridgeError.corrupt }
    }

    func buildReport(uploaded: [Uploaded]) throws -> Report {
        let local = localBooks()
        let voice = saved.settings.voice
        var books: [Holding] = [], added: [Added] = []
        for m in local {
            let key = bookKey(m.id)
            let (ready, left) = readiness(m, voice)
            books.append(Holding(key: key, epub: hasOriginal(m.id), ready: ready, left: left))
            if !saved.known.contains(key), saved.deletions[m.id] == nil {
                let meta = try seal(BookMeta(id: m.id, title: m.title, author: m.author, language: m.language), "meta/\(key)", pad: 256)
                let sentences = m.chapters.filter { !$0.isFrontMatter }.reduce(0) { $0 + $1.sentenceCount }
                let at = saved.added[m.id] ?? m.createdAt
                added.append(Added(key: key, meta: meta, sentences: sentences,
                                   narratable: BookLanguage.hasVoice(m.language) && sentences > 0, at: Self.ms(at)))
            }
        }
        let deleted = saved.deletions.map { Deleted(key: bookKey($0.key), at: Self.ms($0.value)) }
        let places = Places(positions: progress.all.sorted { $0.bookID < $1.bookID },
                            markers: markers.all.sorted { $0.id.uuidString < $1.id.uuidString })
        let placesData = try JSON.encoder.encode(places)
        let hash = SHA256.hash(data: placesData).map { String(format: "%02x", $0) }.joined()
        sending = (hash, saved.settings.voiceAt, saved.settings.nameAt)
        var settings: [String: Setting] = [:]
        if saved.sentVoiceAt != saved.settings.voiceAt, saved.settings.voiceAt.timeIntervalSince1970 > 0 {
            settings["voice"] = Setting(data: try seal(["voice": saved.settings.voice], "settings/voice", pad: 256), at: Self.ms(saved.settings.voiceAt))
        }
        if let n = saved.settings.name, let at = saved.settings.nameAt, saved.sentNameAt != at {
            settings["name"] = Setting(data: try seal(["name": n], "settings/name", pad: 256), at: Self.ms(at))
        }
        return Report(kind: kind.rawValue,
                      info: try seal(DeviceInfo(deviceID: deviceID, name: deviceName, endpoints: endpoints), "info/\(serverID)", pad: 512),
                      narrator: narrator.map { WireNarrator(sps: $0.sentencesPerSecond, queued: $0.queuedSentences) },
                      books: books, added: added, deleted: deleted, uploaded: uploaded,
                      requested: saved.requested.map { bookKey($0) }, declined: saved.declined.map { bookKey($0) },
                      places: hash == saved.placesHash ? nil : try seal(places, "places/\(serverID)", pad: BridgeKeys.statePadding),
                      seen: saved.seen, settings: settings)
    }

    /// Takes the account's view in. Called after every report (the report it answers has gone).
    func apply(_ view: View) -> SyncResult {
        var result = SyncResult()
        // What was sent is acknowledged.
        if let h = sending.places { saved.placesHash = h }
        if let at = sending.voiceAt, at.timeIntervalSince1970 > 0 { saved.sentVoiceAt = at }
        if let at = sending.nameAt { saved.sentNameAt = at }

        if let v = view.settings["voice"], let d = try? open([String: String].self, v.data, "settings/voice"),
           let voice = d["voice"], Self.date(v.at) > saved.settings.voiceAt {
            saved.settings.voice = voice; saved.settings.voiceAt = Self.date(v.at); saved.sentVoiceAt = saved.settings.voiceAt
        }
        if let v = view.settings["name"], let d = try? open([String: String].self, v.data, "settings/name"),
           let name = d["name"], Self.date(v.at) > (saved.settings.nameAt ?? .distantPast) {
            saved.settings.name = name; saved.settings.nameAt = Self.date(v.at); saved.sentNameAt = saved.settings.nameAt
        }

        for p in view.places where p.device != serverID {
            guard let places = try? open(Places.self, p.data, "places/\(p.device)") else { continue }
            for pos in places.positions { progress.merge(pos) }
            markers.merge(places.markers)
            saved.seen[p.device] = p.version
        }

        // Books: ids, tombstones, offers, narrators.
        let local = Dictionary(localBooks().map { (bookKey($0.id), $0) }, uniquingKeysWith: { a, _ in a })
        var names: [String: String] = [:]
        for d in view.devices {
            if let info = d.info, let i = try? open(DeviceInfo.self, info, "info/\(d.id)") { names[d.id] = i.name }
        }
        saved.devices = view.devices.filter { $0.id != serverID }.compactMap { d in
            let info = d.info.flatMap { try? open(DeviceInfo.self, $0, "info/\(d.id)") }
            return AccountDevice(id: d.id, name: info?.name ?? "A device", kind: DeviceKind(rawValue: d.kind) ?? .mac,
                                 lastSeen: Self.date(d.lastSeen), online: d.online,
                                 books: view.books.filter { $0.deletedAt == nil && $0.holders[d.id] != nil }.count,
                                 endpoints: info?.endpoints ?? [])
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        saved.known = []
        var offers: [OfferedBook] = []
        saved.narratingOn = [:]
        for b in view.books {
            let meta = b.meta.flatMap { try? open(BookMeta.self, $0, "meta/\(b.key)") }.flatMap { bookKey($0.id) == b.key ? $0 : nil }
            let id = local[b.key]?.id ?? meta?.id
            if let deletedAt = b.deletedAt {
                guard let id else { continue }
                saved.deletions[id] = nil                                   // the account has it
                if let m = local[b.key], (saved.added[m.id] ?? m.createdAt) <= Self.date(deletedAt) { result.deleted.append(m.id) }
                continue
            }
            saved.known.insert(b.key)
            guard let id else { continue }
            if let n = b.narrator, n != serverID { saved.narratingOn[id] = names[n] ?? "another device" }
            if view.tasks.narrate.contains(b.key) { result.narrate.append(id) }
            guard !saved.declined.contains(id), let meta else { continue }
            let mine = local[b.key].map { readiness($0, saved.settings.voice).ready } ?? -1
            if local[b.key] == nil || (b.audio?.ready ?? 0) > mine {
                offers.append(OfferedBook(id: id, title: meta.title, author: meta.author, epubReady: b.epub != nil,
                                          audioChapters: b.audio?.ready ?? 0))
            }
        }
        saved.offers = offers
        save()
        return result
    }

    // MARK: Taking what others offer

    /// Downloads EPUBs this device lacks (and builds the books from them) and audio it has less of.
    func fetch(_ view: View, downloads: Downloads, skipAudio: Set<String>, into result: inout SyncResult) async throws -> Bool {
        var changed = false
        let fm = FileManager.default
        for b in view.books where b.deletedAt == nil {
            guard let meta = b.meta.flatMap({ try? open(BookMeta.self, $0, "meta/\(b.key)") }), bookKey(meta.id) == b.key,
                  !saved.declined.contains(meta.id), downloads.allows(meta.id) else { continue }
            let id = meta.id
            let bundleURL = BookBundle.url(for: id, in: library)
            // The EPUB: the book itself. The text is built from it here.
            if !hasOriginal(id), let e = b.epub, let pack = try? open(EPUBPack.self, e.pack, "epubpack/\(b.key)") {
                do {
                    report(.init(id: "get-" + id, bookID: id, title: meta.title, kind: .getting, state: .running(nil), route: "Cloud"))
                    let file = try await download(pack.file, logical: { "epub/\(id)/\(pack.file.sha256.lowercased())#\($0)" })
                    defer { try? fm.removeItem(at: file) }
                    guard (try? DocumentDigest.sha256Prefix(of: file)) == id else { throw BridgeError.corrupt }
                    let original = BookImporter.originalURL(for: id, in: library)
                    try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: bundleURL.appendingPathComponent(BookBundle.manifestFile).path) {
                        try? fm.removeItem(at: original)
                        try fm.copyItem(at: file, to: original)
                    } else {
                        let named = fm.temporaryDirectory.appendingPathComponent("habla-\(UUID().uuidString)", isDirectory: true)
                        try fm.createDirectory(at: named, withIntermediateDirectories: true)
                        defer { try? fm.removeItem(at: named) }
                        let src = named.appendingPathComponent(Self.safeName(meta.title) + ".epub")
                        try fm.copyItem(at: file, to: src)
                        try BookImporter().importEPUB(at: src, into: library)
                    }
                    saved.added[id] = saved.added[id] ?? .distantPast   // received: never brings back a delete
                    save()
                    result.arrived.append(id)
                    changed = true
                    report(.init(id: "get-" + id, bookID: id, title: meta.title, kind: .getting, state: .done, route: "Cloud"))
                } catch BridgeError.corrupt {
                    report(.init(id: "get-" + id, bookID: id, title: meta.title, kind: .getting,
                                 state: .failed("It didn’t arrive intact. It will be fetched again."), route: "Cloud"))
                } catch BridgeError.http(404) {
                    continue                                    // replaced meanwhile: next round
                }
            }
            // The audio, onto the text built here.
            guard let a = b.audio, !busy.contains(id), !skipAudio.contains(id),
                  let m = try? BookBundle(url: bundleURL).manifest(),
                  (a.ready ?? 0) > readiness(m, saved.settings.voice).ready,
                  let pack = try? open(AudioPack.self, a.pack, "audiopack/\(b.key)") else { continue }
            do {
                if try await installAudio(pack, into: BookBundle(url: bundleURL), title: meta.title) {
                    result.arrived.append(id)
                    saved.requested.remove(id)
                    changed = true
                }
            } catch BridgeError.http(404) { continue }
        }
        result.arrived = Array(Set(result.arrived)).sorted()
        save()
        return changed
    }

    /// Installs the chapters this copy lacks whose text matches the sender's exactly.
    func installAudio(_ pack: AudioPack, into bundle: BookBundle, title: String) async throws -> Bool {
        var m = try bundle.manifest()
        let voice = saved.settings.voice
        let wanted = pack.chapters.filter { c in
            guard let local = m.chapters.first(where: { $0.index == c.index }),
                  (try? Self.textPrint(bundle, local)) == c.text else { return false }
            let left = Set(m.chaptersToNarrate(voiceID: voice).map(\.index))
            return local.audioStatus != .ready || left.contains(c.index)
        }
        guard !wanted.isEmpty else { return false }
        let total = max(1, wanted.reduce(0) { $0 + $1.audio.size + ($1.timing?.size ?? 0) })
        var done = 0
        let fm = FileManager.default
        for c in wanted {
            for (file, path) in [(c.audio, BookBundle.audioPath(c.index))] + (c.timing.map { [($0, BookBundle.timingPath(c.index))] } ?? []) {
                let before = done
                let temp = try await download(file, logical: { "blob/\(m.id)/\(file.sha256.lowercased())#\($0)" }) { [onProgress, onActivity, id = m.id] bytes in
                    let f = Double(before + bytes) / Double(total)
                    onProgress?(id, f)
                    onActivity?(.init(id: "get-" + id, bookID: id, title: title, kind: .getting, state: .running(f), route: "Cloud"))
                }
                done += file.size
                let dest = bundle.fileURL(path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: temp) } else { try fm.moveItem(at: temp, to: dest) }
            }
            guard let i = m.chapters.firstIndex(where: { $0.index == c.index }) else { continue }
            m.chapters[i].audioFile = BookBundle.audioPath(c.index)
            m.chapters[i].timingFile = c.timing == nil ? nil : BookBundle.timingPath(c.index)
            m.chapters[i].duration = c.duration
            m.chapters[i].audioStatus = .ready
            m.chapters[i].voiceID = c.voiceID
            m.chapters[i].model = c.model
            m.chapters[i].planVersion = c.planVersion
            m.chapters[i].silentSentences = c.silentSentences
        }
        if m.voice == nil, let v = wanted.first?.voiceID { m.voice = VoiceInfo(engine: "kokoro", voiceID: v) }
        _ = try bundle.commit(m)
        report(.init(id: "get-" + m.id, bookID: m.id, title: title, kind: .getting, state: .done, route: "Cloud"))
        return true
    }

    // MARK: Sending what the account asks for

    func performUploads(_ view: View) async throws -> [Uploaded] {
        var out: [Uploaded] = []
        guard !view.tasks.upload.isEmpty else { return out }
        let local = Dictionary(localBooks().map { (bookKey($0.id), $0) }, uniquingKeysWith: { a, _ in a })
        var present = Set(try await client.list(.transit).map(\.name))
        for t in view.tasks.upload {
            guard let m = local[t.key] else { continue }
            if t.kind == "epub" {
                let url = BookImporter.originalURL(for: m.id, in: library)
                guard let file = try? Self.transferFile(url) else { continue }
                let logical = { (i: Int) in "epub/\(m.id)/\(file.sha256.lowercased())#\(i)" }
                guard try await roomFor([(file, logical)], present: present, title: m.title, id: m.id) else { continue }
                let names = try await upload(file, from: url, logical: logical, present: &present, id: m.id, title: m.title, total: file.size, offset: 0)
                out.append(Uploaded(key: t.key, kind: "epub", names: names, pack: try seal(EPUBPack(file: file), "epubpack/\(t.key)", pad: 1024), ready: nil))
            } else if t.kind == "audio" {
                let bundle = BookBundle(url: BookBundle.url(for: m.id, in: library))
                let chapters = audioChapters(m, bundle)
                guard !chapters.isEmpty else { continue }
                var files: [(TransferFile, (Int) -> String, URL)] = []
                for (c, info) in chapters {
                    files.append((c.audio, { "blob/\(m.id)/\(c.audio.sha256.lowercased())#\($0)" }, bundle.fileURL(info.audioFile!)))
                    if let tf = c.timing, let p = info.timingFile { files.append((tf, { "blob/\(m.id)/\(tf.sha256.lowercased())#\($0)" }, bundle.fileURL(p))) }
                }
                guard try await roomFor(files.map { ($0.0, $0.1) }, present: present, title: m.title, id: m.id) else { continue }
                let total = max(1, files.reduce(0) { $0 + $1.0.size })
                var names: [String] = [], offset = 0
                log("Sending “\(m.title)” to your other devices…")
                for (f, logical, url) in files {
                    names += try await upload(f, from: url, logical: logical, present: &present, id: m.id, title: m.title, total: total, offset: offset)
                    offset += f.size
                }
                report(.init(id: "send-" + m.id, bookID: m.id, title: m.title, kind: .sending, state: .done, route: "Cloud"))
                out.append(Uploaded(key: t.key, kind: "audio", names: names,
                                    pack: try seal(AudioPack(chapters: chapters.map(\.0)), "audiopack/\(t.key)", pad: 1024),
                                    ready: chapters.count))
            }
        }
        return out
    }

    /// The narrated chapters of a book, as they travel.
    func audioChapters(_ m: BookManifest, _ bundle: BookBundle) -> [(AudioChapter, ChapterInfo)] {
        let hashes = Dictionary(m.files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        func file(_ path: String?) -> TransferFile? {
            guard let path else { return nil }
            if let e = hashes[path] { return TransferFile(path: path, size: e.size, sha256: e.sha256, chunks: BridgeKeys.chunks(e.size)) }
            return try? Self.transferFile(bundle.fileURL(path), path: path)
        }
        return m.chapters.compactMap { c in
            guard c.audioStatus == .ready, let audio = file(c.audioFile), let text = try? Self.textPrint(bundle, c) else { return nil }
            return (AudioChapter(index: c.index, text: text, audio: audio, timing: file(c.timingFile), duration: c.duration,
                                 voiceID: c.voiceID ?? m.voice?.voiceID, model: c.model, planVersion: c.planVersion,
                                 silentSentences: c.silentSentences), c)
        }
    }

    /// Whether the cloud has room for what isn't there yet (otherwise it waits, said in Activity).
    func roomFor(_ files: [(TransferFile, (Int) -> String)], present: Set<String>, title: String, id: String) async throws -> Bool {
        let needed = files.reduce(0) { sum, f in
            sum + (0..<f.0.chunks).filter { !present.contains(keys.objectName(f.1($0))) }.count * min(f.0.size, BridgeKeys.chunkSize)
        }
        guard needed > 0 else { return true }
        let usage = try await client.usage()
        if usage.freeBytes > needed + needed / 10 { return true }
        report(.init(id: "send-" + id, bookID: id, title: title, kind: .sending, state: .waiting("Waiting for room on the cloud")))
        return false
    }

    // MARK: Chunks

    func upload(_ f: TransferFile, from url: URL, logical: (Int) -> String, present: inout Set<String>,
                id: String, title: String, total: Int, offset: Int) async throws -> [String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var names: [String] = []
        for i in 0..<f.chunks {
            let l = logical(i), name = keys.objectName(l)
            names.append(name)
            guard !present.contains(name) else { continue }
            try handle.seek(toOffset: UInt64(i * BridgeKeys.chunkSize))
            let plain = try handle.read(upToCount: BridgeKeys.chunkSize) ?? Data()
            try await client.put(.transit, name, try keys.seal(plain, logical: l, padTo: BridgeKeys.chunkPadding))
            present.insert(name)
            report(.init(id: "send-" + id, bookID: id, title: title, kind: .sending,
                         state: .running(Double(offset + min(f.size, (i + 1) * BridgeKeys.chunkSize)) / Double(max(1, total))), route: "Cloud"))
        }
        return names
    }

    /// Reassembles a file from its chunks and checks its SHA-256 (whole chunks of a stopped
    /// download of the same file are reused).
    func download(_ f: TransferFile, logical: (Int) -> String, progress: ((Int) -> Void)? = nil) async throws -> URL {
        let fm = FileManager.default
        let partials = fm.temporaryDirectory.appendingPathComponent("bridge-partial", isDirectory: true)
        try? fm.createDirectory(at: partials, withIntermediateDirectories: true)
        let partial = partials.appendingPathComponent(String(f.sha256.lowercased().filter(\.isHexDigit).prefix(64)) + "-\(f.size)")
        var hasher = SHA256()
        var first = 0
        if fm.fileExists(atPath: partial.path), let size = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int) {
            first = min(size / BridgeKeys.chunkSize, f.chunks)
            if first > 0, let h = try? FileHandle(forReadingFrom: partial) {
                for _ in 0..<first { if let d = try? h.read(upToCount: BridgeKeys.chunkSize) { hasher.update(data: d) } }
                try? h.close()
            }
            if let h = try? FileHandle(forWritingTo: partial) { try? h.truncate(atOffset: UInt64(first * BridgeKeys.chunkSize)); try? h.close() }
        } else {
            fm.createFile(atPath: partial.path, contents: nil)
        }
        let out = try FileHandle(forWritingTo: partial)
        try out.seekToEnd()
        do {
            for i in first..<f.chunks {
                let l = logical(i)
                guard let blob = try await client.get(.transit, keys.objectName(l)).data else { throw BridgeError.corrupt }
                let plain = try keys.open(blob, logical: l)
                hasher.update(data: plain)
                try out.write(contentsOf: plain)
                progress?(min(f.size, (i + 1) * BridgeKeys.chunkSize))
            }
            try out.close()
        } catch {
            try? out.close()
            if case BridgeError.corrupt = error { try? fm.removeItem(at: partial) }
            throw error
        }
        guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == f.sha256.lowercased() else {
            try? fm.removeItem(at: partial)
            throw BridgeError.corrupt
        }
        let ready = fm.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        try fm.moveItem(at: partial, to: ready)
        return ready
    }

    // MARK: Helpers

    func bookKey(_ id: String) -> String { keys.objectName("book/\(id)") }

    func hasOriginal(_ id: String) -> Bool { FileManager.default.fileExists(atPath: BookImporter.originalURL(for: id, in: library).path) }

    func localBooks() -> [BookManifest] {
        let items = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == BookBundle.fileExtension }.compactMap { try? BookBundle(url: $0).manifest() }
    }

    func seal<T: Encodable>(_ value: T, _ logical: String, pad: Int) throws -> String {
        try keys.seal(try JSON.encoder.encode(value), logical: logical, padTo: pad).base64EncodedString()
    }

    func open<T: Decodable>(_ type: T.Type, _ b64: String, _ logical: String) throws -> T {
        guard let data = Data(base64Encoded: b64) else { throw BridgeError.corrupt }
        return try JSON.decoder.decode(T.self, from: try keys.open(data, logical: logical))
    }

    func report(_ item: ActivityItem) { onActivity?(item) }

    /// Chapters narrated with the account voice, and sentences still to narrate.
    public static let defaultReadiness: @Sendable (BookManifest, String) -> (ready: Int, left: Int) = { m, voice in
        let left = m.chaptersToNarrate(voiceID: voice)
        let leftIDs = Set(left.map(\.index))
        let ready = m.chapters.filter { $0.audioStatus == .ready && !leftIDs.contains($0.index) }.count
        return (ready, BookLanguage.hasVoice(m.language) ? left.reduce(0) { $0 + $1.sentenceCount } : 0)
    }

    /// A chapter's text fingerprint: its title and every sentence, in order.
    static func textPrint(_ bundle: BookBundle, _ c: ChapterInfo) throws -> String {
        let text = try bundle.chapterText(c)
        var h = SHA256()
        h.update(data: Data(text.title.utf8))
        for (_, s) in text.sentences { h.update(data: Data([1])); h.update(data: Data((text.sentenceText(s.id) ?? "").utf8)) }
        return h.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func transferFile(_ url: URL, path: String = "") throws -> TransferFile {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return TransferFile(path: path, size: size, sha256: try BookBundle.sha256(of: url), chunks: BridgeKeys.chunks(size))
    }

    static func safeName(_ title: String) -> String {
        let s = title.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return s.isEmpty || s.hasPrefix(".") ? "Book" : String(s.prefix(80))
    }

    static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    /// Daily caps reset at midnight UTC, monthly ones on the 1st; storage frees as devices collect.
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

/// One file as it travels, cut into sealed chunks of `BridgeKeys.chunkSize`.
public struct TransferFile: Codable, Equatable, Sendable {
    public var path: String
    public var size: Int
    public var sha256: String
    public var chunks: Int
}

extension BridgeKeys {
    static func chunks(_ size: Int) -> Int { max(1, (size + chunkSize - 1) / chunkSize) }
}
