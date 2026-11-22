import Foundation
import Network
@testable import HablaCore

/// Protocol double of CrossPoint's File Transfer web server, written from the firmware
/// source (src/network/CrossPointWebServer.cpp): same routes, argument styles and quirks
/// (upload refuses to overwrite; settings are JSON keyed like the web settings page).
final class FakeCrossPoint: @unchecked Sendable {
    var files: [String: Data] = [:]          // "/Habla/x.epub" → bytes
    var folders: Set<String> = ["/"]
    var settings: [String: Any] = [:]
    var opds: [[String: Any]] = []
    var uploads = 0
    private var listener: NWListener?
    private var udp: Int32 = -1
    private let queue = DispatchQueue(label: "fake.crosspoint")
    private let lock = NSLock()

    func start() async throws -> (http: UInt16, udp: UInt16) {
        let l = try NWListener(using: .tcp)
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        listener = l
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = Once()
            l.stateUpdateHandler = { s in
                if case .ready = s, once.claim() { cont.resume(returning: l.port!.rawValue) }
                if case .failed(let e) = s, once.claim() { cont.resume(throwing: e) }
            }
            l.start(queue: queue)
        }
        // UDP discovery on an ephemeral port.
        udp = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(udp, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(udp, $0, &len) } }
        let fd = udp
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 16)
            while true {
                var from = sockaddr_in(); var fl = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, 15, 0, $0, &fl) } }
                if n <= 0 { return }
                if String(decoding: buf[0..<n], as: UTF8.self) == "hello" {
                    let msg = "crosspoint (on crosspoint);81"
                    _ = withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, msg, msg.utf8.count, 0, $0, fl) } }
                }
            }
        }
        return (port, UInt16(bigEndian: bound.sin_port))
    }

    func stop() { listener?.cancel(); if udp >= 0 { close(udp) } }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] d, _, done, _ in
            guard let self else { return }
            var b = buf; if let d { b.append(d) }
            guard let req = HTTPRequest.parse(b) else { if !done { self.receive(c, b) }; return }
            let (status, type, body) = self.lock.withLock { self.route(req, raw: b) }
            let head = "HTTP/1.1 \(status) X\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
        }
    }

    private func form(_ body: Data) -> [String: String] {
        var out: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    private func query(_ r: HTTPRequest, raw: Data) -> [String: String] {
        let line = String(decoding: raw.prefix(while: { $0 != 13 }), as: UTF8.self)
        guard let q = line.split(separator: " ")[1].split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        return form(Data(q.utf8))
    }

    private func route(_ r: HTTPRequest, raw: Data) -> (Int, String, Data) {
        let json = { (o: Any) in (200, "application/json", try! JSONSerialization.data(withJSONObject: o)) }
        switch (r.method, r.path) {
        case ("GET", "/api/status"):
            return json(["version": "1.6.0", "device": "X4", "ip": "127.0.0.1", "mode": "STA"])
        case ("GET", "/api/files"):
            let dir = query(r, raw: raw)["path"] ?? "/"
            let prefix = dir == "/" ? "/" : dir + "/"
            var items: [[String: Any]] = folders.filter { $0 != "/" && $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
                .map { ["name": String($0.dropFirst(prefix.count)), "size": 0, "isDirectory": true, "isEpub": false] }
            items += files.filter { $0.key.hasPrefix(prefix) && !$0.key.dropFirst(prefix.count).contains("/") }
                .map { ["name": String($0.key.dropFirst(prefix.count)), "size": $0.value.count, "isDirectory": false, "isEpub": true] }
            return json(items)
        case ("POST", "/mkdir"):
            let f = form(r.body)
            guard let name = f["name"] else { return (400, "text/plain", Data("Missing folder name".utf8)) }
            folders.insert((f["path"] == "/" || f["path"] == nil ? "" : f["path"]!) + "/" + name)
            return (200, "text/plain", Data("ok".utf8))
        case ("POST", "/delete"):
            guard let p = form(r.body)["path"] else { return (400, "text/plain", Data("Missing `path`".utf8)) }
            files[p] = nil
            return (200, "text/plain", Data("All items deleted successfully".utf8))
        case ("POST", "/upload"):
            let dir = query(r, raw: raw)["path"] ?? "/"
            let text = r.body
            guard let nameStart = text.range(of: Data("filename=\"".utf8)),
                  let nameEnd = text[nameStart.upperBound...].firstIndex(of: UInt8(ascii: "\"")),
                  let headEnd = text.range(of: Data("\r\n\r\n".utf8), in: nameEnd..<text.endIndex),
                  let tail = text.range(of: Data("\r\n--".utf8), options: .backwards) else {
                return (400, "text/plain", Data("bad multipart".utf8))
            }
            let name = String(decoding: text[nameStart.upperBound..<nameEnd], as: UTF8.self)
            let path = (dir == "/" ? "" : dir) + "/" + name
            let overwrite = ["1", "true"].contains(query(r, raw: raw)["overwrite"] ?? "")
            if folders.contains(path) { return (400, "text/plain", Data("A folder with this name already exists: \(name)".utf8)) }
            if files[path] != nil && !overwrite { return (400, "text/plain", Data("File already exists: \(name)".utf8)) }
            uploads += 1
            files[path] = text.subdata(in: headEnd.upperBound..<tail.lowerBound)
            return (200, "text/plain", Data("File uploaded successfully: \(name)".utf8))
        case ("POST", "/api/settings"):
            guard let o = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else { return (400, "text/plain", Data()) }
            // Firmware: enums are ints in range (else ignored); strings for URL/credentials.
            let enums = ["koServerType": 3, "koMatchMethod": 2, "koSyncBehavior": 2, "koSendMetadata": 2, "koSyncOnSleep": 2]
            for (k, v) in o {
                if let max = enums[k] { if let i = v as? Int, i >= 0, i < max { settings[k] = i }; continue }
                if v is String { settings[k] = v }
            }
            return (200, "text/plain", Data("Applied".utf8))
        case ("GET", "/api/opds"):
            return json(opds)
        case ("POST", "/api/opds"):
            let o = try! JSONSerialization.jsonObject(with: r.body) as! [String: Any]
            if let i = o["index"] as? Int {
                guard opds.indices.contains(i) else { return (400, "text/plain", Data("Invalid server index".utf8)) }
                opds[i]["name"] = o["name"]; opds[i]["url"] = o["url"]
            } else {
                guard opds.count < 8 else { return (400, "text/plain", Data("Cannot add server (limit reached)".utf8)) }
                opds.append(["index": opds.count, "name": o["name"]!, "url": o["url"]!])
            }
            return (200, "text/plain", Data("ok".utf8))
        default:
            return (404, "text/plain", Data("Not found".utf8))
        }
    }
}
