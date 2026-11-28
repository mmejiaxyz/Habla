import XCTest
@testable import HablaCore

/// The account end to end against the real Worker (`Cloudflare/habla-bridge/test/serve.mjs`, the
/// Worker on node with fake bindings). Guards what matters: one code joins, the EPUB is the book
/// everywhere, audio lands only on identical text, the account picks the narrator, deletes go
/// everywhere, and nothing stays in the cloud once every device has it.
final class AccountTests: XCTestCase {
    var server: Process?
    var url: URL!

    override func setUp() async throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Cloudflare/habla-bridge/test/serve.mjs")
        guard let node = ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("node isn't installed")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = ["--no-warnings", script.path, "0"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        server = p
        var line = ""
        while !line.contains("\n"), let d = try out.fileHandleForReading.read(upToCount: 1), !d.isEmpty { line += String(decoding: d, as: UTF8.self) }
        let port = line.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "listening ", with: "")
        url = URL(string: "http://127.0.0.1:\(port)")!
    }

    override func tearDown() { server?.terminate() }

    struct Device {
        let sync: AccountSync
        let library: URL
        let progress: ProgressStore
        let markers: MarkerStore
    }

    func device(_ id: String, _ kind: DeviceKind, _ config: BridgeConfig) -> Device {
        let dir = Fixtures.tempDir()
        let lib = dir.appendingPathComponent("Library")
        try! FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        let progress = ProgressStore(fileURL: dir.appendingPathComponent("progress.json"))
        let markers = MarkerStore(fileURL: dir.appendingPathComponent("markers.json"), deviceID: id)
        let s = AccountSync(config: config, deviceID: id, deviceName: "Sam’s \(kind)", kind: kind, progress: progress,
                            markers: markers, library: lib, stateURL: dir.appendingPathComponent("account.json"))
        return Device(sync: s, library: lib, progress: progress, markers: markers)
    }

    func transit(_ config: BridgeConfig) async throws -> Int {
        try await BridgeClient(baseURL: url, token: BridgeKeys(libraryKey: config.libraryKey).token).list(.transit).count
    }

    /// Mac A makes the account and adds a narrated book; a phone joins with a one-time code and a
    /// second Mac joins too. Both get the EPUB, build the text themselves, and take the audio.
    func testBookAddedAnywhereReachesEveryDevice() async throws {
        let config = try await AccountSync.createAccount(at: url, serverKey: "s3cret")
        let macA = device("mac-a", .mac, config)
        await macA.sync.setName("Sam")
        await macA.sync.setVoice("tone")
        let bundle = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: macA.library.deletingLastPathComponent()), into: macA.library)
        try await RenderPipeline(engine: ToneEngine(), cacheDirectory: macA.library.deletingLastPathComponent().appendingPathComponent("c"))
            .render(bundle, voice: VoiceInfo(engine: "tone", voiceID: "tone"))
        let m = try bundle.manifest()
        await macA.sync.recordAdded(m.id)
        try await macA.sync.sync()

        // A one-time code joins once.
        let code = try await macA.sync.makeJoinCode()
        let typed = try XCTUnwrap(JoinCode(code.display.lowercased()))
        let joined = try await AccountSync.join(typed, at: url)
        XCTAssertEqual(joined.config.libraryKey, config.libraryKey)
        XCTAssertEqual(joined.name, "Sam")
        do { _ = try await AccountSync.join(typed, at: url); XCTFail("a code works once") } catch BridgeError.http(404) {}

        let phone = device("iphone-1", .phone, joined.config)
        let macB = device("mac-b", .mac, joined.config)
        for _ in 0..<3 { for d in [phone, macB, macA] { try await d.sync.sync() } }

        for d in [phone, macB] {
            let original = BookImporter.originalURL(for: m.id, in: d.library)
            XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: BookImporter.originalURL(for: m.id, in: macA.library)), "the EPUB, byte for byte")
            let theirs = try BookBundle(url: BookBundle.url(for: m.id, in: d.library)).manifest()
            XCTAssertEqual(theirs.chapters.map(\.audioStatus), m.chapters.map(\.audioStatus), "the audio landed on the text built here")
            XCTAssertTrue(theirs.isFullyRendered && theirs.chapters.contains { $0.audioStatus == .ready })
            XCTAssertEqual(try BookBundle.sha256(of: BookBundle(url: BookBundle.url(for: m.id, in: d.library)).fileURL(BookBundle.audioPath(m.chapters.first { $0.audioStatus == .ready }!.index))),
                           m.files.first { $0.path == BookBundle.audioPath(m.chapters.first { $0.audioStatus == .ready }!.index) }?.sha256)
            let settings = await d.sync.settings
            XCTAssertEqual(settings.voice, "tone"); XCTAssertEqual(settings.name, "Sam")
        }
        let left = try await transit(config)
        XCTAssertEqual(left, 0, "everyone has it: nothing stays in the cloud")
        let devices = await macA.sync.devices()
        XCTAssertEqual(Set(devices.map(\.name)), ["Sam’s phone", "Sam’s mac"])
    }

    /// Audio is installed only on identical text: a chapter whose text differs here is left to narrate.
    func testAudioOnlyOnMatchingText() async throws {
        let config = try await AccountSync.createAccount(at: url, serverKey: "s3cret")
        let mac = device("mac-a", .mac, config), phone = device("iphone-1", .phone, config)
        await mac.sync.setVoice("tone")
        let epub = Fixtures.writeSampleEPUB(to: mac.library.deletingLastPathComponent())
        let bundle = try BookImporter().importEPUB(at: epub, into: mac.library)
        // The phone already has the book (its own import), with one chapter's text changed.
        let mine = try BookImporter().importEPUB(at: epub, into: phone.library)
        let m = try mine.manifest()
        let changed = try XCTUnwrap(m.chapters.first { !$0.isFrontMatter })
        var text = try mine.chapterText(changed)
        text.blocks[text.blocks.count - 1].text += " Extra."
        if var last = text.blocks[text.blocks.count - 1].sentences.last {
            last.range.length += 7
            text.blocks[text.blocks.count - 1].sentences[text.blocks[text.blocks.count - 1].sentences.count - 1] = last
        }
        try mine.write(text, to: changed.textFile)
        try await RenderPipeline(engine: ToneEngine(), cacheDirectory: mac.library.deletingLastPathComponent().appendingPathComponent("c"))
            .render(bundle, voice: VoiceInfo(engine: "tone", voiceID: "tone"))
        for _ in 0..<3 { for d in [mac, phone] { try await d.sync.sync() } }
        let got = try mine.manifest()
        XCTAssertEqual(got.chapters.first { $0.index == changed.index }?.audioStatus, .pending, "different text: no audio")
        XCTAssertTrue(got.chapters.contains { $0.index != changed.index && $0.audioStatus == .ready }, "the rest arrived")
    }

    /// The account gives a book to the device that narrates it; deleting anywhere deletes
    /// everywhere; places travel sealed.
    func testNarratorDeletesAndPlaces() async throws {
        let config = try await AccountSync.createAccount(at: url, serverKey: "s3cret")
        let phone = device("iphone-1", .phone, config), mac = device("mac-a", .mac, config)
        await mac.sync.setNarrator(NarratorStatus(sentencesPerSecond: 2, queuedSentences: 0, measured: true))
        await phone.sync.setNarrator(NarratorStatus(sentencesPerSecond: 0.2, queuedSentences: 0, measured: true))
        let m = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: phone.library.deletingLastPathComponent()), into: phone.library).manifest()
        await phone.sync.recordAdded(m.id)
        var macRound = try await mac.sync.sync()
        let phoneRound = try await phone.sync.sync()
        XCTAssertEqual(phoneRound.narrate, [], "a Mac is online: not the iPhone")
        macRound = try await mac.sync.sync()
        XCTAssertEqual(macRound.narrate, [m.id], "the account gives it to the Mac")
        XCTAssertTrue(FileManager.default.fileExists(atPath: BookImporter.originalURL(for: m.id, in: mac.library).path), "with its EPUB")

        phone.progress.record(ReadingPosition(bookID: m.id, chapter: 2, sentence: 3, mode: .reading, deviceID: "iphone-1"))
        try await phone.sync.sync()
        try await mac.sync.sync()
        XCTAssertEqual(mac.progress.position(for: m.id)?.sentence, 3)

        await mac.sync.recordDeleted(m.id)
        try await mac.sync.sync()
        let gone = try await phone.sync.sync()
        XCTAssertEqual(gone.deleted, [m.id])
    }
}

