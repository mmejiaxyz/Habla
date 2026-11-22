import XCTest
import Network
@testable import HablaCore

final class ImportTests: XCTestCase {
    func testImportStructure() throws {
        let dir = Fixtures.tempDir()
        let bundle = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: dir), into: dir)
        let m = try bundle.manifest()

        XCTAssertEqual(m.title, "A Test Novel")
        XCTAssertEqual(m.author, "Ada Writer")
        XCTAssertEqual(m.chapters.map(\.title), ["Copyright", "Chapter One", "Chapter Two"])
        XCTAssertEqual(m.chapters[0].isFrontMatter, true)
        XCTAssertEqual(m.chapters[0].audioStatus, .skipped)
        XCTAssertEqual(m.chapters[1].audioStatus, .pending)
        XCTAssertEqual(m.koreaderDigest.count, 32)
        XCTAssertEqual(m.revision, 1)
        XCTAssertTrue(m.files.contains { $0.path == "text/ch001.json" })

        let ch1 = try bundle.chapterText(m.chapters[1])
        let allText = ch1.blocks.map(\.text).joined(separator: "\n")
        XCTAssertFalse(allText.contains("footnote"), "footnotes are skipped")
        XCTAssertFalse(allText.contains("var x"), "scripts are skipped")
        XCTAssertTrue(allText.contains("continues in a second file"), "split file merged into its chapter")
        XCTAssertEqual(ch1.blocks.filter { $0.kind == .sceneBreak }.count, 2, "<hr/> and * * * are scene breaks")

        let first = try XCTUnwrap(ch1.blocks.first { $0.text.hasPrefix("It was") })
        XCTAssertFalse(first.text.contains("amused.1"), "note reference removed")
        let italic = try XCTUnwrap(first.styles.first { $0.style == .italic })
        XCTAssertEqual((first.text as NSString).substring(with: italic.range.nsRange), "not")
        XCTAssertTrue(first.source.xpointer.hasPrefix("/body/DocFragment[2]/body/section/p"))

        let verse = try XCTUnwrap(ch1.blocks.first { $0.text.hasPrefix("Later") })
        XCTAssertTrue(verse.text.contains("wrote\ntwo lines\nof verse"), "line breaks preserved for the reader")

        let ch2 = try bundle.chapterText(m.chapters[2])
        XCTAssertEqual(ch2.blocks.first?.kind, .heading)
        XCTAssertTrue(ch2.blocks.contains { $0.kind == .quote })
        XCTAssertTrue(ch2.blocks.contains { $0.text.contains("Plain & simple") })

        // Sentence ids are sequential within a chapter.
        XCTAssertEqual(ch1.sentences.map(\.sentence.id), Array(0..<m.chapters[1].sentenceCount))
    }

    func testDRMRejected() throws {
        var zip = ZipWriter()
        zip.add("META-INF/encryption.xml", data: Data("""
        <encryption><EncryptedData><EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/></EncryptedData></encryption>
        """.utf8))
        XCTAssertThrowsError(try EPUBPackage(archive: ZipArchive(data: zip.finalize()))) { error in
            guard case EPUBError.drmProtected = error else { return XCTFail("\(error)") }
        }
    }

    func testMalformedXHTMLFallsBackToTagSoup() {
        let broken = Data("<html><body><p>Unclosed <i>italic<p>Second para &mdash; ok</body></html>".utf8)
        let r = ContentExtractor(spineIndex: 0, href: "x.html").extract(broken)
        XCTAssertEqual(r.blocks.count, 2)
        XCTAssertEqual(r.blocks[1].text, "Second para — ok")
    }
}

final class TextTests: XCTestCase {
    let seg = SentenceSegmenter()
    let norm = SpeechNormalizer()

    func sentences(_ s: String) -> [String] {
        seg.ranges(in: s).map { (s as NSString).substring(with: $0.nsRange) }
    }

    func testSegmentation() {
        XCTAssertEqual(sentences("Mr. Darcy arrived. He bowed."), ["Mr. Darcy arrived.", "He bowed."])
        XCTAssertEqual(sentences("“Is it?” cried his wife. Yes."), ["“Is it?” cried his wife.", "Yes."])
        let long = String(repeating: "word ", count: 50) + "and then; " + String(repeating: "more ", count: 50) + "end."
        XCTAssertTrue(sentences(long).allSatisfy { $0.count <= seg.maxLength })
    }

    func testSpokenText() {
        XCTAssertEqual(norm.spoken("Mr. Darcy in 1813."), "Mister Darcy in eighteen thirteen.")
        XCTAssertEqual(norm.spoken("It cost $5 on the 21st."), "It cost five dollars on the twenty-first.")
        XCTAssertEqual(norm.spoken("In 1905 and 2004 and 1900."), "In nineteen oh five and two thousand four and nineteen hundred.")
        XCTAssertEqual(norm.spoken("Chapter IV", isHeading: true), "Chapter four")
        XCTAssertEqual(norm.spoken("XII", isHeading: true), "Chapter twelve")
        XCTAssertEqual(norm.spoken("I", isHeading: true), "Chapter one")
        XCTAssertEqual(norm.spoken("I said so."), "I said so.")
        XCTAssertEqual(norm.spoken("She waited—then left."), "She waited, then left.")
        XCTAssertEqual(norm.spoken("1,200 men"), "one thousand two hundred men")
        XCTAssertEqual(norm.spoken("THE END OF THE STORY"), "The end of the story")
    }
}

