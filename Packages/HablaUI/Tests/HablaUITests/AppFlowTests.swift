import XCTest
import HablaCore
@testable import HablaUI

/// App-level flows with the real stores (no UI): what the iPhone and Mac apps actually do.
@MainActor
final class AppFlowTests: XCTestCase {
    /// Pride and Prejudice (Standard Ebooks). Set HABLA_TEST_EPUB, or put it in T_epub/ (git-ignored).
    static let epub: URL = ProcessInfo.processInfo.environment["HABLA_TEST_EPUB"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../T_epub/pride-se.epub").standardizedFileURL

    /// A tiny, distinct EPUB (a copy of the test book with a different title).
    static func makeSmallEPUB(in dir: URL) throws -> URL {
        let src = try Data(contentsOf: epub)
        let out = dir.appendingPathComponent("second.epub")
        // Appending bytes after the ZIP's end keeps it readable but gives it a new identity.
        try (src + Data("habla-second-book".utf8)).write(to: out)
        return out
    }

    func temp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("habla-ui-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// A Mac library with Pride and Prejudice, chapters 1–2 narrated (fake tone voice).
    func macLibrary() async throws -> (URL, BookBundle, RenderPipeline) {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.epub.path), "test EPUB missing")
        let lib = temp()
        let b = try BookImporter().importEPUB(at: Self.epub, into: lib)
        let pipeline = RenderPipeline(engine: ToneEngine(), cacheDirectory: lib.appendingPathComponent(".cache"))
        try await pipeline.render(b, voice: VoiceInfo(engine: "tone", voiceID: "tone"), only: [1, 2])
        return (lib, b, pipeline)
    }

