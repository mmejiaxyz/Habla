import XCTest
@testable import HablaCore

/// The manifest shape an old iPhone build decodes (no planVersion): new books must still load.
private struct OldChapterInfo: Decodable {
    var index: Int
    var title: String
    var audioStatus: ChapterInfo.AudioStatus
    var sentenceCount: Int
    var isFrontMatter: Bool
}

private struct OldManifest: Decodable {
    var id: String
    var chapters: [OldChapterInfo]
}

/// Every chapter opens with its name (spoken from the manifest when the text doesn't already
/// say it). The synthetic title uses a sentence id no real sentence can have, and every consumer
/// (fractions, positions, KOReader sync) treats it as the chapter's start. The audible break
/// between chapters is played by NarrationPlayer, so it isn't in the rendered audio.
final class ChapterTitlesTests: XCTestCase {
    func book(_ import: BookImporter = BookImporter()) throws -> (bundle: BookBundle, manifest: BookManifest, dir: URL) {
        let dir = Fixtures.tempDir()
        let bundle = try `import`.importEPUB(at: Fixtures.writeChapterTitlesEPUB(to: dir), into: dir)
        return (bundle, try bundle.manifest(), dir)
    }

    func testChapterWithoutHeadingGetsSpokenTitleFirst() throws {
        let (bundle, m, dir) = try book()
        let pipeline = RenderPipeline(engine: ToneEngine(), cacheDirectory: dir.appendingPathComponent("cache"))
        let info = try XCTUnwrap(m.chapters.first { $0.title == "Chapter One" })
        let text = try bundle.chapterText(info)
        let plan = pipeline.plan(text, language: m.language)

        // The title is only an image (a `chapter-title` paragraph with nothing spoken in it),
        // so the plan must open with the manifest/TOC name.
        XCTAssertEqual(plan.first?.id, RenderPipeline.titleSentenceID)
        XCTAssertEqual(plan.first?.spoken, "Chapter One")
        XCTAssertEqual(plan.first?.pause, pipeline.pauses.heading, "heading pause before the first body sentence")
        // The id can never collide with a real sentence id (0..<sentenceCount).
        XCTAssertLessThan(RenderPipeline.titleSentenceID, 0)
        XCTAssertEqual(info.sentenceCount, 1, "the title is an image; only the body paragraph has text")
    }

    func testHeadingThatAlreadySaysTheNameIsNotDoubled() throws {
        let (bundle, m, dir) = try book()
        let pipeline = RenderPipeline(engine: ToneEngine(), cacheDirectory: dir.appendingPathComponent("cache"))
        let info = try XCTUnwrap(m.chapters.first { $0.title == "Chapter Two" })
        let plan = pipeline.plan(try bundle.chapterText(info), language: m.language)

        XCTAssertEqual(plan.first?.id, 0, "the printed heading itself announces the chapter")
        XCTAssertEqual(plan.first?.spoken, "Chapter Two")
        XCTAssertFalse(plan.contains { $0.id == RenderPipeline.titleSentenceID }, "no doubled title")
        XCTAssertFalse(pipeline.titleChangesAudio(try bundle.chapterText(info), language: m.language))
    }

    func testTextStyledTitleReadsLikeAHeading() throws {
        let (bundle, m, dir) = try book()
        let pipeline = RenderPipeline(engine: ToneEngine(), cacheDirectory: dir.appendingPathComponent("cache"))
        let info = try XCTUnwrap(m.chapters.first { $0.title == "Chapter Four" })
        let plan = pipeline.plan(try bundle.chapterText(info), language: m.language)

        // `<p class="chapter-title">Chapter Four</p>`: spoken first, with a heading pause,
        // and not doubled by a synthetic title.
        XCTAssertEqual(plan.first?.id, 0)
        XCTAssertEqual(plan.first?.spoken, "Chapter Four")
        XCTAssertEqual(plan.first?.pause, pipeline.pauses.heading)
        XCTAssertFalse(plan.contains { $0.id == RenderPipeline.titleSentenceID })
    }

