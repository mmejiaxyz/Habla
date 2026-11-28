import XCTest
import CryptoKit
@testable import HablaCore

/// The Worker contract (Docs/cloud-bridge.md), in process: records every byte it is given.
final class FakeBridge: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var objects: [String: (data: Data, etag: String)] = [:]
    nonisolated(unsafe) static var seen: [String] = []          // every URL + header the bridge received
    nonisolated(unsafe) static var storageCap = Int.max
    nonisolated(unsafe) static var corrupt: Set<String> = []     // object names served with a flipped byte
    nonisolated(unsafe) static var seenAt: [String: Date] = [:]  // device check-ins (listing the documents)
    static let lock = NSLock()

    static func reset() { lock.withLock { objects = [:]; seen = []; storageCap = .max; corrupt = []; seenAt = [:] } }
    static var stored: Int { lock.withLock { objects.values.reduce(0) { $0 + $1.data.count } } }
    static func names(_ kind: String) -> [String] { lock.withLock { objects.keys.filter { $0.hasPrefix(kind + "/") } } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let r = request
        var body = r.httpBody ?? Data()
        if let s = r.httpBodyStream {
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 65536)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
        }
        let parts = r.url!.path.split(separator: "/").map(String.init)
        let (status, data, headers) = Self.lock.withLock { () -> (Int, Data, [String: String]) in
            Self.seen.append(r.url!.absoluteString + " " + (r.allHTTPHeaderFields ?? [:]).description)
            guard r.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true else { return (401, Data(), [:]) }
            let js = { (o: Any) in try! JSONSerialization.data(withJSONObject: o) }
            if parts == ["v1", "usage"] {
                let used = Self.objects.values.reduce(0) { $0 + $1.data.count }
                return (200, js(["storageBytes": used, "portfolioBytes": 0, "storageCapBytes": 1 << 40,   // claims room, so the 507 path is what stops uploads
                                 "classA": 0, "classACap": 1, "classB": 0, "classBCap": 1, "requestsToday": 0, "requestsCapDay": 1]), [:])
            }
            guard parts.count >= 2, parts[0] == "v1" else { return (404, Data(), [:]) }
            let kind = parts[1]
            if parts.count == 2 {
                if kind == "state", let d = r.value(forHTTPHeaderField: "X-Habla-Device") { Self.seenAt[d] = Date() }
                let f = ISO8601DateFormatter()
                let list = Self.objects.filter { $0.key.hasPrefix(kind + "/") }.map { o -> [String: Any] in
                    let name = String(o.key.dropFirst(kind.count + 1))
                    var e: [String: Any] = ["name": name, "size": o.value.data.count, "etag": o.value.etag]
                    if let at = Self.seenAt[name] { e["seen"] = f.string(from: at) }
                    return e
                }
                return (200, js(list), [:])
            }
            let key = "\(kind)/\(parts[2])"
            precondition(parts[2].range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil, "name leaked structure")
            switch r.httpMethod {
            case "PUT":
                let used = Self.objects.values.reduce(0) { $0 + $1.data.count }
                if used + body.count > Self.storageCap { return (507, js(["error": "full", "cap": "storage"]), [:]) }
                let etag = UUID().uuidString
                Self.objects[key] = (body, etag)
                return (200, js(["etag": etag]), [:])
            case "DELETE":
                Self.objects[key] = nil
                return (200, js(["ok": true]), [:])
            default:
                guard var o = Self.objects[key] else { return (404, Data(), [:]) }
                if r.value(forHTTPHeaderField: "If-None-Match") == "\"\(o.etag)\"" { return (304, Data(), ["ETag": "\"\(o.etag)\""]) }
                if Self.corrupt.contains(parts[2]) { o.data[o.data.count / 2] ^= 0xFF }
                return (200, o.data, ["ETag": "\"\(o.etag)\""])
            }
        }
        let response = HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeBridge.self]
        return URLSession(configuration: c)
    }
}

final class BridgeTests: XCTestCase {
    let key = BridgeKeys.newLibraryKey()
    let url = URL(string: "https://bridge.test")!

