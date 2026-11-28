import Foundation
import Network

/// Serves a folder of `.habla` bundles + reading progress over the local network
/// and advertises itself with Bonjour. Runs inside the Mac app.
public final class LibraryServer: @unchecked Sendable {
    public let library: URL
    public let progress: ProgressStore
    public var accessToken: String?
    public var serviceName: String
    /// MD5 of the KOReader sync password set on the e-reader (KOSync's `x-auth-key`); nil = open on the LAN.
    public var koreaderKeyMD5: String?
    /// The secret in the OPDS catalog's address (`opdsKey(password:)`); nil = no catalog.
    public var opdsKey: String?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "habla.server")
    public private(set) var port: UInt16?
    public var onEvent: (@Sendable (String) -> Void)?
    /// Called (on the server queue) with an EPUB the iPhone sent, saved in `inbox`.
    public var onInbox: (@Sendable (URL) -> Void)?
    /// Where books sent from the iPhone land before they're imported.
    public var inbox: URL { library.deletingLastPathComponent().appendingPathComponent("Inbox", isDirectory: true) }
    /// Pairing (Habla Studio). With a registry, every `/v1` request except the hello and the
    /// pairing call must carry a paired device's token. Without one (CLI `habla serve`) the
    /// server is open, or uses `accessToken`.
    public var registry: DeviceRegistry?
    public var pairing: PairingWindow?
    /// Random, stable id of this library (Bonjour TXT `id`): lets iPhones tell Macs apart.
    public var libraryID: String?
    /// TLS identity: when set, the server speaks HTTPS only.
    public var tlsIdentity: SecIdentity?
    public var tlsFingerprint: String?
    /// KOReader / OPDS routes for e-readers (plain HTTP devices). Off unless the Xteink feature is on.
    public var allowEReaders = false
    /// An e-reader sent a reading position (book id): the Mac passes it on to the account.
    public var onEReaderPosition: (@Sendable (String) -> Void)?
    /// A paired device made a request.
    public var onDevice: (@Sendable (PairedDevice) -> Void)?
    /// Bookmarks and underlines, exchanged with paired devices.
    public var markers: MarkerStore?
    /// The cloud bridge settings handed to paired phones (only over this pinned, paired link).
    public var bridgeConfig: (@Sendable () -> BridgeConfig?)?
    /// Books narrated here for someone else's library: never listed, served or synced to this
    /// Mac's own devices (they don't exist as far as the server is concerned).
    public var isHidden: (@Sendable (String) -> Bool)?
    /// The account (one library on every device): its devices get in with the account's Wi-Fi
    /// token, and the hello proves to them that this Mac holds the account key. Set before
    /// `start` (the Bonjour record carries the account tag); restart the server when it changes.
    public let account = Locked<BridgeKeys?>(nil)
    /// A Mac without an account: an iPhone that scanned its join QR code hands one over.
    public var onJoin: (@Sendable (BridgeConfig, String?) -> Void)?
    /// Largest EPUB accepted from the iPhone.
    static let maxUpload = 200 * 1024 * 1024

    public init(library: URL, progress: ProgressStore, serviceName: String = "Habla", accessToken: String? = nil) {
        self.library = library
        self.progress = progress
        self.serviceName = serviceName
        self.accessToken = accessToken
    }

    /// Starts listening on the preferred port; while it's taken (often a previous copy still
    /// quitting) it retries for a few seconds, then takes any free port. iPhones find the Mac by
    /// Bonjour name and library id, so a different port still works. Returns the bound port.
    @discardableResult
    public func start(port preferred: UInt16 = SyncProtocol.defaultPort, advertise: Bool = true,
                      retries: Int = 8) async throws -> UInt16 {
        var attempt = 0
        while true {
            do { return try await listen(on: preferred, advertise: advertise) }
            catch let NWError.posix(code) where code == .EADDRINUSE {
                attempt += 1
                if attempt > retries { return try await listen(on: 0, advertise: advertise) }
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }

    private func listen(on port: UInt16, advertise: Bool) async throws -> UInt16 {
        let params: NWParameters
        if let id = tlsIdentity, let secID = sec_identity_create(id) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secID)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: tls)
        } else {
            params = NWParameters.tcp
        }
        params.allowLocalEndpointReuse = true
        let listener = port == 0 ? try NWListener(using: params)
                                 : try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        if advertise {
            var txt = NWTXTRecord()
            txt["v"] = "2"
            if let libraryID { txt["id"] = libraryID }
            if tlsIdentity != nil { txt["tls"] = "1" }
            if let keys = account.value { txt["acct"] = keys.accountTag }
            listener.service = NWListener.Service(name: serviceName, type: SyncProtocol.bonjourType, domain: nil, txtRecord: txt)
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }

        return try await withCheckedThrowingContinuation { cont in
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard once.claim() else { return }
                    self?.listener = listener
                    let p = listener.port?.rawValue ?? port
                    self?.port = p
                    cont.resume(returning: p)
                case .failed(let e), .waiting(let e):
                    guard once.claim() else { return }
                    listener.cancel()
                    cont.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connections

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        let id = ObjectIdentifier(conn)
        receiveRequest(conn, buffer: Data())
        // Drop clients that connect and never finish their request (uploads get longer).
        // Responses are never cut: a big chapter on slow Wi-Fi takes as long as it takes.
        queue.asyncAfter(deadline: .now() + 120) { [weak self, weak conn] in
            guard let self, let conn else { return }
            if !self.answered.contains(id), conn.state != .cancelled { conn.cancel() }
            self.answered.remove(id)
        }
    }

    /// Connections whose request arrived (touched only on `queue`).
    private var answered = Set<ObjectIdentifier>()

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil || (done && buf.isEmpty) { conn.cancel(); return }
            guard let request = HTTPRequest.parse(buf) else {
                if buf.count > Self.maxUpload + 64 * 1024 || done { self.send(conn, .text(400, "Bad request")) }
                else { self.receiveRequest(conn, buffer: buf) }
                return
            }
            self.answered.insert(ObjectIdentifier(conn))
            self.send(conn, self.route(request))
        }
    }

    // MARK: - Pairing

    func pair(_ r: HTTPRequest) -> HTTPResponse {
        guard let registry, let pairing, let libraryID else { return .text(404, "Not found") }
        guard let req = try? JSON.decoder.decode(PairRequest.self, from: r.body),
              !req.deviceID.isEmpty, req.deviceID.count <= 64 else { return .text(400, "Bad request") }
        // The proof covers the certificate this server really has: a relay can't reuse it.
        guard pairing.verify(proof: req.proof, fingerprint: tlsFingerprint ?? "", deviceID: req.deviceID) else {
            return .text(403, "Wrong or expired code")
        }
        let token = registry.register(id: req.deviceID, name: req.deviceName)
        onEvent?("PAIRED \(req.deviceName)")
        return .json(PairResponse(token: token, libraryID: libraryID, name: serviceName))
    }

    /// Takes the account an iPhone hands over: only while this Mac has none, only with the
    /// one-time code from its QR code, bound to this server's certificate.
    func join(_ r: HTTPRequest) -> HTTPResponse {
        guard account.value == nil, let pairing, let onJoin else { return .text(409, "This Mac already has an account") }
        guard let req = try? JSON.decoder.decode(JoinRequest.self, from: r.body),
              !req.deviceID.isEmpty, req.deviceID.count <= 64 else { return .text(400, "Bad request") }
        guard pairing.verify(proof: req.proof, fingerprint: tlsFingerprint ?? "", deviceID: req.deviceID) else {
            return .text(403, "Wrong or expired code")
        }
        guard let (config, name) = AccountCode.parse(req.account) else { return .text(400, "Bad account") }
        onJoin(config, name)
        onEvent?("JOINED from \(req.deviceName)")
        return .json(["status": "joined"])
    }

    // MARK: - Books sent from the iPhone

    /// `PUT /v1/inbox/<book id>` with the EPUB as body, `X-Habla-SHA256` (full hex digest) and
    /// `X-Habla-Filename` (percent-encoded). Idempotent: a book already here just answers 200.
    func receiveInbox(_ r: HTTPRequest, id: String) -> HTTPResponse {
        guard id.count == 16, id.allSatisfy({ $0.isHexDigit }) else { return .text(400, "Bad book id") }
        if manifest(id) != nil { return .json(["id": id, "status": "exists"]) }
        guard !r.body.isEmpty, r.body.count <= Self.maxUpload else { return .text(413, "Too large") }
        let digest = BookBundle.sha256(of: r.body)
        guard digest.lowercased() == (r.headers["x-habla-sha256"] ?? "").lowercased(), digest.hasPrefix(id) else {
            return .text(422, "Checksum mismatch")
        }
        // An EPUB is a ZIP: refuse anything else now, so the iPhone keeps its copy and can say why.
        guard r.body.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { return .text(415, "Not an EPUB") }
        var name = (r.headers["x-habla-filename"]?.removingPercentEncoding ?? "\(id).epub")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.hasPrefix(".") || name.isEmpty { name = "\(id).epub" }
        if !name.lowercased().hasSuffix(".epub") { name += ".epub" }
        let folder = inbox.appendingPathComponent(id, isDirectory: true)
        let file = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try r.body.write(to: file, options: .atomic)
        } catch { return .text(500, "Couldn't save the book") }
        onInbox?(file)
        return .json(["id": id, "status": "received"], status: 201)
    }

    // MARK: - Routing

    func route(_ r: HTTPRequest) -> HTTPResponse {
        let parts = r.path.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        onEvent?("\(r.method) \(r.path)")

        // E-readers (KOReader / CrossPoint on the Xteink) speak their own protocols and auth.
        if allowEReaders {
            if parts.first == "users" || parts.first == "syncs" { return koreaderRoute(r, parts) }
            if parts.first == "opds" { return opdsRoute(r, parts) }
        }

        // Public: who this is (to tell Macs apart) and the pairing call itself.
        if parts == ["v1"], r.method == "GET" {
            var hello = ServerHello(name: serviceName, version: String(SyncProtocol.version), libraryID: libraryID,
                                    pairing: registry != nil, inbox: "1")
            if let keys = account.value, let fp = tlsFingerprint, let nonce = r.headers["x-habla-nonce"], (16...128).contains(nonce.count) {
                hello.accountProof = keys.lanProof(fingerprint: fp, nonce: nonce)
            }
            return .json(hello)
        }
        if parts == ["v1", "pair"], r.method == "POST" { return pair(r) }
        if parts == ["v1", "join"], r.method == "POST" { return join(r) }

        let token = r.headers[SyncProtocol.tokenHeader.lowercased()]
        if let keys = account.value, let token, Self.constantTimeEqual(token, keys.lanToken) {
            // One of the account's devices.
            let id = String((r.headers["x-habla-device"] ?? "device").prefix(64))
            let name = String((r.headers["x-habla-device-name"]?.removingPercentEncoding ?? "Device").prefix(60))
            onDevice?(PairedDevice(id: id, name: name, tokenHash: "", pairedAt: Date(), lastSeen: Date()))
        } else if let registry {
            guard let device = registry.device(forToken: token) else { return .text(401, "Not paired") }
            onDevice?(device)
        } else if let accessToken, token != accessToken {
            return .text(401, "Unauthorized")
        }

        switch (r.method, parts.first, parts.count) {
        case ("GET", "v1", 2) where parts[1] == "library":
            return .json(manifests().map(LibraryEntry.init(manifest:)))

        case ("GET", "v1", 4) where parts[1] == "books" && parts[3] == "manifest":
            guard let m = manifest(parts[2]) else { return .text(404, "No such book") }
            return .json(m)

        case ("GET", "v1", _) where parts.count >= 5 && parts[1] == "books" && parts[3] == "files":
            let id = parts[2], path = parts[4...].joined(separator: "/")
            // Only files listed in the manifest are served: no path tricks possible.
            guard let m = manifest(id), m.files.contains(where: { $0.path == path }) else {
                return .text(404, "No such file")
            }
            return .file(BookBundle(url: BookBundle.url(for: id, in: library)).fileURL(path))

        case ("GET", "v1", 2) where parts[1] == "progress":
            let ids = Set(manifests().map(\.id))
            return .json(progress.all.filter { ids.contains($0.bookID) })

        case ("PUT", "v1", 2) where parts[1] == "progress":
            guard var p = try? JSON.decoder.decode(ReadingPosition.self, from: r.body) else {
                return .text(400, "Bad position")
            }
            guard manifest(p.bookID) != nil else { return .json(p) }   // unknown book: acknowledge, don't store
            // A device clock running ahead must not win forever.
            if p.updatedAt > Date().addingTimeInterval(60) { p.updatedAt = Date() }
            return .json(progress.merge(p))

        case ("GET", "v1", 2) where parts[1] == "markers":
            return .json(markers?.all ?? [])

        case ("PUT", "v1", 2) where parts[1] == "markers":
            guard let markers, let incoming = try? JSON.decoder.decode([Marker].self, from: r.body) else { return .text(400, "Bad markers") }
            markers.merge(incoming)
            return .json(markers.all)

        case ("GET", "v1", 2) where parts[1] == "bridge":
            guard registry != nil, let config = bridgeConfig?() else { return .text(404, "No cloud bridge") }
            return .json(config)

        case ("PUT", "v1", 3) where parts[1] == "inbox":
            return receiveInbox(r, id: parts[2])

        default:
            return .text(404, "Not found")
        }
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The books this library shows its devices (hidden guest books left out).
    public func manifests() -> [BookManifest] {
        let hidden = isHidden
        return allManifests().filter { !(hidden?($0.id) ?? false) }
    }

    /// Every bundle in the folder, guest books included: for the Mac app itself only.
    public func allManifests() -> [BookManifest] {
        let items = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == BookBundle.fileExtension }
            .compactMap { try? BookBundle(url: $0).manifest() }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func manifest(_ id: String) -> BookManifest? {
        guard id.allSatisfy({ $0.isLetter || $0.isNumber }), !(isHidden?(id) ?? false) else { return nil }
        return try? BookBundle(url: BookBundle.url(for: id, in: library)).manifest()
    }

    // MARK: - Sending

    private func send(_ conn: NWConnection, _ response: HTTPResponse) {
        switch response.body {
        case .data(let d):
            conn.send(content: response.head(length: d.count) + d, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { [weak self] _ in self?.finish(conn) })
        case .file(let url):
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let size = try? handle.seekToEnd() else {
                send(conn, .text(404, "Missing file")); return
            }
            try? handle.seek(toOffset: 0)
            conn.send(content: response.head(length: Int(size)), completion: .contentProcessed { _ in })
            streamFile(handle, to: conn)
        }
    }

    /// Ends a response without cutting it short: the last bytes (and TLS close) have been
    /// handed over, so wait for the client to hang up before releasing the connection.
    /// Closing right away can reset the connection while data is still in flight
    /// ("The network connection was lost" on the iPhone).
    private func finish(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, done, error in
            if done || error != nil { conn.cancel() } else { self?.finish(conn) }
        }
        queue.asyncAfter(deadline: .now() + 30) { [weak conn] in
            if let conn, conn.state != .cancelled { conn.cancel() }
        }
    }

    private func streamFile(_ handle: FileHandle, to conn: NWConnection) {
        let chunk = (try? handle.read(upToCount: 256 * 1024)) ?? nil
        guard let chunk, !chunk.isEmpty else {
            try? handle.close()
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { [weak self] _ in self?.finish(conn) })
            return
        }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil { try? handle.close(); conn.cancel(); return }
            self?.streamFile(handle, to: conn)
        })
    }
}