    func testTitleOnlyChapterIsNarratedNeverSkipped() async throws {
        let (bundle, m, dir) = try book()
        let pipeline = RenderPipeline(engine: ToneEngine(), cacheDirectory: dir.appendingPathComponent("cache"))
        let info = try XCTUnwrap(m.chapters.first { $0.title == "Book Two" })
        XCTAssertEqual(info.audioStatus, .pending, "a part page is a chapter to narrate, not front matter to skip")
        XCTAssertTrue(m.chaptersToNarrate(voiceID: "tone").contains { $0.index == info.index })
        XCTAssertEqual(info.sentenceCount, 1)

        try await pipeline.render(bundle, voice: VoiceInfo(engine: "tone", voiceID: "tone"))
        let done = try bundle.manifest()
        let narrated = try XCTUnwrap(done.chapters.first { $0.index == info.index })
        XCTAssertEqual(narrated.audioStatus, .ready)
        XCTAssertEqual(narrated.planVersion, BookManifest.currentPlanVersion)
        // Just the title.
        let timing = try XCTUnwrap(try bundle.timing(narrated))
        XCTAssertEqual(timing.sentences.map(\.id), [0])
    }

    func testSyntheticIDsAreIgnoredByFractionsPositionsAndXPointers() throws {
        let (bundle, m, _) = try book()
        let map = try KOReaderPositionMap(bundle: bundle)
        let chapter = m.chapters.first { $0.title == "Chapter One" }!.index

        // A position on the title is the chapter's start, not its end.
        XCTAssertEqual(m.fraction(chapter: chapter, sentence: RenderPipeline.titleSentenceID),
                       m.fraction(chapter: chapter, sentence: 0))
        XCTAssertEqual(map.xpointer(chapter: chapter, sentence: RenderPipeline.titleSentenceID),
                       map.xpointer(chapter: chapter, sentence: 0))
        XCTAssertEqual(map.percentage(chapter: chapter, sentence: RenderPipeline.titleSentenceID),
                       map.percentage(chapter: chapter, sentence: 0))

        // A synthetic position always loses to a real one, even with equal timestamps.
        let now = Date()
        let title = ReadingPosition(bookID: m.id, chapter: chapter, sentence: RenderPipeline.titleSentenceID,
                                    mode: .listening, updatedAt: now, deviceID: "t")
        let real = ReadingPosition(bookID: m.id, chapter: chapter, sentence: 5, mode: .listening,
                                   updatedAt: now, deviceID: "t")
        XCTAssertEqual(ReadingPosition.merge(title, real)?.sentence, 5)
        XCTAssertEqual(ReadingPosition.merge(real, title)?.sentence, 5)
    }

    func testOldPlanChaptersAreRenarratedAndOldBuildsCanStillReadThem() async throws {
        let (bundle, m, dir) = try book()
        let pipeline = RenderPipeline(engine: ToneEngine(), cacheDirectory: dir.appendingPathComponent("cache"))
        try await pipeline.render(bundle, voice: VoiceInfo(engine: "tone", voiceID: "tone"))
        var done = try bundle.manifest()
        XCTAssertTrue(done.chaptersToNarrate(voiceID: "tone").isEmpty)

        // A book narrated before this plan existed (no planVersion recorded) is queued again,
        // but only chapters whose spoken words change are re-rendered: the rest keep the exact
        // same audio file (the iPhone never re-downloads identical audio) and are just stamped.
        func audioData() throws -> [Int: Data] {
            var out: [Int: Data] = [:]
            for c in try bundle.manifest().chapters where c.audioFile != nil {
                out[c.index] = try Data(contentsOf: bundle.fileURL(c.audioFile!))
            }
            return out
        }
        let before = try audioData()
        for i in done.chapters.indices { done.chapters[i].planVersion = nil }
        done = try bundle.commit(done)
        XCTAssertEqual(done.chaptersToNarrate(voiceID: "tone").count, done.chapters.count)
        let changing = try done.chapters.filter {
            pipeline.titleChangesAudio(try bundle.chapterText($0), language: done.language)
        }.map(\.index)
        XCTAssertFalse(changing.isEmpty, "the fixture has a chapter whose title is only an image")
        XCTAssertLessThan(changing.count, done.chapters.count, "and chapters that already say their name")
        // Make the re-rendered chapters observable: drop their audio, so a re-render rewrites it.
        for i in changing { try FileManager.default.removeItem(at: bundle.fileURL(done.chapters.first { $0.index == i }!.audioFile!)) }
        try await pipeline.render(bundle, voice: VoiceInfo(engine: "tone", voiceID: "tone"))
        let stamped = try bundle.manifest()
        XCTAssertTrue(stamped.chaptersToNarrate(voiceID: "tone").isEmpty)
        XCTAssertTrue(stamped.chapters.allSatisfy { $0.planVersion == BookManifest.currentPlanVersion })
        let after = try audioData()
        for (index, data) in before where !changing.contains(index) {
            XCTAssertEqual(after[index], data, "chapter \(index) says its name already: audio untouched")
        }
        for index in changing { XCTAssertNotNil(after[index], "chapter \(index) was re-rendered with its title") }

        // An old iPhone build (whose ChapterInfo has no planVersion) still decodes new books.
        let json = try Data(contentsOf: bundle.fileURL(BookBundle.manifestFile))
        let old = try JSONDecoder().decode(OldManifest.self, from: json)
        XCTAssertEqual(old.id, m.id)
        XCTAssertEqual(old.chapters.count, m.chapters.count)
        XCTAssertTrue(old.chapters.allSatisfy { $0.audioStatus == .ready })
    }