    override func setUp() { FakeBridge.reset() }

    /// A fully narrated sample book, plus a 9 MB file so a file spans two chunks.
    func makeLibrary() async throws -> (URL, BookManifest) {
        let mac = Fixtures.tempDir().appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        let bundle = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: mac.deletingLastPathComponent()), into: mac)
        try await RenderPipeline(engine: ToneEngine(), cacheDirectory: mac.deletingLastPathComponent().appendingPathComponent("c"))
            .render(bundle, voice: VoiceInfo(engine: "tone", voiceID: "tone"))
        var big = Data(count: 9 * 1024 * 1024)
        big.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try big.write(to: bundle.fileURL("audio/extra.bin"))
        let m = try bundle.commit(bundle.manifest())
        XCTAssertTrue(m.isFullyRendered)
        return (mac, m)
    }

    func device(_ id: String, _ role: DeviceDocument.Role, library: URL) -> (BridgeSync, ProgressStore, MarkerStore) {
        let dir = library.deletingLastPathComponent()
        let progress = ProgressStore(fileURL: dir.appendingPathComponent("progress.json"))
        let markers = MarkerStore(fileURL: dir.appendingPathComponent("markers.json"), deviceID: id)
        let sync = BridgeSync(config: BridgeConfig(url: url, libraryKey: key), deviceID: id, deviceName: "Sam’s \(role)",
                              role: role, progress: progress, markers: markers, library: library,
                              stateURL: dir.appendingPathComponent("bridge-state.json"), session: FakeBridge.session())
        return (sync, progress, markers)
    }

    /// The whole trip, and what Cloudflare could see of it: nothing readable.
    func testBooksPositionsAndMarkersTravelSealed() async throws {
        let (macLib, m) = try await makeLibrary()
        let phoneLib = Fixtures.tempDir().appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: phoneLib, withIntermediateDirectories: true)
        let (mac, macProgress, macMarkers) = device("mac-1", .mac, library: macLib)
        let (phone, phoneProgress, phoneMarkers) = device("iphone-1", .phone, library: phoneLib)

        // The Mac lists the book, the phone asks for it, the Mac sends it.
        try await mac.syncState()
        try await phone.syncState()
        try await mac.syncState()
        let sent = try await mac.publishNewBooks()
        XCTAssertEqual(sent, [m.id])
        XCTAssertGreaterThan(FakeBridge.names("transit").count, m.files.count, "the 9 MB file spans two chunks")
        let again = try await mac.publishNewBooks()
        XCTAssertEqual(again, [], "a book is sent once")

        // The phone installs a byte-identical book.
        try await phone.syncState()
        let installed = try await phone.receiveBooks()
        XCTAssertEqual(installed, [m.id])
        for f in m.files {
            XCTAssertEqual(try BookBundle.sha256(of: BookBundle(url: BookBundle.url(for: m.id, in: phoneLib)).fileURL(f.path)), f.sha256)
        }

        // Place and markers, both ways, including a removal.
        phoneProgress.record(ReadingPosition(bookID: m.id, chapter: 2, sentence: 7, mode: .reading, deviceID: "iphone-1"))
        let mark = Marker(bookID: m.id, kind: .bookmark, chapter: 2, sentence: 7, text: "Plain & simple text", deviceID: "iphone-1")
        let line = Marker(bookID: m.id, kind: .underline, chapter: 1, sentence: 3, offset: 4, length: 6, text: "Darcy", deviceID: "iphone-1")
        phoneMarkers.add(mark); phoneMarkers.add(line)
        try await phone.syncState()
        try await mac.syncState()
        XCTAssertEqual(macProgress.position(for: m.id)?.sentence, 7)
        XCTAssertEqual(Set(macMarkers.markers(book: m.id).map(\.id)), [mark.id, line.id])
        macMarkers.remove(line.id)
        try await mac.syncState()
        try await phone.syncState()
        XCTAssertEqual(phoneMarkers.markers(book: m.id).map(\.id), [mark.id])

        // Once the phone has it, the book leaves the bridge.
        try await mac.syncState()
        try await mac.collect()
        XCTAssertEqual(FakeBridge.names("transit"), [], "books only pass through")
        XCTAssertEqual(FakeBridge.names("state").count, 2, "places and markers stay")

        // Cloudflare saw no title, author, id, device name, text or key.
        let blobs = FakeBridge.lock.withLock { FakeBridge.objects.values.map(\.data) }
        let traffic = Data(FakeBridge.lock.withLock { FakeBridge.seen.joined(separator: "\n") }.utf8)
        let secrets = [m.title, m.author, m.id, "Sam", "iphone-1", "mac-1", "Darcy", "Plain & simple", "Chapter I"]
            .filter { !$0.isEmpty }.map { Data($0.utf8) } + [key, key.base64EncodedData()]
        for s in secrets {
            for b in blobs + [traffic] { XCTAssertNil(b.range(of: s), "leaked: \(String(decoding: s, as: UTF8.self))") }
        }
        let keys = BridgeKeys(libraryKey: key)
        XCTAssertNil(traffic.range(of: keys.encKey.withUnsafeBytes { Data($0) }))
        XCTAssertTrue(blobs.allSatisfy { ($0.count - 29) % 4096 == 0 || ($0.count - 29) % 65536 == 0 }, "sizes are padded")
    }

    /// A bad byte, a wrong key, or a full bridge never breaks a library.
    /// The original EPUB travels to the account's other Macs (so each can hand it to the Xteink),
    /// byte for byte, and never to a phone.
    func testOriginalEPUBReachesMacsOnly() async throws {
        let (macLib, m) = try await makeLibrary()
        let original = BookImporter.originalURL(for: m.id, in: macLib)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        let libs = (0..<2).map { _ -> URL in
            let l = Fixtures.tempDir().appendingPathComponent("Library")
            try? FileManager.default.createDirectory(at: l, withIntermediateDirectories: true)
            return l
        }
        let (mac, _, _) = device("mac-1", .mac, library: macLib)
        let (mac2, _, _) = device("mac-2", .mac, library: libs[0])
        let (phone, _, _) = device("iphone-1", .phone, library: libs[1])
        for d in [mac, mac2, phone, mac] { try await d.syncState() }
        let sent = try await mac.publishNewBooks()
        XCTAssertEqual(sent, [m.id])
        for d in [mac2, phone] { try await d.syncState(); let got = try await d.receiveBooks(); XCTAssertEqual(got, [m.id]) }
        XCTAssertEqual(try Data(contentsOf: BookImporter.originalURL(for: m.id, in: libs[0])), try Data(contentsOf: original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: BookImporter.originalURL(for: m.id, in: libs[1]).path))
        let phoneBundle = BookBundle.url(for: m.id, in: libs[1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: phoneBundle.appendingPathComponent("_original.epub").path))
    }

    func testFailuresLeaveLibrariesAlone() async throws {
        let keys = BridgeKeys(libraryKey: key)
        let sealed = try keys.seal(Data("hello".utf8), logical: "a", padTo: 4096)
        XCTAssertEqual(try keys.open(sealed, logical: "a"), Data("hello".utf8))
        XCTAssertThrowsError(try keys.open(sealed, logical: "b"), "a blob can't move to another name")
        XCTAssertThrowsError(try BridgeKeys(libraryKey: BridgeKeys.newLibraryKey()).open(sealed, logical: "a"))

        let (macLib, m) = try await makeLibrary()
        let phoneLib = Fixtures.tempDir().appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: phoneLib, withIntermediateDirectories: true)
        let (mac, _, _) = device("mac-1", .mac, library: macLib)
        let (phone, _, _) = device("iphone-1", .phone, library: phoneLib)
        try await mac.syncState()
        try await phone.syncState()
        try await mac.syncState()

        // Full (the Worker refuses the first chunk): nothing half-sent, sync pauses instead of retrying.
        FakeBridge.storageCap = FakeBridge.stored + 1000
        do { try await mac.publishNewBooks() } catch BridgeError.capReached {}
        let paused = await mac.pausedUntil
        XCTAssertNotNil(paused)
        XCTAssertTrue(FakeBridge.names("transit").isEmpty)

        // A tampered chunk: the phone refuses the book and keeps its library as it was.
        FakeBridge.storageCap = .max
        let fresh = BridgeSync(config: BridgeConfig(url: url, libraryKey: key), deviceID: "mac-1", deviceName: "Mac", role: .mac,
                               progress: ProgressStore(fileURL: macLib.deletingLastPathComponent().appendingPathComponent("p2.json")),
                               markers: MarkerStore(fileURL: macLib.deletingLastPathComponent().appendingPathComponent("m2.json"), deviceID: "mac-1"),
                               library: macLib, stateURL: macLib.deletingLastPathComponent().appendingPathComponent("s2.json"), session: FakeBridge.session())
        try await fresh.syncState()
        try await fresh.publishNewBooks()
        FakeBridge.corrupt = Set(FakeBridge.names("transit").prefix(1).map { String($0.dropFirst("transit/".count)) })
        try await phone.syncState()
        let installed = try await phone.receiveBooks()
        XCTAssertEqual(installed, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: BookBundle.url(for: m.id, in: phoneLib).appendingPathComponent(BookBundle.manifestFile).path))
    }

    /// A new book goes to the running device that finishes it first; a quiet one is skipped,
    /// and the chosen Mac collects the EPUB.
    func testNewBookGoesToFastestRunningMac() async throws {
        let libs = (0..<3).map { _ -> URL in
            let l = Fixtures.tempDir().appendingPathComponent("Library")
            try? FileManager.default.createDirectory(at: l, withIntermediateDirectories: true)
            return l
        }
        let (macA, _, _) = device("mac-a", .mac, library: libs[0])
        let (macB, _, _) = device("mac-b", .mac, library: libs[1])
        let (phone, _, _) = device("iphone-1", .phone, library: libs[2])
        let inboxB = libs[1].deletingLastPathComponent().appendingPathComponent("Inbox")
        await macB.configure(inbox: inboxB)
        await macA.setNarrator(NarratorStatus(sentencesPerSecond: 1.0, queuedSentences: 4000, measured: true))   // busy
        await macB.setNarrator(NarratorStatus(sentencesPerSecond: 1.5, queuedSentences: 0, measured: true))
        await phone.setNarrator(NarratorStatus(sentencesPerSecond: 0.2, queuedSentences: 0, measured: true))
        try await macA.syncState(); try await macB.syncState(); try await phone.syncState()

        let pick = await phone.chooseNarrator(sentences: 900)
        XCTAssertEqual(pick, "mac-b")
        let epub = try Fixtures.writeSampleEPUB(to: libs[2].deletingLastPathComponent())
        let id = try DocumentDigest.sha256Prefix(of: epub)
        try await phone.sendEPUB(epub, id: id, filename: "Sample.epub", to: pick)
        try await macA.syncState(); try await macB.syncState()
        let atA = try await macA.receiveEPUBs()
        XCTAssertEqual(atA, [], "only the chosen Mac takes it")
        let atB = try await macB.receiveEPUBs()
        XCTAssertEqual(atB.count, 1)
        XCTAssertEqual(try BookBundle.sha256(of: atB[0]), try BookBundle.sha256(of: epub))

        // Both Macs go quiet (last check-ins an hour ago): the phone narrates rather than wait.
        let keys = BridgeKeys(libraryKey: key)
        for mac in ["mac-a", "mac-b"] { FakeBridge.lock.withLock { FakeBridge.seenAt[keys.objectName("state/\(mac)")] = Date().addingTimeInterval(-3600) } }
        try await phone.syncState()
        let stale = await phone.chooseNarrator(sentences: 900)
        XCTAssertEqual(stale, "iphone-1")

        // One voice for the account: changed on a Mac, every device follows.
        await macA.setVoice("bm_fable")
        try await macA.syncState(); try await phone.syncState()
        let voice = await phone.settings.voice
        XCTAssertEqual(voice, "bm_fable")
    }

    /// A helper Mac narrates for the account but never sees places or marks, never receives
    /// books, and drops what it narrated once every device has it.
    func testHelperNarratesWithoutKeepingOrSeeing() async throws {
        let (helperLib, m) = try await makeLibrary()          // stands for a book it just narrated
        let phoneLib = Fixtures.tempDir().appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: phoneLib, withIntermediateDirectories: true)
        let (helper, helperProgress, helperMarkers) = device("mac-helper", .helper, library: helperLib)
        let (phone, phoneProgress, phoneMarkers) = device("iphone-1", .phone, library: phoneLib)
        let done = Locked<[String]>([])
        await helper.configure(onJobDone: { id in done.mutate { $0.append(id) } })
        await helper.setNarrator(NarratorStatus(sentencesPerSecond: 2, queuedSentences: 0, measured: true))

        phoneProgress.record(ReadingPosition(bookID: "other-book", chapter: 1, sentence: 2, mode: .reading, deviceID: "iphone-1"))
        phoneMarkers.add(Marker(bookID: "other-book", kind: .bookmark, chapter: 1, sentence: 2, text: "secret place", deviceID: "iphone-1"))
        try await phone.syncState(); try await helper.syncState(); try await phone.syncState()

        let pick = await phone.chooseNarrator(sentences: 500)
        XCTAssertEqual(pick, "mac-helper", "a running helper can be chosen")
        XCTAssertNil(helperProgress.position(for: "other-book"), "no places on a helper")
        XCTAssertTrue(helperMarkers.all.isEmpty, "no marks on a helper")

        // It narrated a job: the phone gets it; once collected the helper lets it go.
        await helper.recordJobForTest(m.id)
        try await helper.syncState(); try await phone.syncState(); try await helper.syncState()   // the phone asks
        let sent = try await helper.publishNewBooks()
        XCTAssertEqual(sent, [m.id])
        try await phone.syncState()
        let got = try await phone.receiveBooks()
        XCTAssertEqual(got, [m.id])
        try await helper.syncState()
        try await helper.collect()
        XCTAssertEqual(done.value, [m.id])
        XCTAssertTrue(FakeBridge.names("transit").isEmpty)
        let received = try await helper.receiveBooks()
        XCTAssertEqual(received, [], "a helper never takes finished books")
    }

    /// A book narrated here for someone else's library never reaches this Mac's own devices:
    /// not through its own bridge, not over Wi-Fi.
    func testGuestBookNeverReachesOwnDevices() async throws {
        let (macLib, m) = try await makeLibrary()
        let phoneLib = Fixtures.tempDir().appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: phoneLib, withIntermediateDirectories: true)
        let (mac, _, _) = device("mac-1", .mac, library: macLib)
        let (phone, _, _) = device("iphone-1", .phone, library: phoneLib)
        await mac.configure(hidden: { [m.id] })
        try await phone.syncState(); try await mac.syncState()
        let sent = try await mac.publishNewBooks()
        XCTAssertEqual(sent, [], "never sent to its own phone")
        XCTAssertTrue(FakeBridge.names("transit").isEmpty)
        try await phone.syncState()
        let received = try await phone.receiveBooks()
        XCTAssertEqual(received, [])
        let held = await phone.booksOnMac()
        XCTAssertFalse(held.contains(m.id), "not even listed as held")

        let server = LibraryServer(library: macLib, progress: ProgressStore(fileURL: macLib.appendingPathComponent(".p.json")))
        server.isHidden = { $0 == m.id }
        func get(_ path: String) -> Int { server.route(HTTPRequest(method: "GET", path: path, headers: [:], body: Data())).status }
        XCTAssertTrue(server.manifests().isEmpty)
        XCTAssertEqual(server.allManifests().map(\.id), [m.id], "the app itself still narrates it")
        XCTAssertEqual(get("/v1/books/\(m.id)/manifest"), 404)
        XCTAssertEqual(get("/v1/books/\(m.id)/files/\(m.files[0].path)"), 404)
    }
}

