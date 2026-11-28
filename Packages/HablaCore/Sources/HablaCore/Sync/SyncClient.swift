import Foundation
import Network

public enum SyncError: Error, CustomStringConvertible, Equatable {
    case http(Int, String), unreachable(String), integrity(String), pairing(String)
    /// The Mac doesn't know this device (never paired, or forgotten on the Mac).
    case notPaired
    /// The Mac refused what was sent, for good (retrying won't help).
    case rejected(String)
    public var description: String {
        switch self {
        case .http(let code, let path): return "Server returned \(code) for \(path)"
        case .unreachable(let s): return "Can't reach the Mac: \(s)"
        case .integrity(let p): return "Downloaded file failed its checksum: \(p)"
        case .pairing(let m): return m
        case .notPaired: return "This iPhone isn't paired with that Mac."
        case .rejected(let m): return m
        }
    }
}

final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add(_ n: Int) -> Int { lock.withLock { value += n; return value } }
}

public struct SyncSummary: Sendable {
    public var filesDownloaded = 0
    public var bytesDownloaded = 0
    public var filesRemoved = 0
    public var upToDate: Bool { filesDownloaded == 0 && filesRemoved == 0 }
}

/// iPhone side of sync: downloads bundles (only changed files) and exchanges progress.
public struct SyncClient: Sendable {
    public let baseURL: URL
    public var accessToken: String?
    /// Sent with every request so the Mac can show which device synced.
    public var deviceID: String?
    public var deviceName: String?
    let session: URLSession

    public init(baseURL: URL, accessToken: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL; self.accessToken = accessToken; self.session = session
    }

    // MARK: Library

    public func library() async throws -> [LibraryEntry] {
        try await getJSON([LibraryEntry].self, "v1/library")
    }

    public func manifest(_ id: String) async throws -> BookManifest {
        try await getJSON(BookManifest.self, "v1/books/\(id)/manifest")
    }

    /// Brings the local copy of a book up to date. Files are verified by SHA-256 and
    /// written before the manifest, so an interrupted sync never leaves a broken book.
    /// - `verify`: also re-hash every local file (repairs silent corruption; slower).
    @discardableResult
    public func syncBook(_ id: String, into library: URL, verify: Bool = false,
                         progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) async throws -> SyncSummary {
        // The Mac may re-narrate a chapter while we download: fetch the new manifest and continue.
        var attempt = 0
        while true {
            do { return try await syncBookOnce(id, into: library, verify: verify, progress: progress) }
            catch SyncError.integrity where attempt < 3 { attempt += 1 }
            catch SyncError.http(404, _) where attempt < 3 { attempt += 1 }   // a file left the book mid-sync
        }
    }

    func syncBookOnce(_ id: String, into library: URL, verify: Bool,
                      progress: (@Sendable (_ done: Int, _ total: Int) -> Void)?) async throws -> SyncSummary {
        let remote = try await manifest(id)
        // Never let a manifest point outside this book's folder.
        guard BookBundle.isSafeRelativePath(id), !id.contains("/"),
              let bad = Optional(remote.files.first { !BookBundle.isSafeRelativePath($0.path) }), bad == nil else {
            throw SyncError.integrity("unsafe file path in the book from the Mac")
        }
        let bundle = BookBundle(url: BookBundle.url(for: id, in: library))
        let local = try? bundle.manifest()
        let localHashes = Dictionary((local?.files ?? []).map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        let fm = FileManager.default

        var summary = SyncSummary()
        let needed = remote.files.filter { f in
            let dest = bundle.fileURL(f.path)
            guard fm.fileExists(atPath: dest.path) else { return true }
            let onDisk = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? -1
            if onDisk != f.size { return true }                       // truncated / damaged
            if localHashes[f.path] == f.sha256 && !verify { return false }
            // Left over from an interrupted sync, or verifying: keep it only if the bytes match.
            return (try? BookBundle.sha256(of: dest)) != f.sha256
        }
        let total = needed.reduce(0) { $0 + $1.size }
        let counter = ByteCounter()

        // Up to 4 files at once: small text files don't wait behind large audio.
        try await withThrowingTaskGroup(of: FileEntry.self) { group in
            var queue = needed.sorted { $0.size < $1.size }[...]
            func addNext() {
                guard let file = queue.popFirst() else { return }
                group.addTask {
                    try Task.checkCancellation()
                    let encoded = file.path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
                    let temp = try await download("v1/books/\(id)/files/\(encoded)")
                    guard (try? BookBundle.sha256(of: temp)) == file.sha256 else {
                        try? FileManager.default.removeItem(at: temp)
                        throw SyncError.integrity(file.path)
                    }
                    let dest = bundle.fileURL(file.path)
                    let fm = FileManager.default
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: temp) }
                    else { try fm.moveItem(at: temp, to: dest) }
                    return file
                }
            }
            for _ in 0..<4 { addNext() }
            while let file = try await group.next() {
                summary.filesDownloaded += 1
                summary.bytesDownloaded += file.size
                progress?(counter.add(file.size), total)
                addNext()
            }
        }