    /// Re-narrating an already-narrated book is cheap: the old sentence cache supplies every
    /// body sentence, so only the new announced titles are synthesised.
    func testRenarrationOnlySynthesisesTheNewTitles() async throws {
        let (bundle, _, dir) = try book()
        let voice = VoiceInfo(engine: "tone", voiceID: "tone")
        let first = RenderPipeline(engine: ToneEngine(), cacheDirectory: dir.appendingPathComponent("cache"))
        try await first.render(bundle, voice: voice)
        var m = try bundle.manifest()
        for i in m.chapters.indices { m.chapters[i].planVersion = nil }
        m = try bundle.commit(m)

        // A fresh cache holding what an old build's cache would: every body sentence, no titles.
        let fresh = RenderPipeline(engine: ToneEngine(), cacheDirectory: dir.appendingPathComponent("cache-old"))
        for info in m.chapters {
            let text = try bundle.chapterText(info)
            for block in text.blocks {
                for s in block.sentences {
                    let spoken = s.spoken ?? block.substring(s.range)
                    if spoken.contains(where: { $0.isLetter || $0.isNumber }) {
                        _ = try await fresh.sentenceAudio(spoken, voice: voice)
                    }
                }
            }
        }

        let hits = HitCounter()
        try await fresh.render(bundle, voice: voice) { hits.add($0.cacheHit) }
        // Only "Chapter One" (an image) needs a new synthetic title: its sentence is the one
        // thing an old book's cache doesn't hold. The styled paragraph and headings say their
        // own names and come from cache.
        XCTAssertEqual(hits.misses, 1, "only the new title sentence is synthesised")
        XCTAssertGreaterThan(hits.hits, 0)
    }

    func testFrontMatterWithNoMeaningfulTitleIsNotAnnounced() throws {
        let (bundle, m, dir) = try book()
        let pipeline = RenderPipeline(engine: ToneEngine(), cacheDirectory: dir.appendingPathComponent("cache"))
        let info = m.chapters[0]
        let text = try bundle.chapterText(info)
        for meaningless in ["Front matter", "Untitled", ""] {
            var t = text
            t.title = meaningless
            let plan = pipeline.plan(t, language: m.language)
            XCTAssertFalse(plan.contains { $0.id == RenderPipeline.titleSentenceID }, "“\(meaningless)” is not announced")
        }
        var t = text
        t.title = "Copyright"
        let plan = pipeline.plan(t, language: m.language)
        XCTAssertEqual(plan.first?.id, RenderPipeline.titleSentenceID, "a real front-matter title is announced")
        XCTAssertEqual(plan.first?.spoken, "Copyright")
    }
}
