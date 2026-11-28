import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Talks to an Xteink running stock CrossPoint firmware while it is in *File Transfer*
/// mode — no plugin, no install on either side. Protocol taken from the firmware source
/// (crosspoint-reader, MIT): HTTP on port 80 plus a UDP "hello" discovery on port 8134.
public struct CrossPointDevice: Sendable, Hashable {
    public var name: String
    public var host: String          // IPv4 address or "crosspoint.local"
    public var port: Int = 80

    public init(name: String, host: String, port: Int = 80) {
        self.name = name; self.host = host; self.port = port
    }

    public var baseURL: URL { URL(string: "http://\(host):\(port)")! }

    public struct Status: Decodable, Sendable {
        public var version: String
        public var device: String?
        public var ip: String?
        public var mode: String?
    }

    public struct File: Decodable, Sendable, Hashable {
        public var name: String
        public var size: Int
        public var isDirectory: Bool
        public var isEpub: Bool?
    }

    // MARK: Discovery

    /// Broadcasts CrossPoint's discovery "hello" and collects replies
    /// (`crosspoint (on <hostname>);<wsPort>`), then falls back to `crosspoint.local`.
    public static func discover(timeout: TimeInterval = 1.5,
                                targets: [String] = ["255.255.255.255"],
                                discoveryPort: UInt16 = 8134, httpPort: Int = 80) async -> [CrossPointDevice] {
        var found = await Task.detached { udpHello(targets: targets, port: discoveryPort, timeout: timeout) }.value
            .map { CrossPointDevice(name: $0.name, host: $0.ip, port: httpPort) }
        if found.isEmpty {
            let local = CrossPointDevice(name: "crosspoint", host: "crosspoint.local", port: httpPort)
            if (try? await local.status(timeout: 2)) != nil { found.append(local) }
        }
        return found
    }

    static func udpHello(targets: [String], port: UInt16, timeout: TimeInterval) -> [(name: String, ip: String)] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        for target in targets {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, target, &addr.sin_addr)
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, "hello", 5, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var out: [(String, String)] = []
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 128)
        while Date() < deadline {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            let msg = String(decoding: buf[0..<n], as: UTF8.self)
            guard msg.hasPrefix("crosspoint") else { continue }
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipBuf)
            let name = msg.components(separatedBy: ";")[0]
                .replacingOccurrences(of: "crosspoint (on ", with: "").replacingOccurrences(of: ")", with: "")
            if !out.contains(where: { $0.1 == ip }) { out.append((name, ip)) }
        }
        return out
    }

    // MARK: API

    public func status(timeout: TimeInterval = 5) async throws -> Status {
        var r = URLRequest(url: baseURL.appendingPathComponent("api/status"))
        r.timeoutInterval = timeout
        return try JSONDecoder().decode(Status.self, from: try await send(r))
    }

    public func files(in path: String) async throws -> [File] {
        var c = URLComponents(url: baseURL.appendingPathComponent("api/files"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "path", value: path)]
        return try JSONDecoder().decode([File].self, from: try await send(URLRequest(url: c.url!)))
    }

    public func makeFolder(_ name: String, in parent: String = "/") async throws {
        try await sendForm("mkdir", ["name": name, "path": parent])
    }

    public func delete(_ path: String) async throws {
        try await sendForm("delete", ["path": path])
    }

    /// Uploads a file into `folder`. With `overwrite`, newer firmware writes `<name>.part` and swaps it in
    /// only when complete (the old copy survives a failed upload); older firmware answers
    /// "File already exists", in which case we delete and upload again.
    public func upload(_ file: URL, as fileName: String, to folder: String, overwrite: Bool = false) async throws {
        do {
            try await uploadOnce(file, as: fileName, to: folder, overwrite: overwrite)
        } catch SyncError.http(400, let detail) where overwrite && detail.contains("File already exists") {
            try await delete(folder == "/" ? "/\(fileName)" : "\(folder)/\(fileName)")
            try await uploadOnce(file, as: fileName, to: folder, overwrite: false)
        }
    }

    func uploadOnce(_ file: URL, as fileName: String, to folder: String, overwrite: Bool) async throws {
        var c = URLComponents(url: baseURL.appendingPathComponent("upload"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "path", value: folder)] + (overwrite ? [URLQueryItem(name: "overwrite", value: "1")] : [])
        let boundary = "habla-\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: application/epub+zip\r\n\r\n".utf8)
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var r = URLRequest(url: c.url!)
        r.httpMethod = "POST"
        r.timeoutInterval = 300
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        _ = try await send(r)
    }

    /// Writes settings by key (same keys as the device's web settings page).
    public func setSettings(_ values: [String: Any]) async throws {
        var r = URLRequest(url: baseURL.appendingPathComponent("api/settings"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: values)
        _ = try await send(r)
    }

    public struct OPDSServer: Decodable, Sendable { public var index: Int?; public var name: String; public var url: String }

    /// Updates the entry at `index` (firmware: POST /api/opds with "index").
    public func updateOPDSServer(index: Int, name: String, url: String) async throws {
        var r = URLRequest(url: baseURL.appendingPathComponent("api/opds"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["index": index, "name": name, "url": url])
        _ = try await send(r)
    }

    public func opdsServers() async throws -> [OPDSServer] {
        try JSONDecoder().decode([OPDSServer].self, from: try await send(URLRequest(url: baseURL.appendingPathComponent("api/opds"))))
    }

    public func addOPDSServer(name: String, url: String) async throws {
        var r = URLRequest(url: baseURL.appendingPathComponent("api/opds"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "url": url])
        _ = try await send(r)
    }

    // MARK: HTTP

    @discardableResult
    func sendForm(_ path: String, _ fields: [String: String]) async throws -> Data {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        r.httpBody = Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return try await send(r)
    }

    func send(_ r: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: r) }
        catch { throw SyncError.unreachable("\(name) (\(host)): \(error.localizedDescription)") }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SyncError.http(http.statusCode, "\(r.url?.path ?? "") — \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return data
    }
}