final class RenderTests: XCTestCase {
    func testRenderCachesAndResumes() async throws {
        let dir = Fixtures.tempDir()
        let bundle = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: dir), into: dir)
        let cache = dir.appendingPathComponent("cache")
        let pipeline = RenderPipeline(engine: ToneEngine(), cacheDirectory: cache)
        let voice = VoiceInfo(engine: "tone", voiceID: "tone")

        try await pipeline.render(bundle, voice: voice)
        var m = try bundle.manifest()
        XCTAssertTrue(m.isFullyRendered)
        XCTAssertEqual(m.chapters[0].audioStatus, .skipped)
        let info = m.chapters[1]
        let timing = try XCTUnwrap(try bundle.timing(info))
        XCTAssertGreaterThan(timing.duration, 1)
        XCTAssertEqual(timing.sentences.map(\.id), timing.sentences.map(\.id).sorted())
        for (a, b) in zip(timing.sentences, timing.sentences.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start) }
        XCTAssertEqual(timing.sentence(at: timing.sentences[1].start + 0.01), timing.sentences[1].id)
        XCTAssertTrue(m.files.contains { $0.path == "audio/ch001.m4a" })

        // Voice change → re-render, but every sentence comes from cache only if the voice matches.
        let hits = HitCounter()
        let voice2 = VoiceInfo(engine: "tone", voiceID: "tone", speed: 1.0)
        try await pipeline.render(bundle, voice: voice2) { hits.add($0.cacheHit) }
        XCTAssertEqual(hits.misses, 0, "same voice: nothing to render")

        m.chapters[1].audioStatus = .pending
        try bundle.commit(m)
        try await pipeline.render(bundle, voice: voice) { hits.add($0.cacheHit) }
        XCTAssertGreaterThan(hits.hits, 0)
        XCTAssertEqual(hits.misses, 0, "re-render of an unchanged chapter is all cache hits")
    }
}

final class CrossPointReaderNumberingTests: XCTestCase {
    /// CrossPoint READS text()[k] as "after k-1 closed child elements" but WRITES it as
    /// "k-th non-empty text run": a paragraph that opens with <abbr> differs. Offsets are raw code
    /// points (uncollapsed whitespace, U+FEFF counted).
    func testPointersFollowFirmwareConventions() throws {
        let dir = Fixtures.tempDir()
        let bundle = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: dir), into: dir)
        let m = try bundle.manifest()
        let ch = try bundle.chapterText(m.chapters[2])
        let para = try XCTUnwrap(ch.blocks.first { $0.text.hasPrefix("Mr.") })
        XCTAssertTrue(para.text.contains("Bingley\u{2060}—truly"), "U+FEFF kept (as U+2060) so offsets match")
        let second = try XCTUnwrap(para.sentences.first { (para.text as NSString).substring(with: $0.range.nsRange).hasPrefix("He had") })
        let map = try KOReaderPositionMap(bundle: bundle)

        // Habla → device: reader numbering. <abbr> closed once before the text → text()[2];
        // offset counts the raw "\n      " the display collapsed to one space.
        let xp = try XCTUnwrap(map.xpointer(chapter: 2, sentence: second.id))
        let raw = "\u{00A0}Bennet was among the earliest\n      of those who waited. "
        XCTAssertTrue(xp.hasSuffix("/p[2]/text()[2].\(raw.unicodeScalars.count)"), xp)

        // Device → Habla: writer numbering (same node here = 1st non-empty run) with raw offsets.
        XCTAssertEqual(map.position(for: xp.replacingOccurrences(of: "text()[2]", with: "text()[1]"))?.sentence, second.id)
    }
}

final class VoiceSwitchTests: XCTestCase {
    func testSwitchingVoiceKeepsOldAudioUntilReplaced() async throws {
        let dir = Fixtures.tempDir()
        let bundle = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: dir), into: dir)
        let p = RenderPipeline(engine: ToneEngine(), cacheDirectory: dir.appendingPathComponent(".c"))
        let a = VoiceInfo(engine: "tone", voiceID: "a"), b = VoiceInfo(engine: "tone", voiceID: "b")
        try await p.render(bundle, voice: a)
        // Switch to voice b but only get through chapter 1 (as if paused/cancelled).
        try await p.render(bundle, voice: b, only: [1])
        let m = try bundle.manifest()
        XCTAssertEqual(m.chapters[1].voiceID, "b")
        XCTAssertEqual(m.chapters[2].audioStatus, .ready, "old narration stays playable")
        XCTAssertEqual(m.chapters[2].voiceID, "a")
        XCTAssertEqual(m.chaptersToNarrate(voiceID: "b").map(\.index), [2])
        try await p.render(bundle, voice: b)
        XCTAssertTrue(try bundle.manifest().chaptersToNarrate(voiceID: "b").isEmpty)
    }
}

final class HitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var hits = 0, misses = 0
    func add(_ hit: Bool) { lock.withLock { if hit { hits += 1 } else { misses += 1 } } }
}

