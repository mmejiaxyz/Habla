import XCTest
@testable import HablaCore

/// Regression tests for the problems found in the November 2026 user-testing round.
final class UserTestingRegressionTests: XCTestCase {

    // MARK: Voice engine

    /// A worker that never says "ready" (damaged model, stuck disk) must not block narration forever.
    func testStuckWorkerStartTimesOut() async throws {
        let dir = Fixtures.tempDir()
        let python = dir.appendingPathComponent("python")
        try "#!/bin/sh\necho 'loading forever' >&2\nsleep 60\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("worker.py").path, contents: Data())
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("hf"), withIntermediateDirectories: true)
        let engine = VoiceEngine(configuration: .init(python: python, worker: dir.appendingPathComponent("worker.py"), home: dir.appendingPathComponent("hf")))
        let old = VoiceEngine.startTimeout
        VoiceEngine.startTimeout = 1.5
        defer { VoiceEngine.startTimeout = old }
        let t0 = Date()
        do { _ = try await engine.synthesize("Hello.", voice: VoiceInfo(engine: "paradee", voiceID: "af_heart")); XCTFail("should fail") }
        catch { XCTAssertLessThan(Date().timeIntervalSince(t0), 10, "gave up in time") }
        // The log keeps what the worker said (and isn't wiped by a restart).
        do { _ = try await engine.synthesize("Again.", voice: VoiceInfo(engine: "paradee", voiceID: "af_heart")) } catch {}
        let log = try String(contentsOf: dir.appendingPathComponent("worker.log"), encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "loading forever").count - 1, 2, log)
        await engine.shutdown()
    }

    func testWorkerCountFollowsModelAndMemory() {
        let gb: UInt64 = 1_073_741_824
        XCTAssertEqual(EnginePool.recommendedWorkers(memoryBytes: 8 * gb, cores: 8), 3, "M1 Air 8 GB: three Paradee workers")
        XCTAssertEqual(EnginePool.recommendedWorkers(memoryBytes: 16 * gb, cores: 8), 4)
        XCTAssertEqual(EnginePool.recommendedWorkers(memoryBytes: 18 * gb, cores: 11), 4, "never more than four (no gain past four)")
        XCTAssertEqual(EnginePool.recommendedWorkers(memoryBytes: 8 * gb, cores: 2), 1)
    }

    /// Sentences with nothing to say still get a timing, so audio and text stay aligned.
    func testSilentSentencesKeepTheirTiming() async throws {
        let root = Fixtures.tempDir()
        let ch = Fixtures.xhtml("<h1>Emoji</h1><p>Before the stars. 🌟🌟🌟 After the stars.</p><p>★ ★ ★</p><p>The end.</p>")
        let epub = Fixtures.write(Fixtures.customEPUB(chapters: [("a.xhtml", Data(ch.utf8))], toc: ["a.xhtml"]), named: "e.epub", in: root)
        let bundle = try BookImporter().importEPUB(at: epub, into: root.appendingPathComponent("lib"))
        try await RenderPipeline(engine: ToneEngine(), cacheDirectory: root.appendingPathComponent("c"))
            .render(bundle, voice: VoiceInfo(engine: "tone", voiceID: "tone"))
        let m = try bundle.manifest()
        let info = try XCTUnwrap(m.chapters.first { $0.audioStatus == .ready })
        let timing = try JSON.decoder.decode(ChapterTiming.self, from: Data(contentsOf: bundle.fileURL(info.timingFile!)))
        XCTAssertEqual(timing.sentences.map(\.id), Array(0..<info.sentenceCount), "every sentence has a timing")
    }

    // MARK: Import

    func testLatin1AndUTF16ChaptersAreReadable() throws {
        let root = Fixtures.tempDir()
        let latin1 = """
        <?xml version="1.0" encoding="ISO-8859-1"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Café</h1><p>Señor Müller aß ein Stück Kuchen. Voilà, très bien.</p></body></html>
        """.data(using: .isoLatin1)!
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("""
        <?xml version="1.0" encoding="UTF-16"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Zwei</h1><p>Grüße aus Köln, sagte sie. Es war schön.</p></body></html>
        """.data(using: .utf16LittleEndian)!)
        let epub = Fixtures.write(Fixtures.customEPUB(chapters: [("a.xhtml", latin1), ("b.xhtml", utf16)], toc: ["a.xhtml", "b.xhtml"]),
                                  named: "enc.epub", in: root)
        let bundle = try BookImporter().importEPUB(at: epub, into: root.appendingPathComponent("lib"))
        let m = try bundle.manifest()
        let all = try m.chapters.map { try bundle.chapterText($0).blocks.map(\.text).joined(separator: " ") }.joined(separator: " ")
        XCTAssertTrue(all.contains("Señor Müller aß ein Stück Kuchen"), all)
        XCTAssertTrue(all.contains("Grüße aus Köln"), all)
        XCTAssertFalse(all.contains("<p>") || all.contains("\u{FFFD}"), all)
    }

    func testSplitChapterContinuationIsNarrated() throws {
        let root = Fixtures.tempDir()
        let one = Fixtures.xhtml("<h1>Chapter One</h1><p>It began on a Tuesday, as these things do.</p>")
        let oneB = Fixtures.xhtml("<p>And it went on into the night, long after the lamps were lit.</p>")
        let two = Fixtures.xhtml("<h1>Chapter Two</h1><p>Morning came.</p>")
        let epub = Fixtures.write(Fixtures.customEPUB(chapters: [("1.xhtml", Data(one.utf8)), ("1b.xhtml", Data(oneB.utf8)), ("2.xhtml", Data(two.utf8))],
                                                      toc: ["1.xhtml", "2.xhtml"]), named: "split.epub", in: root)
        let m = try BookImporter().importEPUB(at: epub, into: root.appendingPathComponent("lib")).manifest()
        XCTAssertEqual(m.chapters.count, 2, "the continuation joins chapter one")
        XCTAssertTrue(try BookBundle(url: BookBundle.url(for: m.id, in: root.appendingPathComponent("lib"))).chapterText(m.chapters[0])
            .blocks.contains { $0.text.contains("long after the lamps") })
        XCTAssertTrue(m.chapters.allSatisfy { !$0.isFrontMatter })
    }

    func testShortUntitledBookIsNotFrontMatter() throws {
        let root = Fixtures.tempDir()
        let story = Fixtures.xhtml("<p>The cat sat by the window all afternoon. Nobody came. It did not mind.</p>")
        let epub = Fixtures.write(Fixtures.customEPUB(title: "A Very Short Story", chapters: [("s.xhtml", Data(story.utf8))], toc: []),
                                  named: "short.epub", in: root)
        let m = try BookImporter().importEPUB(at: epub, into: root.appendingPathComponent("lib")).manifest()
        XCTAssertEqual(m.chapters.count, 1)
        XCTAssertFalse(m.chapters[0].isFrontMatter, "a short book is the story, not front matter")
        XCTAssertEqual(m.chapters[0].audioStatus, .pending)
        XCTAssertEqual(m.chapters[0].title, "A Very Short Story")
    }

    func testImageOnlyBookIsRefusedWithAReason() throws {
        let root = Fixtures.tempDir()
        let page = Fixtures.xhtml("<div><img src=\"p1.jpg\" alt=\"\"/></div>")
        let epub = Fixtures.write(Fixtures.customEPUB(chapters: [("p.xhtml", Data(page.utf8))], toc: ["p.xhtml"]), named: "img.epub", in: root)
        XCTAssertThrowsError(try BookImporter().importEPUB(at: epub, into: root.appendingPathComponent("lib"))) { error in
            XCTAssertTrue("\(error)".contains("no text"), "\(error)")
        }
    }

    // MARK: Files and sync

    func testFileHashesAreReusedOnlyForUnchangedFiles() throws {
        let root = Fixtures.tempDir()
        let bundle = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: root), into: root.appendingPathComponent("lib"))
        var m = try bundle.manifest()
        let path = BookBundle.textPath(m.chapters[1].index)
        // Unchanged file: the recorded hash is reused (no re-hashing every commit).
        if let i = m.files.firstIndex(where: { $0.path == path }) { m.files[i].sha256 = "reused-marker" }
        m = try bundle.commit(m)
        XCTAssertEqual(m.files.first { $0.path == path }?.sha256, "reused-marker")
        // Same size, different bytes, clock moved back (commit dated in the future): re-hashed.
        let url = bundle.fileURL(path)
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 2] = bytes[bytes.count - 2] == 0x20 ? 0x0A : 0x20
        try bytes.write(to: url)
        m.updatedAt = Date().addingTimeInterval(86_400)
        m = try bundle.commit(m)
        XCTAssertEqual(m.files.first { $0.path == path }?.sha256, try BookBundle.sha256(of: url))
    }

    func testUnsafeManifestPathsAreRefused() async throws {
        let root = Fixtures.tempDir()
        let mac = root.appendingPathComponent("Mac")
        let bundle = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: root), into: mac)
        var m = try bundle.manifest()
        try Data("gotcha".utf8).write(to: bundle.fileURL("evil.txt"))
        m.files.append(FileEntry(path: "../../ESCAPED.txt", size: 6, sha256: BookBundle.sha256(of: Data("gotcha".utf8))))
        try bundle.write(m, to: BookBundle.manifestFile, pretty: true)
        let server = LibraryServer(library: mac, progress: ProgressStore(fileURL: root.appendingPathComponent("p.json")))
        let port = try await server.start(port: 0, advertise: false)
        defer { server.stop() }
        let phone = root.appendingPathComponent("Phone/Library")
        do { _ = try await SyncClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!).syncBook(m.id, into: phone); XCTFail("synced an unsafe path") }
        catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Phone/ESCAPED.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ESCAPED.txt").path))
        XCTAssertFalse(BookBundle.isSafeRelativePath("a/../b"))
        XCTAssertTrue(BookBundle.isSafeRelativePath("audio/ch001.m4a"))
    }

    func testInboxRefusesNonEPUBAndTheClientSaysWhy() async throws {
        let root = Fixtures.tempDir()
        let server = LibraryServer(library: root.appendingPathComponent("Library"), progress: ProgressStore(fileURL: root.appendingPathComponent("p.json")))
        let port = try await server.start(port: 0, advertise: false)
        defer { server.stop() }
        let junk = root.appendingPathComponent("junk.epub")
        try Data("this is not an epub at all".utf8).write(to: junk)
        do { try await SyncClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!).sendBook(junk); XCTFail("accepted junk") }
        catch SyncError.rejected {} catch { XCTFail("wrong error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.inbox.path) && !((try? FileManager.default.contentsOfDirectory(atPath: server.inbox.path)) ?? []).isEmpty)
    }

    func testEReaderRoutesAreOffUnlessAsked() {
        let s = LibraryServer(library: Fixtures.tempDir(), progress: ProgressStore(fileURL: Fixtures.tempDir().appendingPathComponent("p.json")))
        XCTAssertFalse(s.allowEReaders)
    }

    // MARK: Positions and clocks

    /// Devices with wrong clocks still converge on the Mac's answer, and a new local place
    /// always beats this device's older one (even after the clock moved back).
    func testPositionsConvergeDespiteClockSkew() async throws {
        let root = Fixtures.tempDir()
        let mac = root.appendingPathComponent("Mac")
        let bundle = try BookImporter().importEPUB(at: Fixtures.writeSampleEPUB(to: root), into: mac)
        let id = try bundle.manifest().id
        let server = LibraryServer(library: mac, progress: ProgressStore(fileURL: root.appendingPathComponent("mac.json")))
        let port = try await server.start(port: 0, advertise: false)
        defer { server.stop() }
        let client = SyncClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let fast = ProgressStore(fileURL: root.appendingPathComponent("a.json"))   // clock an hour ahead
        let slow = ProgressStore(fileURL: root.appendingPathComponent("b.json"))   // clock an hour behind

        fast.record(ReadingPosition(bookID: id, chapter: 1, sentence: 0, mode: .reading,
                                    updatedAt: Date().addingTimeInterval(3600), deviceID: "fast"))
        try await client.syncProgress(fast)
        try await client.syncProgress(slow)
        slow.record(ReadingPosition(bookID: id, chapter: 2, sentence: 5, mode: .reading,
                                    updatedAt: Date().addingTimeInterval(-3600), deviceID: "slow"))
        try await client.syncProgress(slow)
        try await client.syncProgress(fast)
        XCTAssertEqual(server.progress.position(for: id)?.chapter, 2, "the newer place wins on the Mac")
        XCTAssertEqual(fast.position(for: id)?.chapter, 2, "the fast-clock device adopts it")
        XCTAssertEqual(slow.position(for: id)?.chapter, 2)
        XCTAssertTrue(fast.pending.isEmpty && slow.pending.isEmpty)

        // Clock moved back on one device: its new place still replaces its old one.
        fast.record(ReadingPosition(bookID: id, chapter: 3, sentence: 1, mode: .listening,
                                    updatedAt: Date().addingTimeInterval(-86_400), deviceID: "fast"))
        XCTAssertEqual(fast.position(for: id)?.chapter, 3)
        try await client.syncProgress(fast)
        XCTAssertEqual(server.progress.position(for: id)?.chapter, 3)
    }
}
