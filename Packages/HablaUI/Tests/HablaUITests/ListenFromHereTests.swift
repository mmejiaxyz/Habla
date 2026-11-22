import XCTest
import HablaCore
@testable import HablaUI

/// Part B — "Listen from here" on the word card: the tapped sentence maps to the narrated
/// sentence id, and the button (which the card shows only for narrated chapters) is hidden
/// when the chapter has no audio.
@MainActor
final class ListenFromHereTests: XCTestCase {
    /// A tiny one-chapter book with a heading and three known sentences.
    func book(ready: Bool) throws -> ReaderModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("habla-ui-listen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var zip = ZipWriter()
        zip.add("mimetype", data: Data("application/epub+zip".utf8))
        zip.add("META-INF/container.xml", data: Data("""
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.utf8))
        zip.add("OEBPS/content.opf", data: Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Listen</dc:title><dc:creator>T</dc:creator><dc:language>en</dc:language></metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="c1"/></spine>
        </package>
        """.utf8))
        zip.add("OEBPS/nav.xhtml", data: Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body><nav epub:type="toc"><ol>
        <li><a href="ch1.xhtml">Chapter One</a></li>
        </ol></nav></body></html>
        """.utf8))
        zip.add("OEBPS/ch1.xhtml", data: Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <h1>Chapter One</h1>
        <p>First sentence here. Second sentence, with more words. Third sentence ends now.</p>
        </body></html>
        """.utf8))
        let epub = dir.appendingPathComponent("listen.epub")
        try zip.finalize().write(to: epub)

        let bundle = try BookImporter().importEPUB(at: epub, into: dir.appendingPathComponent("lib"))
        var m = try bundle.manifest()
        if ready {
            m.chapters[0].audioStatus = .ready
            m = try bundle.commit(m)
        }
        let model = ReaderModel(bundle: bundle, manifest: m, chapter: m.chapters[0].index, sentence: nil, style: ReaderStyle())
        model.setPageSize(CGSize(width: 338, height: 700))
        return model
    }

    func testTappedSentenceMapsToTheNarratedSentence() throws {
        let model = try book(ready: true)
        let ns = try XCTUnwrap(model.layout).chapter.text.string as NSString
        let layout = try XCTUnwrap(model.layout)

        // The word card's sentence (the whole grammatical sentence around the tapped word)
        // resolves to the narration sentence that starts there.
        let second = ns.range(of: "Second sentence")
        let sentence = try XCTUnwrap(model.sentenceRange(around: second.location))
        XCTAssertEqual(ns.substring(with: sentence), "Second sentence, with more words.")
        let id = try XCTUnwrap(model.narrationStart(at: sentence.location))
        XCTAssertEqual((layout.chapter.text.string as NSString).substring(with: layout.chapter.range(ofSentence: id)!),
                       "Second sentence, with more words.")

        // A word in the first sentence and one in the third resolve to their own sentences.
        XCTAssertEqual(model.narrationStart(at: ns.range(of: "First sentence").location), 1)
        XCTAssertEqual(model.narrationStart(at: ns.range(of: "Third sentence").location), 3)
        // The heading is its own sentence.
        XCTAssertEqual(model.narrationStart(at: ns.range(of: "Chapter One").location), 0)
    }

    func testListenButtonIsHiddenForUnnarratedChapters() throws {
        let model = try book(ready: false)
        let ns = try XCTUnwrap(model.layout).chapter.text.string as NSString
        let sentence = try XCTUnwrap(model.sentenceRange(around: ns.range(of: "Second sentence").location))
        // No audio for this chapter → no start point → the card shows no listen button.
        XCTAssertNil(model.narrationStart(at: sentence.location))
        XCTAssertNil(model.narrationStart(at: ns.range(of: "Chapter One").location))
    }

    /// The button's action: jumping to the tapped sentence starts playback there, even when
    /// the player had no book loaded.
    func testJumpStartsPlaybackAtTheTappedSentence() async throws {
        let model = try book(ready: false)
        let bundle = model.bundle
        var m = try bundle.manifest()
        m.chapters[0].audioStatus = .pending
        m = try bundle.commit(m)
        try await RenderPipeline(engine: ToneEngine(),
                                 cacheDirectory: bundle.url.deletingLastPathComponent().appendingPathComponent("cache"))
            .render(bundle, voice: VoiceInfo(engine: "tone", voiceID: "tone"))
        let fresh = try bundle.manifest()
        let rendered = ReaderModel(bundle: bundle, manifest: fresh, chapter: 0, sentence: nil, style: ReaderStyle())
        rendered.setPageSize(CGSize(width: 338, height: 700))

        let ns = try XCTUnwrap(rendered.layout).chapter.text.string as NSString
        let sentence = try XCTUnwrap(rendered.sentenceRange(around: ns.range(of: "Second sentence").location))
        let id = try XCTUnwrap(rendered.narrationStart(at: sentence.location))

        let player = NarrationPlayer()
        XCTAssertNil(player.bookID, "the player has nothing loaded")
        player.jump(chapter: rendered.chapter, sentence: id, autoplay: true, in: bundle, manifest: fresh)
        try await Task.sleep(nanoseconds: 600_000_000)   // AVPlayer settles and ticks
        XCTAssertEqual(player.bookID, fresh.id)
        XCTAssertEqual(player.chapter, rendered.chapter)
        XCTAssertEqual(player.sentence, id)
        XCTAssertTrue(player.isPlaying)
        player.unload()
    }
}