final class SyncTests: XCTestCase {
    func testServerClientRoundTrip() async throws {
        let mac = Fixtures.tempDir(), phone = Fixtures.tempDir()
        let bundle = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: mac), into: mac)
        try await RenderPipeline(engine: ToneEngine(), cacheDirectory: mac.appendingPathComponent("c"))
            .render(bundle, voice: VoiceInfo(engine: "tone", voiceID: "tone"))
        let id = try bundle.manifest().id

        let server = LibraryServer(library: mac, progress: ProgressStore(fileURL: mac.appendingPathComponent("p.json")),
                                   accessToken: "secret")
        let port = try await server.start(port: 0, advertise: false)
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!

        // Wrong token is refused.
        do { _ = try await SyncClient(baseURL: base, accessToken: "nope").library(); XCTFail("expected 401") }
        catch { XCTAssertEqual(error as? SyncError, .notPaired) }

        let client = SyncClient(baseURL: base, accessToken: "secret")
        let lib = try await client.library()
        XCTAssertEqual(lib.map(\.id), [id])

        let first = try await client.syncBook(id, into: phone)
        XCTAssertGreaterThan(first.filesDownloaded, 3)
        let local = BookBundle(url: BookBundle.url(for: id, in: phone))
        XCTAssertEqual(try local.manifest(), try bundle.manifest())
        XCTAssertEqual(try Data(contentsOf: local.fileURL("audio/ch001.m4a")),
                       try Data(contentsOf: bundle.fileURL("audio/ch001.m4a")))

        let second = try await client.syncBook(id, into: phone)
        XCTAssertTrue(second.upToDate, "unchanged book downloads nothing")

        // Progress: newest wins on both sides.
        let phoneStore = ProgressStore(fileURL: phone.appendingPathComponent("p.json"))
        phoneStore.merge(ReadingPosition(bookID: id, chapter: 1, sentence: 3, mode: .reading,
                                         updatedAt: Date(timeIntervalSinceNow: -60), deviceID: "phone"))
        _ = try await client.push(ReadingPosition(bookID: id, chapter: 2, sentence: 1, mode: .listening, deviceID: "mac"))
        try await client.syncProgress(phoneStore)
        XCTAssertEqual(phoneStore.position(for: id)?.chapter, 2)
        XCTAssertEqual(server.progress.position(for: id)?.deviceID, "mac")
    }

    func testServerSurvivesBadRequestsAndPhoneRepairsDamage() async throws {
        let mac = Fixtures.tempDir(), phone = Fixtures.tempDir()
        let bundle = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: mac), into: mac)
        try await RenderPipeline(engine: ToneEngine(), cacheDirectory: mac.appendingPathComponent(".c"))
            .render(bundle, voice: VoiceInfo(engine: "tone", voiceID: "tone"))
        let id = try bundle.manifest().id
        let server = LibraryServer(library: mac, progress: ProgressStore(fileURL: mac.appendingPathComponent(".p.json")))
        let port = try await server.start(port: 0, advertise: false)
        defer { server.stop() }

        // Negative Content-Length used to crash the whole server.
        let conn = try await rawSend(port: port, "PUT /v1/progress HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n{}")
        XCTAssertTrue(conn.hasPrefix("HTTP/1.1 4"), conn)
        let client = SyncClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        _ = try await client.library()   // still alive

        try await client.syncBook(id, into: phone)
        let local = BookBundle(url: BookBundle.url(for: id, in: phone))
        let audio = local.fileURL("audio/ch001.m4a")
        let good = try Data(contentsOf: audio)
        // Truncated file: repaired by a normal sync (size check).
        try Data(good.prefix(100)).write(to: audio)
        try await client.syncBook(id, into: phone)
        XCTAssertEqual(try Data(contentsOf: audio), good)
        // Same-size corruption: repaired by a verifying sync.
        var bad = good; bad[bad.count / 2] ^= 0xFF
        try bad.write(to: audio)
        try await client.syncBook(id, into: phone, verify: true)
        XCTAssertEqual(try Data(contentsOf: audio), good)

        // Unknown books are acknowledged but never stored or handed out.
        _ = try await client.push(ReadingPosition(bookID: "nope", chapter: 1, sentence: 1, mode: .reading, deviceID: "x"))
        XCTAssertNil(server.progress.position(for: "nope"))
        // Sub-second ordering survives the wire.
        let t = Date()
        _ = try await client.push(ReadingPosition(bookID: id, chapter: 2, sentence: 0, mode: .reading, updatedAt: t.addingTimeInterval(0.9), deviceID: "a"))
        let w = try await client.push(ReadingPosition(bookID: id, chapter: 1, sentence: 0, mode: .reading, updatedAt: t.addingTimeInterval(0.5), deviceID: "b"))
        XCTAssertEqual(w.chapter, 2, "the newer position wins even within the same second")
    }

    func rawSend(port: UInt16, _ text: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            c.start(queue: .global())
            c.send(content: Data(text.utf8), completion: .contentProcessed { _ in
                c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { d, _, _, _ in
                    cont.resume(returning: String(decoding: d ?? Data(), as: UTF8.self)); c.cancel()
                }
            })
        }
    }

    func testArchiveRoundTrip() throws {
        let dir = Fixtures.tempDir(), dest = Fixtures.tempDir()
        let bundle = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: dir), into: dir)
        let imported = try BookBundle.importArchive(bundle.exportArchive(), into: dest)
        XCTAssertEqual(try imported.manifest(), try bundle.manifest())
    }

    func testProgressStoreSurvivesBadEntries() throws {
        let dir = Fixtures.tempDir(), f = dir.appendingPathComponent("p.json")
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
        try Data("""
        {"good":{"bookID":"good","chapter":3,"sentence":4,"mode":"reading","updatedAt":"2026-11-22T01:00:00Z","deviceID":"x"},
         "bad":{"bookID":"bad","chapter":1,"updatedAt":"yesterday"},
         "ahead":{"bookID":"ahead","chapter":2,"sentence":0,"mode":"reading","updatedAt":"\(future)","deviceID":"y"}}
        """.utf8).write(to: f)
        let store = ProgressStore(fileURL: f)
        XCTAssertEqual(store.position(for: "good")?.chapter, 3, "one bad entry must not wipe the rest")
        XCTAssertNil(store.position(for: "bad"))
        XCTAssertLessThanOrEqual(store.position(for: "ahead")!.updatedAt, Date(), "future clocks are clamped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("p.damaged.json").path))
        store.merge(ReadingPosition(bookID: "ahead", chapter: 5, sentence: 0, mode: .listening, deviceID: "z"))
        XCTAssertEqual(store.position(for: "ahead")?.chapter, 5, "a newer real position wins over the clamped one")
    }

    func testPositionMerge() {
        let old = ReadingPosition(bookID: "b", chapter: 5, sentence: 0, mode: .reading,
                                  updatedAt: Date(timeIntervalSince1970: 0), deviceID: "a")
        let new = ReadingPosition(bookID: "b", chapter: 1, sentence: 0, mode: .listening,
                                  updatedAt: Date(timeIntervalSince1970: 10), deviceID: "b")
        XCTAssertEqual(ReadingPosition.merge(old, new), new, "latest wins even if earlier in the book")
    }
}