// MARK: - Minimal HTTP/1.1

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    /// Returns nil until the full request (headers + Content-Length body) has arrived.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        let path0 = requestLine.count > 1 ? String(requestLine[1]) : ""
        let limit = path0.hasPrefix("/v1/inbox/") ? LibraryServer.maxUpload : 8 * 1024 * 1024
        // Malformed or oversized: answer with an empty request (routes reject it), never crash.
        guard length >= 0, length <= limit else {
            return HTTPRequest(method: "BAD", path: "/", headers: headers, body: Data())
        }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        let path = String(requestLine[1]).components(separatedBy: "?")[0]
        return HTTPRequest(method: String(requestLine[0]), path: path, headers: headers,
                           body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }
}

struct HTTPResponse {
    enum Body { case data(Data), file(URL) }
    var status: Int
    var contentType: String
    var body: Body
    var headers: [String: String] = [:]

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json",
                     body: .data((try? JSON.encoder.encode(value)) ?? Data("null".utf8)))
    }
    static func rawJSON(_ data: Data) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: "application/json", body: .data(data))
    }
    static func text(_ status: Int, _ s: String) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: .data(Data(s.utf8)))
    }
    static func file(_ url: URL) -> HTTPResponse {
        let type: String
        switch url.pathExtension {
        case "m4a": type = "audio/mp4"
        case "json": type = "application/json"
        case "jpg": type = "image/jpeg"
        default: type = "application/octet-stream"
        }
        return HTTPResponse(status: 200, contentType: type, body: .file(url))
    }

    func head(length: Int) -> Data {
        let reason = [200: "OK", 201: "Created", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found"][status] ?? "Error"
        let extra = headers.map { "\($0.key): \($0.value)\r\n" }.sorted().joined()
        // Always Content-Length: CrossPoint's HTTP client hangs on bodies without it.
        return Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(length)\r\n\(extra)Connection: close\r\n\r\n".utf8)
    }
}

/// Guards a continuation so it resumes exactly once.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