extension AccountTests {
    /// The Xteink through the cloud: its catalog holds the account's EPUBs (title only), its
    /// positions reach the iPhone, and the iPhone's place reaches it, with no Mac in between.
    func testXteinkThroughTheCloud() async throws {
        let config = try await AccountSync.createAccount(at: url, serverKey: "s3cret")
        let mac = device("mac-a", .mac, config), phone = device("iphone-1", .phone, config)
        let m = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: mac.library.deletingLastPathComponent()), into: mac.library).manifest()
        await mac.sync.recordAdded(m.id)
        let login = try await mac.sync.setupEReader()
        for _ in 0..<2 { for d in [mac, phone] { try await d.sync.sync() } }

        func call(_ path: String, method: String = "GET", body: Data? = nil, basic: Bool = false) async throws -> (Data, Int) {
            var r = URLRequest(url: url.appendingPathComponent(path))
            r.httpMethod = method; r.httpBody = body
            if basic { r.setValue("Basic " + Data("\(login.user):\(login.password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
            else { r.setValue(login.user, forHTTPHeaderField: "x-auth-user"); r.setValue(KOReaderDigest.filename(login.password), forHTTPHeaderField: "x-auth-key") }
            let (d, resp) = try await URLSession.shared.data(for: r)
            return (d, (resp as! HTTPURLResponse).statusCode)
        }
        let (feed, _) = try await call("opds", basic: true)
        XCTAssertTrue(String(decoding: feed, as: UTF8.self).contains("<title>\(BookTitle.clean(m.title))</title>"))
        let key = BridgeKeys(libraryKey: config.libraryKey).objectName("book/\(m.id)")
        let (epub, _) = try await call("opds/books/\(key).epub", basic: true)
        XCTAssertEqual(epub, Fixtures.sampleEPUB(), "the EPUB as it is: its digest matches for position sync")

        // The Xteink syncs a place; the iPhone takes it.
        let map = try KOReaderPositionMap(bundle: BookBundle(url: BookBundle.url(for: m.id, in: phone.library)))
        let xp = try XCTUnwrap(map.xpointer(chapter: 2, sentence: 1))
        let put = try JSONSerialization.data(withJSONObject: ["document": m.koreaderDigest, "progress": xp, "percentage": 0.7, "device": "CrossPoint", "device_id": "x4"])
        _ = try await call("kosync/syncs/progress", method: "PUT", body: put)
        try await phone.sync.sync()
        XCTAssertEqual(phone.progress.position(for: m.id).map { [$0.chapter, $0.sentence] }, [2, 1])
        XCTAssertEqual(phone.progress.position(for: m.id)?.deviceID.hasPrefix("koreader:"), true)

        // The iPhone reads on; the Xteink gets the iPhone's place.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        phone.progress.record(ReadingPosition(bookID: m.id, chapter: 2, sentence: 3, mode: .listening, deviceID: "iphone-1"))
        try await phone.sync.sync()
        let (got, _) = try await call("kosync/syncs/progress/\(m.koreaderDigest)")
        let pointer = try XCTUnwrap((try JSONSerialization.jsonObject(with: got) as? [String: Any])?["progress"] as? String)
        XCTAssertEqual(map.position(for: pointer).map { [$0.chapter, $0.sentence] }, [2, 3])
    }

    func testTitlesLeaveTheSourceOut() {
        XCTAssertEqual(BookTitle.clean("The Project Gutenberg eBook of Pride and Prejudice"), "Pride and Prejudice")
        XCTAssertEqual(BookTitle.clean("Zodiac Academy: Ruthless Fae: An Academy Bully Romance (Supernatural Bullies and Beasts Book 2)"),
                       "Zodiac Academy: Ruthless Fae: An Academy Bully Romance")
        XCTAssertEqual(BookTitle.clean("The Republic - Oxford University Press"), "The Republic")
        XCTAssertEqual(BookTitle.clean("Moby Dick | Standard Ebooks"), "Moby Dick")
        XCTAssertEqual(BookTitle.clean("Dune: Deluxe Edition [z-lib.org]"), "Dune: Deluxe Edition")
        XCTAssertEqual(BookTitle.clean("Stand by Me"), "Stand by Me")
    }
}