final class KOReaderTests: XCTestCase {
    func testXPointerRoundTripAndTolerance() throws {
        let dir = Fixtures.tempDir()
        let bundle = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: dir), into: dir)
        let map = try KOReaderPositionMap(bundle: bundle)
        let m = try bundle.manifest()

        // Every sentence → XPointer → same sentence.
        for ch in m.chapters {
            for s in 0..<ch.sentenceCount {
                let xp = try XCTUnwrap(map.xpointer(chapter: ch.index, sentence: s))
                XCTAssertTrue(xp.hasPrefix("/body/DocFragment["), xp)
                let back = try XCTUnwrap(map.position(for: xp), xp)
                XCTAssertEqual(back.chapter, ch.index, xp)
                XCTAssertEqual(back.sentence, s, xp)
            }
        }

        let xp = try XCTUnwrap(map.xpointer(chapter: 1, sentence: 1))
        // Newer crengine writes [1] on single steps.
        let withOnes = xp.replacingOccurrences(of: "/body/DocFragment", with: "/body[1]/DocFragment")
            .replacingOccurrences(of: "/section/", with: "/section[1]/")
        XCTAssertEqual(map.position(for: withOnes)?.sentence, 1)
        // Firmware format: every step indexed, text()[k].offset.
        XCTAssertTrue(xp.contains("/section[1]/p[") && xp.contains("/text()["), xp)
        // "It was 1813, and Mr. Darcy was <em>not</em> amused. He had $5…": the device points into the
        // text node AFTER the <em> (text()[2] of the <p>) → must land on the 2nd sentence, not the 1st.
        let ch1 = try bundle.chapterText(m.chapters[1])
        let para = try XCTUnwrap(ch1.blocks.first { $0.text.hasPrefix("It was") })
        let p = KOReaderPositionMap.indexed(para.source.xpointer)
        let second = try XCTUnwrap(para.sentences.dropFirst().first)
        let afterEm = (para.text as NSString).range(of: " amused.").location
        let offsetInNode2 = second.range.location - afterEm
        XCTAssertEqual(map.position(for: "\(p)/text()[2].\(offsetInNode2)")?.sentence, second.id)
        XCTAssertEqual(map.position(for: "\(p)/em[1]/text()[1].1")?.sentence, para.sentences[0].id)
        // KOReader's older text().N form still works.
        XCTAssertEqual(map.position(for: "\(para.source.xpointer)/text().0")?.sentence, para.sentences[0].id)
        // Drift: a paragraph index past the end of the section → last block, not nil.
        XCTAssertNotNil(map.position(for: "/body/DocFragment[2]/body/section/p[99]/text().0"))
        // Unknown section → nil (never guess the chapter from percentage).
        XCTAssertNil(map.position(for: "/body/DocFragment[42]/body/p/text().0"))
    }

    func testKOSyncAndOPDS() async throws {
        let mac = Fixtures.tempDir()
        let bundle = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: mac), into: mac)
        let m = try bundle.manifest()
        let server = LibraryServer(library: mac, progress: ProgressStore(fileURL: mac.appendingPathComponent("p.json")))
        server.koreaderKeyMD5 = KOReaderDigest.filename("secret")   // MD5("secret")
        let port = try await server.start(port: 0, advertise: false)
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!

        func request(_ method: String, _ path: String, _ body: [String: Any]? = nil, key: String? = "secret") async throws -> (Int, [String: Any]) {
            var r = URLRequest(url: base.appendingPathComponent(path))
            r.httpMethod = method
            r.setValue("application/vnd.koreader.v1+json", forHTTPHeaderField: "Accept")
            r.setValue("reader", forHTTPHeaderField: "x-auth-user")
            if let key { r.setValue(KOReaderDigest.filename(key), forHTTPHeaderField: "x-auth-key") }
            if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
            let (data, resp) = try await URLSession.shared.data(for: r)
            return ((resp as! HTTPURLResponse).statusCode, (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        }

        let (badAuth, _) = try await request("GET", "users/auth", key: "wrong")
        XCTAssertEqual(badAuth, 401)
        let (auth, authBody) = try await request("GET", "users/auth")
        XCTAssertEqual(auth, 200); XCTAssertEqual(authBody["authorized"] as? String, "OK")

        // Device pushes a position using CrossPoint's default file-name document id.
        let doc = try XCTUnwrap(m.koreaderFilenameDigest)
        let xp = try XCTUnwrap(KOReaderPositionMap(bundle: bundle).xpointer(chapter: 2, sentence: 1))
        let (put, _) = try await request("PUT", "syncs/progress",
                                         ["document": doc, "progress": xp, "percentage": 0.8, "device": "Xteink X4", "device_id": "x4"])
        XCTAssertEqual(put, 200)
        let stored = try XCTUnwrap(server.progress.position(for: m.id))
        XCTAssertEqual(stored.chapter, 2); XCTAssertEqual(stored.sentence, 1)
        XCTAssertEqual(stored.deviceID, "koreader:Xteink X4")

        // The phone moves on; the device pulls by partial-MD5 id (Binary mode) and gets an XPointer.
        server.progress.merge(ReadingPosition(bookID: m.id, chapter: 1, sentence: 2, mode: .listening, deviceID: "iphone"))
        let (get, got) = try await request("GET", "syncs/progress/\(m.koreaderDigest)")
        XCTAssertEqual(get, 200)
        let pointer = try XCTUnwrap(got["progress"] as? String)
        XCTAssertEqual(try KOReaderPositionMap(bundle: bundle).position(for: pointer)?.sentence, 2)

        // Unknown book: empty object, still 200 (device sync queues must not stall).
        let (unknown, empty) = try await request("GET", "syncs/progress/ffffffffffffffffffffffffffffffff")
        XCTAssertEqual(unknown, 204, "CrossPoint treats 204 as 'no progress yet'"); XCTAssertTrue(empty.isEmpty)

        // Optimised copy on the device (fingerprint changed): matched by the metadata it sends.
        let (put2, _) = try await request("PUT", "syncs/progress",
            ["document": "0123456789abcdef0123456789abcdef", "progress": xp, "percentage": 0.5, "device": "Xteink X4",
             "metadata": ["title": "A Test Novel", "authors": "Ada Writer", "filename": "Writer - A Test Novel.epub"]])
        XCTAssertEqual(put2, 200)
        XCTAssertEqual(server.progress.position(for: m.id)?.deviceID, "koreader:Xteink X4")

        // OPDS lists the original and serves it byte-for-byte.
        let (feed, _) = try await URLSession.shared.data(from: base.appendingPathComponent("opds"))
        let xml = String(decoding: feed, as: UTF8.self)
        XCTAssertTrue(xml.contains("A Test Novel") && xml.contains("application/epub+zip"))
        let (epub, resp) = try await URLSession.shared.data(from: base.appendingPathComponent("opds/books/\(m.id).epub"))
        XCTAssertEqual(epub, Fixtures.sampleEPUB())
        XCTAssertEqual((resp as! HTTPURLResponse).statusCode, 200)
    }
}