    func testPhoneSyncsBooksPositionsAndNewChapters() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("needs macOS 15") }
        let (lib, b, pipeline) = try await macLibrary()
        let id = try b.manifest().id
        // Secured like Habla Studio: TLS + pairing.
        let server = LibraryServer(library: lib, progress: ProgressStore(fileURL: lib.appendingPathComponent("p.json")), serviceName: "Habla on Test Mac")
        let tls = try TLSIdentity.loadOrCreate(in: temp())
        server.tlsIdentity = tls.identity; server.tlsFingerprint = tls.fingerprint
        server.registry = DeviceRegistry(fileURL: temp().appendingPathComponent("devices.json"))
        let window = PairingWindow()
        server.pairing = window; server.libraryID = "lib-\(UUID().uuidString.prefix(6))"
        let port = try await server.start(port: 0, advertise: false)
        defer { server.stop() }

        let phone = PhoneStore(root: temp())
        defer { phone.unpair() }
        // A typed address is found but not trusted until paired.
        let found = await phone.lookUp(address: "127.0.0.1:\(port)")
        XCTAssertEqual(found?.libraryID, server.libraryID)
        await phone.sync()
        XCTAssertFalse(phone.isConnected)
        await phone.pair(at: try XCTUnwrap(found).url, code: "WRONG-CODE0")
        XCTAssertNil(phone.paired)
        await phone.pair(at: try XCTUnwrap(found).url, code: window.open())
        XCTAssertEqual(phone.paired?.fingerprint, tls.fingerprint)
        XCTAssertTrue(phone.isConnected, phone.error ?? "")
        guard case .remote = phone.books.first(where: { $0.id == id })?.availability else { return XCTFail("book should be on the Mac") }

        // Download.
        let t0 = Date()
        try await phone.download(id)
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertEqual(phone.books.first { $0.id == id }?.availability, .local)
        XCTAssertLessThan(elapsed, 5, "LAN download of a 2-chapter book should be quick")
        XCTAssertEqual(phone.manifest(id)?.chapters.filter { $0.audioStatus == .ready }.count, 2)

        // Phone position reaches the Mac (coalesced push ~2 s).
        phone.savePosition(book: id, chapter: 2, sentence: 7, audioTime: 30, mode: .listening)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertEqual(server.progress.position(for: id)?.sentence, 7)

        // The Mac (or the Xteink through it) moves on → the phone adopts it on sync.
        server.progress.merge(ReadingPosition(bookID: id, chapter: 3, sentence: 2, mode: .reading, deviceID: "koreader:X4"))
        await phone.sync()
        XCTAssertEqual(phone.progress.position(for: id)?.chapter, 3)

        // The Mac narrates another chapter → the phone updates the book by itself on sync.
        try await pipeline.render(b, voice: VoiceInfo(engine: "tone", voiceID: "tone"), only: [3])
        await phone.sync()
        XCTAssertEqual(phone.books.first { $0.id == id }?.availability, .local, "stays usable while updating")
        for _ in 0..<50 where phone.manifest(id)?.chapters.filter({ $0.audioStatus == .ready }).count != 3 {
            try await Task.sleep(nanoseconds: 100_000_000)   // background update
        }
        XCTAssertEqual(phone.manifest(id)?.chapters.filter { $0.audioStatus == .ready }.count, 3)
        XCTAssertTrue(phone.updating.isEmpty)

        // A book added on the Mac shows up by itself while the app is open (no "Sync now").
        phone.startLiveUpdates(every: 0.3)
        defer { phone.stopLiveUpdates() }
        let second = try BookImporter().importEPUB(at: Self.makeSmallEPUB(in: temp()), into: lib).manifest().id
        for _ in 0..<40 where !phone.books.contains(where: { $0.id == second }) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(phone.books.contains { $0.id == second }, "new Mac book should appear without tapping Sync now")
        phone.stopLiveUpdates()

        // Mac unreachable → phone stays usable offline and says so.
        server.stop()
        await phone.sync()
        XCTAssertFalse(phone.isConnected)
        XCTAssertEqual(phone.books.first { $0.id == id }?.availability, .local)
    }

    func testWordUnderlineSurvivesRelayout() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.epub.path))
        let lib = temp().appendingPathComponent("Library")
        let b = try BookImporter().importEPUB(at: Self.epub, into: lib)
        let m = try b.manifest()
        let model = ReaderModel(bundle: b, manifest: m, chapter: 5, sentence: 40, style: ReaderStyle())
        model.setPageSize(CGSize(width: 338, height: 700))
        let layout = try XCTUnwrap(model.layout)
        // Find a word by scanning the page for a point that lands on one.
        var hit: NSRange?
        for y in stride(from: 40.0, to: 600, by: 23) where hit == nil {
            hit = layout.wordRange(at: CGPoint(x: 120, y: y), onPage: model.page)
        }
        let word = try XCTUnwrap(hit)
        let text = (layout.chapter.text.string as NSString).substring(with: word)
        XCTAssertFalse(text.isEmpty)
        XCTAssertTrue(text.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || "’'-".unicodeScalars.contains($0) }, text)
        model.addUnderline(word)
        XCTAssertEqual(model.underlineRanges(), [word])
        // Bigger text: same words underlined, from a fresh store read back from disk.
        model.style = model.style.larger()
        let again = (try XCTUnwrap(model.layout).chapter.text.string as NSString).substring(with: try XCTUnwrap(model.underlineRanges().first))
        XCTAssertEqual(again, text)
        let disk = AnnotationStore(fileURL: lib.deletingLastPathComponent().appendingPathComponent("annotations.json"))
        XCTAssertEqual(disk.underlines(book: m.id).first?.text, text)
        model.removeUnderline(try XCTUnwrap(model.underline(covering: word)))
        // "Sentence" means the whole sentence, not the shorter piece narration uses.
        let first = ReaderModel(bundle: b, manifest: m, chapter: m.chapters.first { !$0.isFrontMatter }!.index, sentence: nil, style: ReaderStyle())
        first.setPageSize(CGSize(width: 338, height: 700))
        let ns = try XCTUnwrap(first.layout).chapter.text.string as NSString
        let wife = ns.range(of: "wife.")
        let sentence = ns.substring(with: try XCTUnwrap(first.sentenceRange(around: wife.location)))
        XCTAssertTrue(sentence.hasPrefix("It is a truth"), sentence)
        XCTAssertTrue(model.underlineRanges().isEmpty)
    }

    func testFindLandsOnTheMatch() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.epub.path))
        let lib = temp()
        let b = try BookImporter().importEPUB(at: Self.epub, into: lib)
        let m = try b.manifest()
        let hits = BookFind.search("NETHERFIELD", in: b, manifest: m)
        XCTAssertGreaterThan(hits.count, 20)
        XCTAssertEqual(hits.map(\.chapter), hits.map(\.chapter).sorted(), "results in reading order")
        XCTAssertTrue(hits.allSatisfy { $0.match.lowercased() == "netherfield" })
        let model = ReaderModel(bundle: b, manifest: m, chapter: m.chapters[0].index, sentence: nil, style: ReaderStyle())
        model.setPageSize(CGSize(width: 338, height: 700))
        for hit in [hits[0], hits[hits.count / 2], hits.last!] {
            model.show(hit, query: "netherfield")
            let found = try XCTUnwrap(model.found)
            XCTAssertEqual(found.chapter, hit.chapter)
            let layout = try XCTUnwrap(model.layout)
            XCTAssertEqual((layout.chapter.text.string as NSString).substring(with: found.range).lowercased(), "netherfield")
            XCTAssertTrue(NSLocationInRange(found.range.location, layout.characterRange(ofPage: model.page)), "match is on the page shown")
        }
        XCTAssertTrue(BookFind.search("x", in: b, manifest: m).isEmpty, "one letter doesn't search")

        // Phrases typed the way people type: plain spaces (the book uses non-breaking ones in
        // "Mr. Bennet"), straight apostrophes and quotes (the book has curly ones).
        for phrase in ["mr. bennet", "Mr.  Bennet replied", "it is a truth universally acknowledged", "don't", "\"my dear mr. bennet,\""] {
            let found = BookFind.search(phrase, in: b, manifest: m)
            XCTAssertFalse(found.isEmpty, "no results for \(phrase)")
            guard let hit = found.first else { continue }
            model.show(hit, query: phrase)
            let range = try XCTUnwrap(model.found?.range, phrase)
            let layout = try XCTUnwrap(model.layout)
            let shown = (layout.chapter.text.string as NSString).substring(with: range)
            XCTAssertEqual(FoldedText(shown).chars, FoldedText.query(phrase), "highlight covers exactly “\(phrase)”, got “\(shown)”")
            XCTAssertTrue(NSLocationInRange(range.location, layout.characterRange(ofPage: model.page)))
        }
        XCTAssertGreaterThan(BookFind.search("mr. bennet", in: b, manifest: m).count, 50)
    }

    /// Long chapters keep their ending: hyphenation adds glyphs during layout, and every
    /// character must still land on a page.
    func testLongChapterPaginationCoversEverything() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.epub.path))
        let b = try BookImporter().importEPUB(at: Self.epub, into: temp())
        let m = try b.manifest()
        // One very long chapter: every chapter's paragraphs together.
        let blocks = try m.chapters.prefix(20).flatMap { try b.chapterText($0).blocks }   // ~a third of the book
        var id = 0
        let renumbered = blocks.map { block -> TextBlock in
            var bl = block
            bl.sentences = bl.sentences.map { var s = $0; s.id = id; id += 1; return s }
            return bl
        }
        var chapter = try b.chapterText(m.chapters[0])
        chapter.blocks = renumbered
        let typeset = Typesetter.set(chapter, style: ReaderStyle(fontSize: 31))
        let layout = PageLayout(chapter: typeset, pageSize: CGSize(width: 300, height: 520))
        let last = layout.characterRange(ofPage: layout.pageCount - 1)
        XCTAssertEqual(NSMaxRange(last), typeset.text.length, "the last page ends at the end of the text")
    }

    /// The iPhone keeps a book it sent until the Mac really has it.
    func testPhoneKeepsSentBookUntilTheMacHasIt() async throws {
        guard #available(macOS 15.0, *) else { throw XCTSkip("needs macOS 15") }
        let lib = temp()
        let server = LibraryServer(library: lib, progress: ProgressStore(fileURL: lib.appendingPathComponent("p.json")), serviceName: "Habla on Test Mac")
        let tls = try TLSIdentity.loadOrCreate(in: temp())
        server.tlsIdentity = tls.identity; server.tlsFingerprint = tls.fingerprint
        server.registry = DeviceRegistry(fileURL: temp().appendingPathComponent("devices.json"))
        let window = PairingWindow()
        server.pairing = window; server.libraryID = "lib-\(UUID().uuidString.prefix(6))"
        let received = Locked<[URL]>([])
        server.onInbox = { url in received.mutate { $0.append(url) } }   // a Mac that doesn't import (yet)
        let port = try await server.start(port: 0, advertise: false)
        defer { server.stop() }
        let phone = PhoneStore(root: temp())
        defer { phone.unpair() }
        await phone.pair(at: URL(string: "https://127.0.0.1:\(port)")!, code: window.open())
        XCTAssertTrue(phone.isConnected, phone.error ?? "")

        phone.importBooks([Self.epub])
        for _ in 0..<150 where received.value.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        let sent = try XCTUnwrap(received.value.first, "the book reached the Mac's inbox · error=\(phone.error ?? "none") outbox=\(phone.outbox) importing=\(phone.importing)")
        let id = try DocumentDigest.sha256Prefix(of: Self.epub)
        await phone.sync()
        XCTAssertTrue(phone.isWaitingForMac(id), "not in the Mac's library yet: still waiting")
        XCTAssertTrue(FileManager.default.fileExists(atPath: BookImporter.originalURL(for: id, in: phone.library).path), "the iPhone keeps its copy")

        _ = try BookImporter().importEPUB(at: sent, into: lib)   // the Mac imports it
        await phone.sync()
        XCTAssertFalse(phone.isWaitingForMac(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: BookImporter.originalURL(for: id, in: phone.library).path), "now the copy can go")
    }

    func testImprintRecordsTheModel() async throws {
        let (_, b, _) = try await macLibrary()
        let m = try b.manifest()
        XCTAssertEqual(m.narrationModels, ["tone"])
        XCTAssertTrue(Imprint.lines(m).first?.hasPrefix("Narrated with tone") == true, Imprint.lines(m).joined(separator: " | "))
        XCTAssertEqual(VoiceEngine(configuration: .init(toolsDirectory: temp())).modelDescription, "Paradee 1.3")
    }

    func testReaderNeverLosesThePlace() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.epub.path))
        let lib = temp()
        let b = try BookImporter().importEPUB(at: Self.epub, into: lib)
        let m = try b.manifest()
        let model = ReaderModel(bundle: b, manifest: m, chapter: 5, sentence: 40, style: ReaderStyle())
        model.setPageSize(CGSize(width: 338, height: 700))
        let layout = try XCTUnwrap(model.layout)
        XCTAssertGreaterThan(layout.pageCount, 1)
        // The requested sentence is on the opened page.
        XCTAssertEqual(layout.page(forSentence: 40), model.page)

        // Every page's first sentence maps back to that page (no gaps, no overlaps).
        var seen = Set<Int>()
        for p in 0..<layout.pageCount {
            let s = try XCTUnwrap(layout.firstSentence(onPage: p), "page \(p) has no sentence")
            XCTAssertLessThanOrEqual(layout.page(forSentence: s)!, p)
            seen.insert(s)
        }
        XCTAssertEqual(seen.count, layout.pageCount, "each page starts at a distinct sentence")

        // Font size and theme changes keep the same sentence on screen.
        model.go(chapter: 5, sentence: 60)
        let anchor = try XCTUnwrap(model.currentSentence)
        model.style = model.style.larger().larger()
        XCTAssertEqual(model.layout?.page(forSentence: anchor), model.page)
        model.style = ReaderStyle(theme: .focus, fontSize: model.style.fontSize)
        XCTAssertEqual(model.layout?.page(forSentence: anchor), model.page)
        model.setPageSize(CGSize(width: 600, height: 500))   // rotation / window resize
        XCTAssertEqual(model.layout?.page(forSentence: anchor), model.page)

        // Paging across chapters both ways.
        model.go(chapter: 5, sentence: 0)
        model.previous()
        XCTAssertEqual(model.chapter, 4)
        XCTAssertEqual(model.page, model.pageCount - 1, "going back lands on the previous chapter's last page")
        model.next()
        XCTAssertEqual(model.chapter, 5); XCTAssertEqual(model.page, 0)

        // Last page of the book: forward is a no-op, never a crash.
        let last = m.chapters.last!.index
        model.go(chapter: last, sentence: Int.max)
        for _ in 0..<50 { model.next() }
        XCTAssertEqual(model.chapter, last)
        XCTAssertFalse(model.canGoForward)

        // Narration following: highlight moves pages only if the reader was on the read page.
        model.go(chapter: 5, sentence: 0)
        let farSentence = m.chapters.first { $0.index == 5 }!.sentenceCount - 1
        model.follow(chapter: 5, sentence: 0)
        model.follow(chapter: 5, sentence: farSentence)       // jumped far (seek): follows
        XCTAssertEqual(model.layout?.page(forSentence: farSentence), model.page)
        model.go(chapter: 2, sentence: 0)                     // user browses elsewhere
        model.follow(chapter: 5, sentence: farSentence - 1)
        XCTAssertEqual(model.chapter, 2, "doesn't yank someone browsing another chapter")

        // Mac spread: pages stay aligned to the left page.
        let spread = ReaderModel(bundle: b, manifest: m, chapter: 5, sentence: 40, style: ReaderStyle(), columns: 2)
        spread.setPageSize(CGSize(width: 500, height: 640))
        XCTAssertEqual(spread.page % 2, 0)
        spread.next(); XCTAssertEqual(spread.page % 2, 0)
    }

    func testPlayerMapsSentencesToAudio() async throws {
        let (lib, b, _) = try await macLibrary()
        _ = lib
        let m = try b.manifest()
        let player = NarrationPlayer()
        var saved: [(Int, Int)] = []
        player.onPosition = { _, c, s, _ in saved.append((c, s)) }

        // Chapter 0 is front matter (no audio): starts at the first narrated chapter.
        player.load(bundle: b, manifest: m, chapter: 0, sentence: nil, autoplay: false)
        XCTAssertEqual(player.chapter, 1)
        XCTAssertNil(player.message)

        player.jump(chapter: 1, sentence: 5, autoplay: false)
        XCTAssertEqual(player.sentence, 5)
        let timing = try XCTUnwrap(b.timing(m.chapters[1]))
        XCTAssertEqual(player.time, timing.sentences[5].start, accuracy: 0.01)

        player.skip(10_000)             // past the end → next narrated chapter
        XCTAssertEqual(player.chapter, 2)
        player.skip(-10_000)            // before the start → previous chapter
        XCTAssertEqual(player.chapter, 1)

        // A chapter that isn't narrated yet: clear message, no crash.
        player.load(bundle: b, manifest: m, chapter: 30, sentence: nil, autoplay: false)
        XCTAssertNotNil(player.message)
        XCTAssertFalse(saved.isEmpty, "seeks save the position")
    }
}

final class Locked<T>: @unchecked Sendable {
    private var v: T; private let l = NSLock()
    init(_ v: T) { self.v = v }
    var value: T { l.withLock { v } }
    func mutate(_ f: (inout T) -> Void) { l.withLock { f(&v) } }
}