        // Remove files the Mac no longer has (e.g. after a voice change).
        let keep = Set(remote.files.map(\.path))
        for old in local?.files ?? [] where !keep.contains(old.path) {
            try? fm.removeItem(at: bundle.fileURL(old.path))
            summary.filesRemoved += 1
        }

        if local != remote || !summary.upToDate {
            try bundle.write(remote, to: BookBundle.manifestFile, pretty: true)
        }
        return summary
    }

    // MARK: Progress

    /// Sends local positions and adopts any newer ones from the Mac.
    /// Sends this device's pending changes, then takes the Mac's positions for everything else.
    /// The Mac decides (latest wins, with its own clock), so devices converge even when their
    /// clocks disagree. `since` is kept for older callers and ignored.
    public func syncProgress(_ store: ProgressStore, since: Date? = nil) async throws {
        for (local, change) in store.pending {
            let winner = try await sendJSON(ReadingPosition.self, "v1/progress", method: "PUT", body: local)
            store.acknowledge(winner, change: change)
        }
        for remote in try await getJSON([ReadingPosition].self, "v1/progress") { store.adopt(remote) }
    }

    /// Exchanges bookmarks and underlines with the Mac (both sides end up with the merge).
    public func syncMarkers(_ store: MarkerStore) async throws {
        store.merge(try await sendJSON([Marker].self, "v1/markers", method: "PUT", body: store.all))
    }

    // MARK: Pairing

    /// The Mac's public hello: name and library id (no pairing needed).
    public func hello() async throws -> ServerHello {
        try await getJSON(ServerHello.self, "v1")
    }

    /// The hello with the Mac's proof that it holds the account key (bound to `nonce`).
    public func hello(nonce: String) async throws -> ServerHello {
        var r = request("v1")
        r.setValue(nonce, forHTTPHeaderField: "X-Habla-Nonce")
        let (data, response) = try await perform(r)
        try check(response, "v1")
        return try JSON.decoder.decode(ServerHello.self, from: data)
    }

    /// Pairs with the code shown on the Mac. `fingerprint`: the certificate this session saw
    /// (from the QR code, or recorded by `PinnedTrust` on first contact).
    public func pair(code: String, fingerprint: String, deviceID: String, deviceName: String) async throws -> PairResponse {
        let body = PairRequest(deviceID: deviceID, deviceName: deviceName,
                               proof: Pairing.proof(code: code, fingerprint: fingerprint, deviceID: deviceID))
        do { return try await sendJSON(PairResponse.self, "v1/pair", method: "POST", body: body) }
        catch SyncError.http(403, _) { throw SyncError.pairing("That code didn't work. Check it on your Mac (codes last 10 minutes).") }
        catch SyncError.http(404, _) { throw SyncError.pairing("This Mac doesn't support pairing. Update Habla on your Mac.") }
    }

    /// Sends an EPUB to the Mac, which imports and narrates it. Returns the book id.
    @discardableResult
    public func sendBook(_ epub: URL, filename: String? = nil) async throws -> String {
        let data = try Data(contentsOf: epub)
        let digest = BookBundle.sha256(of: data)
        let id = String(digest.prefix(16))
        var r = request("v1/inbox/\(id)", method: "PUT")
        r.timeoutInterval = 120
        r.setValue("application/epub+zip", forHTTPHeaderField: "Content-Type")
        r.setValue(digest, forHTTPHeaderField: "X-Habla-SHA256")
        let name = filename ?? epub.lastPathComponent
        r.setValue(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "book.epub", forHTTPHeaderField: "X-Habla-Filename")
        let response: URLResponse
        do { (_, response) = try await session.upload(for: r, from: data) }
        catch { throw SyncError.unreachable(error.localizedDescription) }
        if (response as? HTTPURLResponse)?.statusCode == 415 { throw SyncError.rejected("Your Mac couldn't open this file as an EPUB.") }
        try check(response, "v1/inbox/\(id)")
        return id
    }

    public func push(_ position: ReadingPosition) async throws -> ReadingPosition {
        try await sendJSON(ReadingPosition.self, "v1/progress", method: "PUT", body: position)
    }

    // MARK: HTTP

    func request(_ path: String, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method
        r.timeoutInterval = 30
        if let accessToken { r.setValue(accessToken, forHTTPHeaderField: SyncProtocol.tokenHeader) }
        if let deviceID { r.setValue(deviceID, forHTTPHeaderField: "X-Habla-Device") }
        if let deviceName {
            r.setValue(deviceName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "Device", forHTTPHeaderField: "X-Habla-Device-Name")
        }
        return r
    }

    func getJSON<T: Decodable>(_ type: T.Type, _ path: String) async throws -> T {
        let (data, response) = try await perform(request(path))
        try check(response, path)
        return try JSON.decoder.decode(T.self, from: data)
    }

    func sendJSON<T: Decodable, B: Encodable>(_ type: T.Type, _ path: String, method: String, body: B) async throws -> T {
        var r = request(path, method: method)
        r.httpBody = try JSON.encoder.encode(body)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await perform(r)
        try check(response, path)
        return try JSON.decoder.decode(T.self, from: data)
    }

    func download(_ path: String) async throws -> URL {
        let (temp, response): (URL, URLResponse)
        do { (temp, response) = try await session.download(for: request(path)) }
        catch { throw SyncError.unreachable(error.localizedDescription) }
        try check(response, path)
        // URLSession deletes its temp file when this returns; move it somewhere we own.
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: temp, to: owned)
        return owned
    }

    func perform(_ r: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: r) }
        catch { throw SyncError.unreachable(error.localizedDescription) }
    }

    func check(_ response: URLResponse, _ path: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw SyncError.notPaired }
        guard (200..<300).contains(http.statusCode) else { throw SyncError.http(http.statusCode, path) }
    }
}