final class XteinkTests: XCTestCase {
    func testDeviceFileNamesAreSafe() {
        let nasty = "Who's Afraid? “Quotes” / Slash: Colon * Star <tag> | pipe\u{0007}... " + String(repeating: "Ä", count: 120) + " 😀."
        let name = BookImporter.deviceFileName(title: nasty, id: "abcdef1234567890")
        XCTAssertLessThanOrEqual(name.utf8.count, 100)
        XCTAssertTrue(name.hasSuffix("-abcdef12.epub"))
        XCTAssertNil(name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)))
        XCTAssertEqual(BookImporter.deviceFileName(title: "  ...  ", id: "abcdef12"), "Book-abcdef12.epub")
    }

    func testDiscoverConfigureAndPushWithoutDuplicates() async throws {
        let fake = FakeCrossPoint()
        let ports = try await fake.start()
        defer { fake.stop() }

        let found = await CrossPointDevice.discover(timeout: 0.8, targets: ["127.0.0.1"],
                                                     discoveryPort: ports.udp, httpPort: Int(ports.http))
        let device = try XCTUnwrap(found.first)
        XCTAssertEqual(device.host, "127.0.0.1")
        let status = try await device.status()
        XCTAssertEqual(status.device, "X4")

        let lib = Fixtures.tempDir()
        try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: lib), into: lib)
        let sync = XteinkSync(device: device)

        // One-time setup: sync settings + OPDS feed, idempotent.
        let mac = URL(string: "http://192.168.1.20:8787")!
        try await sync.configure(macBaseURL: mac, username: "habla", password: "pw")
        try await sync.configure(macBaseURL: mac, username: "habla", password: "pw")
        XCTAssertEqual(fake.settings["koServerUrl"] as? String, "http://192.168.1.20:8787")
        XCTAssertEqual(fake.settings["koSyncOnSleep"] as? Int, 1)
        XCTAssertEqual(fake.settings["koMatchMethod"] as? Int, 1)
        XCTAssertEqual(fake.opds.count, 1, "OPDS server added once")

        // Push: folder created, original EPUB delivered byte-for-byte, second push sends nothing.
        let first = try await sync.pushBooks(from: lib)
        XCTAssertEqual(first.sent, ["A Test Novel"])
        XCTAssertTrue(fake.folders.contains("/Habla"))
        let delivered = try XCTUnwrap(fake.files.first { $0.key.hasPrefix("/Habla/A Test Novel-") })
        XCTAssertEqual(delivered.value, Fixtures.sampleEPUB())
        let second = try await sync.pushBooks(from: lib)
        XCTAssertTrue(second.sent.isEmpty); XCTAssertEqual(second.alreadyThere, ["A Test Novel"])

        // A truncated earlier copy is replaced in place (overwrite=1), verified by size.
        fake.files[delivered.key] = Data("partial".utf8)
        let third = try await sync.pushBooks(from: lib)
        XCTAssertEqual(third.sent, ["A Test Novel"])
        XCTAssertEqual(fake.files[delivered.key], Fixtures.sampleEPUB())

        // The Mac's address changed: the same catalog entry is updated, never duplicated.
        try await sync.configure(macBaseURL: URL(string: "http://192.168.1.33:8787")!, username: "habla", password: "pw")
        XCTAssertEqual(fake.opds.count, 1)
        XCTAssertEqual(fake.opds[0]["url"] as? String, "http://192.168.1.33:8787/opds")
        // A full catalog list never blocks setup.
        for i in 0..<7 { fake.opds.append(["index": fake.opds.count, "name": "Other \(i)", "url": "http://x/\(i)"]) }
        fake.opds.remove(at: 0)
        try await sync.configure(macBaseURL: URL(string: "http://192.168.1.44:8787")!, username: "habla", password: "pw")
        XCTAssertEqual(fake.settings["koServerUrl"] as? String, "http://192.168.1.44:8787")
    }

    func testAppUpdateParsesGitHubRelease() {
        let json = """
        {"tag_name":"build-12","name":"Habla 1.12","body":"Fix reader","draft":false,"prerelease":false,
         "assets":[{"name":"Habla.ipa","browser_download_url":"https://github.com/mmejiaxyz/Habla/releases/download/build-12/Habla.ipa"},
                   {"name":"Habla-Studio.zip","browser_download_url":"https://github.com/mmejiaxyz/Habla/releases/download/build-12/Habla-Studio.zip"}]}
        """
        let u = AppUpdate.parse(Data(json.utf8))
        XCTAssertEqual(u?.build, 12)
        XCTAssertEqual(u?.version, "Habla 1.12")
        XCTAssertNotNil(u?.assets["Habla-Studio.zip"])
        XCTAssertNil(AppUpdate.parse(Data(#"{"tag_name":"v1","assets":[]}"#.utf8)))
        XCTAssertNil(AppUpdate.parse(Data(#"{"tag_name":"build-3","draft":true,"assets":[]}"#.utf8)))
        XCTAssertNil(AppUpdate.parse(Data("not json".utf8)))
    }

    func testPhoneSendsBookToMac() async throws {
        let root = Fixtures.tempDir()
        let mac = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        let server = LibraryServer(library: mac, progress: ProgressStore(fileURL: root.appendingPathComponent("p.json")))
        let got = Locked<[URL]>([])
        server.onInbox = { url in got.mutate { $0.append(url) } }
        let port = try await server.start(port: 0, advertise: false)
        defer { server.stop() }
        let client = SyncClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let epub = Fixtures.writeSampleEPUB(to: root)
        let id = try await client.sendBook(epub, filename: "A Test Novel.epub")
        XCTAssertEqual(id, try DocumentDigest.sha256Prefix(of: epub))
        let saved = try XCTUnwrap(got.value.first)
        XCTAssertEqual(saved.lastPathComponent, "A Test Novel.epub")
        XCTAssertEqual(try Data(contentsOf: saved), try Data(contentsOf: epub))
        // Once imported, sending again is a no-op.
        _ = try BookImporter().importEPUB(at: saved, into: mac)
        try await client.sendBook(epub)
        XCTAssertEqual(got.value.count, 1)
        // A corrupted upload is refused.
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/inbox/0123456789abcdef")!)
        r.httpMethod = "PUT"; r.httpBody = Data("junk".utf8); r.setValue("00", forHTTPHeaderField: "X-Habla-SHA256")
        let (_, resp) = try await URLSession.shared.data(for: r)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 422)
    }

    /// Pairing over TLS: nothing without pairing, codes are single-use and bound to the
    /// certificate, pins and forgotten devices are enforced.
    func testPairingKeepsOtherDevicesOut() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("needs macOS 15") }
        let root = Fixtures.tempDir()
        let mac = root.appendingPathComponent("Library")
        _ = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: root), into: mac)
        let server = LibraryServer(library: mac, progress: ProgressStore(fileURL: root.appendingPathComponent("p.json")), serviceName: "Habla on Test Mac")
        let tls = try TLSIdentity.loadOrCreate(in: root.appendingPathComponent("Security"))
        server.tlsIdentity = tls.identity; server.tlsFingerprint = tls.fingerprint
        let registry = DeviceRegistry(fileURL: root.appendingPathComponent("devices.json"))
        let window = PairingWindow()
        server.registry = registry; server.pairing = window; server.libraryID = "lib1"; server.allowEReaders = false
        let port = try await server.start(port: 0, advertise: false)
        defer { server.stop() }
        let url = URL(string: "https://127.0.0.1:\(port)")!

        // A second load reuses the same certificate (the iPhone's pin stays valid).
        XCTAssertEqual(try TLSIdentity.loadOrCreate(in: root.appendingPathComponent("Security")).fingerprint, tls.fingerprint)

        // Stranger: sees only the hello.
        let trust = PinnedTrust(fingerprint: nil)
        let stranger = SyncClient(baseURL: url, session: trust.session())
        let hello = try await stranger.hello()
        XCTAssertEqual(hello.libraryID, "lib1"); XCTAssertEqual(hello.pairing, true)
        XCTAssertEqual(trust.seen, tls.fingerprint)
        do { _ = try await stranger.library(); XCTFail("library must need pairing") } catch { XCTAssertEqual(error as? SyncError, .notPaired) }
        let bogus = SyncClient(baseURL: url, accessToken: "guess", session: trust.session())
        do { _ = try await bogus.library(); XCTFail("guessed token accepted") } catch { XCTAssertEqual(error as? SyncError, .notPaired) }
        // No e-reader routes while the Xteink feature is off.
        let (_, opds) = try await trust.session().data(from: url.appendingPathComponent("opds"))
        XCTAssertEqual((opds as? HTTPURLResponse)?.statusCode, 401)

        // No code open → pairing fails.
        do { _ = try await stranger.pair(code: "AAAAA-AAAAA", fingerprint: tls.fingerprint, deviceID: "x", deviceName: "x"); XCTFail("paired without a code") } catch {}

        let code = window.open()
        // A relay presents its own certificate: a proof made with that fingerprint is refused.
        do { _ = try await stranger.pair(code: code, fingerprint: String(repeating: "a", count: 64), deviceID: "p1", deviceName: "Phone"); XCTFail("relayed proof accepted") } catch {}
        // The right code, typed sloppily, works once.
        let typed = code.lowercased().replacingOccurrences(of: "-", with: " ")
        let paired = try await stranger.pair(code: typed, fingerprint: tls.fingerprint, deviceID: "p1", deviceName: "Phone")
        XCTAssertEqual(paired.libraryID, "lib1")
        do { _ = try await stranger.pair(code: code, fingerprint: tls.fingerprint, deviceID: "p2", deviceName: "Other"); XCTFail("code reused") } catch {}

        // Paired + pinned: full access.
        let phone = SyncClient(baseURL: url, accessToken: paired.token, session: PinnedTrust(fingerprint: tls.fingerprint).session())
        let books = try await phone.library()
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(registry.all.map(\.name), ["Phone"])
        // Same token, wrong pin (another machine answering at that address): the phone refuses it.
        let wrongPin = SyncClient(baseURL: url, accessToken: paired.token, session: PinnedTrust(fingerprint: String(repeating: "b", count: 64)).session())
        do { _ = try await wrongPin.library(); XCTFail("wrong certificate accepted") } catch {}

        // Five wrong guesses close the window.
        let code2 = window.open()
        for _ in 0..<5 { _ = try? await stranger.pair(code: "ZZZZZ-ZZZZZ", fingerprint: tls.fingerprint, deviceID: "p3", deviceName: "x") }
        do { _ = try await stranger.pair(code: code2, fingerprint: tls.fingerprint, deviceID: "p3", deviceName: "x"); XCTFail("window should be closed") } catch {}

        // Forgotten on the Mac → locked out.
        registry.forget("p1")
        do { _ = try await phone.library(); XCTFail("forgotten device still in") } catch { XCTAssertEqual(error as? SyncError, .notPaired) }
        // Tokens are stored only as hashes.
        let disk = try String(contentsOf: root.appendingPathComponent("devices.json"), encoding: .utf8)
        XCTAssertFalse(disk.contains(paired.token))
    }

    /// Real-size transfer over TLS on the Wi-Fi address (not loopback). Opt-in:
    /// HABLA_STRESS_LIBRARY=<a Habla library folder> swift test --filter testLargeBookOverTLS
    func testLargeBookOverTLS() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("needs macOS 15") }
        guard let libPath = ProcessInfo.processInfo.environment["HABLA_STRESS_LIBRARY"] else { throw XCTSkip("set HABLA_STRESS_LIBRARY") }
        guard let ip = LocalNetwork.primaryIPv4() else { throw XCTSkip("no Wi-Fi address") }
        let lib = URL(fileURLWithPath: libPath)
        let root = Fixtures.tempDir()
        let server = LibraryServer(library: lib, progress: ProgressStore(fileURL: root.appendingPathComponent("p.json")))
        let tls = try TLSIdentity.loadOrCreate(in: root.appendingPathComponent("Security"))
        server.tlsIdentity = tls.identity; server.tlsFingerprint = tls.fingerprint
        server.registry = DeviceRegistry(fileURL: root.appendingPathComponent("d.json"))
        let window = PairingWindow(); server.pairing = window; server.libraryID = "stress"
        let port = try await server.start(port: 0, advertise: false)
        defer { server.stop() }
        let url = URL(string: "https://\(ip):\(port)")!
        let trust = PinnedTrust(fingerprint: tls.fingerprint)
        let pair = try await SyncClient(baseURL: url, session: trust.session()).pair(code: window.open(), fingerprint: tls.fingerprint, deviceID: "s", deviceName: "stress")
        let client = SyncClient(baseURL: url, accessToken: pair.token, session: trust.session())
        let books = try await client.library().sorted { $0.totalBytes > $1.totalBytes }
        let book = try XCTUnwrap(books.first)
        let t0 = Date()
        let summary = try await client.syncBook(book.id, into: root.appendingPathComponent("Phone"))
        let dt = Date().timeIntervalSince(t0)
        print("STRESS \(book.title): \(summary.filesDownloaded) files, \(summary.bytesDownloaded / 1_000_000) MB in \(String(format: "%.1f", dt)) s")
        XCTAssertGreaterThan(summary.filesDownloaded, 0)
    }

    func testPairingInviteRoundTrip() {
        let inv = PairingInvite(libraryID: "abc", name: "Habla on Mac", address: "192.168.1.2:8787",
                                fingerprint: String(repeating: "c", count: 64), code: "ABCDE-FGH12")
        XCTAssertEqual(PairingInvite(url: inv.url), inv)
        XCTAssertNil(PairingInvite(url: URL(string: "habla://pair?id=x")!))
        XCTAssertEqual(Pairing.normalize("abcde fgh-iO"), "ABCDEFGH10")
        XCTAssertEqual(Pairing.newCode().count, 11)
    }

    /// Parallel workers answering out of order still produce an in-order chapter.
    func testEnginePoolKeepsSentenceOrder() async throws {
        struct Jittery: TTSEngine {
            let name = "tone"; let cacheVersion = "tone-1"
            func voices() async throws -> [String] { ["tone"] }
            func synthesize(_ text: String, voice: VoiceInfo) async throws -> SpeechAudio {
                try await Task.sleep(nanoseconds: UInt64.random(in: 1...30) * 1_000_000)
                return try await ToneEngine().synthesize(text, voice: voice)
            }
        }
        let root = Fixtures.tempDir()
        let bundle = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: root), into: root.appendingPathComponent("lib"))
        let pool = EnginePool([Jittery(), Jittery(), Jittery()])
        let pipeline = RenderPipeline(engine: pool, cacheDirectory: root.appendingPathComponent("cache"))
        XCTAssertEqual(pipeline.lookahead, 4)
        try await pipeline.render(bundle, voice: VoiceInfo(engine: "tone", voiceID: "tone"))
        let m = try bundle.manifest()
        for info in m.chapters where info.audioStatus == .ready {
            let timing = try JSON.decoder.decode(ChapterTiming.self, from: Data(contentsOf: bundle.fileURL(info.timingFile!)))
            XCTAssertEqual(timing.sentences.map(\.id), timing.sentences.map(\.id).sorted())
            XCTAssertEqual(timing.sentences.map(\.start), timing.sentences.map(\.start).sorted())
        }
        XCTAssertGreaterThan(m.chapters.filter { $0.audioStatus == .ready }.count, 0)
    }

    /// A port held by another program (or a copy still quitting) never stops sharing.
    func testServerFallsBackWhenPortIsTaken() async throws {
        let root = Fixtures.tempDir()
        let a = LibraryServer(library: root, progress: ProgressStore(fileURL: root.appendingPathComponent("a.json")))
        let port = try await a.start(port: 0, advertise: false)
        defer { a.stop() }
        let b = LibraryServer(library: root, progress: ProgressStore(fileURL: root.appendingPathComponent("b.json")))
        let other = try await b.start(port: port, advertise: false, retries: 1)
        defer { b.stop() }
        XCTAssertNotEqual(other, port)
        let hello = try await SyncClient(baseURL: URL(string: "http://127.0.0.1:\(other)")!).hello()
        XCTAssertEqual(hello.version, String(SyncProtocol.version))
    }
}

final class Locked<T>: @unchecked Sendable {
    private var v: T; private let l = NSLock()
    init(_ v: T) { self.v = v }
    var value: T { l.withLock { v } }
    func mutate(_ f: (inout T) -> Void) { l.withLock { f(&v) } }
}