/// One-call setup and book delivery for an Xteink, used by Habla Studio.
public struct XteinkSync {
    public var device: CrossPointDevice
    public var folder = "Habla"

    public static let catalogName = "Habla (Mac)"

    public init(device: CrossPointDevice) { self.device = device }

    /// Points the device's built-in KOReader sync at this Mac (sync on sleep, smart sync,
    /// whole-file matching) and adds the Mac's OPDS catalog. Safe to repeat (e.g. when the
    /// Mac's address changes).
    public func configure(macBaseURL: URL, username: String, password: String) async throws {
        try await device.setSettings([
            "koServerUrl": macBaseURL.absoluteString,
            "koServerType": 1,     // KoSync (not CrossPoint's cloud)
            "koMatchMethod": 1,    // Binary: Habla sends the original file untouched
            "koUsername": username,
            "koPassword": password,
            "koSendMetadata": 1,
            "koSyncBehavior": 1,   // Smart sync (no prompt every time)
            "koSyncOnSleep": 1,    // push position whenever the device sleeps
        ])
        // The catalog is a convenience: never let it block setup. The device keeps at most
        // 8 servers, so reuse (update) our entry when the Mac's address changes.
        let opds = macBaseURL.appendingPathComponent("opds").appendingPathComponent(LibraryServer.opdsKey(password: password)).absoluteString
        if let servers = try? await device.opdsServers(), !servers.contains(where: { $0.url == opds }) {
            if let mine = servers.first(where: { $0.name == Self.catalogName }), let i = mine.index {
                try? await device.updateOPDSServer(index: i, name: Self.catalogName, url: opds)
            } else {
                try? await device.addOPDSServer(name: Self.catalogName, url: opds)
            }
        }
    }

    public struct PushResult: Sendable {
        public var sent: [String] = []
        public var alreadyThere: [String] = []
        public var failed: [(title: String, reason: String)] = []
    }

    /// Takes books deleted from the account off the device: only Habla's own copies in `/Habla`
    /// (named "<title>-<id prefix>.epub"), never the user's other files. Returns the ids done.
    public func removeBooks(_ ids: Set<String>) async throws -> Set<String> {
        let dir = "/\(folder)"
        let root = try await device.files(in: "/")
        guard root.contains(where: { $0.isDirectory && $0.name == folder }) else { return ids }
        let existing = try await device.files(in: dir)
        var done = Set<String>()
        for id in ids {
            let suffix = "-\(id.prefix(8)).epub"
            for f in existing where !f.isDirectory && f.name.hasSuffix(suffix) { try await device.delete("\(dir)/\(f.name)") }
            done.insert(id)
        }
        return done
    }

    /// Sends every book whose original EPUB the Mac kept and the device doesn't have yet
    /// into `/Habla`. Each upload is verified by size on the device; a mismatch (power
    /// loss, Wi-Fi drop) is retried once. Never deletes the user's other files.
    public func pushBooks(from library: URL, only ids: Set<String>? = nil,
                          progress: (@Sendable (String) -> Void)? = nil) async throws -> PushResult {
        let root = try await device.files(in: "/")
        if let clash = root.first(where: { $0.name == folder }), !clash.isDirectory {
            throw SyncError.http(409, "A file named '\(folder)' is in the way on the device")
        }
        if !root.contains(where: { $0.isDirectory && $0.name == folder }) {
            try await device.makeFolder(folder, in: "/")
        }
        let dir = "/\(folder)"
        var existing = try await device.files(in: dir)

        // Stray staged copies from an interrupted overwrite.
        for f in existing where f.name.hasSuffix(".epub.part") { try? await device.delete("\(dir)/\(f.name)") }

        var result = PushResult()
        let manifests = LibraryServer(library: library, progress: ProgressStore(fileURL: library.appendingPathComponent(".unused.json")))
            .manifests().filter { ids?.contains($0.id) ?? true }
        for m in manifests {
            let original = BookImporter.originalURL(for: m.id, in: library)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: original.path))?[.size] as? Int else { continue }
            let name = BookImporter.deviceFileName(title: m.title, id: m.id)
            let there = existing.first { $0.name == name && !$0.isDirectory }
            if there?.size == size { result.alreadyThere.append(m.title); continue }
            progress?(m.title)
            var ok = false
            var reason = ""
            for _ in 0..<2 where !ok {
                do {
                    try await device.upload(original, as: name, to: dir, overwrite: there != nil || reason != "")
                    existing = try await device.files(in: dir)
                    ok = existing.contains { $0.name == name && $0.size == size }
                    if !ok { reason = "size check failed after upload" }
                } catch {
                    reason = (error as? SyncError)?.description ?? error.localizedDescription
                }
            }
            if ok { result.sent.append(m.title) } else { result.failed.append((m.title, reason)) }
        }
        return result
    }
}

public enum LocalNetwork {
    /// This Mac's LAN IPv4 address (Wi-Fi / Ethernet), for URLs handed to e-readers,
    /// which can't resolve `.local` names themselves.
    public static func primaryIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(String, String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (Int32(i.ifa_flags) & IFF_UP) != 0, (Int32(i.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            candidates.append((String(cString: i.ifa_name), String(cString: host)))
        }
        return (candidates.first { $0.0 == "en0" } ?? candidates.first { $0.0.hasPrefix("en") } ?? candidates.first)?.1
    }
}