// MARK: - Bonjour discovery

/// Finds Habla Macs on the local network and resolves them to `http://ip:port` URLs.
/// iOS needs `NSLocalNetworkUsageDescription` and `NSBonjourServices = [_habla._tcp]` in Info.plist.
public final class ServiceBrowser: @unchecked Sendable {
    public struct Service: Hashable, Sendable {
        public var name: String
        public var url: URL
        /// The library id from Bonjour TXT (`id`); nil for old servers / `habla serve`.
        public var libraryID: String?
        /// The account tag from Bonjour TXT (`acct`): the Mac belongs to the account with this tag.
        public var account: String?
        public init(name: String, url: URL, libraryID: String? = nil, account: String? = nil) {
            self.name = name; self.url = url; self.libraryID = libraryID; self.account = account
        }
    }

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "habla.browser")
    private var resolving: [String: NWConnection] = [:]
    public var onChange: (@Sendable ([Service]) -> Void)?
    private var services: [String: Service] = [:]
    private var txt: [String: (id: String?, tls: Bool, acct: String?)] = [:]

    public init() {}

    public func start() {
        let params = NWParameters.tcp
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: SyncProtocol.bonjourType, domain: "local."), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var names = Set<String>()
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint else { continue }
                names.insert(name)
                if case let .bonjour(record) = r.metadata {
                    let info = (id: record["id"], tls: record["tls"] == "1", acct: record["acct"])
                    if let old = self.txt[name], old.id != info.id || old.tls != info.tls || old.acct != info.acct { self.services[name] = nil }
                    self.txt[name] = info
                }
            }
            self.services = self.services.filter { names.contains($0.key) }
            self.txt = self.txt.filter { names.contains($0.key) }
            for r in results { self.resolve(r.endpoint) }
            self.onChange?(Array(self.services.values))
        }
        b.start(queue: queue)
        browser = b
    }

    public func stop() {
        browser?.cancel(); browser = nil
        resolving.values.forEach { $0.cancel() }; resolving = [:]
    }

    /// Connects briefly to learn the service's IPv4 address and port.
    private func resolve(_ endpoint: NWEndpoint) {
        guard case let .service(name, _, _, _) = endpoint, services[name] == nil, resolving[name] == nil else { return }
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let conn = NWConnection(to: endpoint, using: params)
        resolving[name] = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                    var h = "\(host)"
                    if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                    let info = self.txt[name]
                    if let url = URL(string: "\(info?.tls == true ? "https" : "http")://\(h):\(port.rawValue)") {
                        self.services[name] = Service(name: name, url: url, libraryID: info?.id, account: info?.acct)
                        self.onChange?(Array(self.services.values))
                    }
                }
                conn.cancel()
                self.resolving[name] = nil
            case .failed, .cancelled:
                self.resolving[name] = nil
            default: break
            }
        }
        conn.start(queue: queue)
    }
}
