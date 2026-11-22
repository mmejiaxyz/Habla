import XCTest
import HablaCore
@testable import ParadeeKit

/// The iPhone's English pronunciation vs the Mac's, on a real book: every sentence Habla would
/// narrate from one EPUB, compared phoneme for phoneme with Python Paradee (run live through the
/// Mac's voice engine, so nothing is stored). Two measurements:
///   port: Swift fed spaCy's own tokens and tags — isolates the port, must be ≥ 99% identical;
///   iPhone: Swift with Apple's NaturalLanguage tagger, as it runs on the phone — phoneme
///           error rate must stay ≤ 0.5%.
/// Opt-in, since it needs a book and the Mac's voice engine:
///   PARADEE_EPUB=/path/to/book.epub PARADEE_REPORT=/tmp/report.txt swift test --package-path Packages/ParadeeKit --filter EnglishBookTests
final class EnglishBookTests: XCTestCase {
    struct Reference: Decodable {
        struct Tok: Decodable { let text: String; let tag: String; let ws: String }
        let us: String, gb: String, tokens: [Tok]
    }

    func testBookMatchesMacParadee() throws {
        guard let path = ProcessInfo.processInfo.environment["PARADEE_EPUB"] else {
            throw XCTSkip("set PARADEE_EPUB to an English EPUB")
        }
        let sentences = try Self.spokenSentences(of: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(sentences.count, 100, "expected a whole book")
        let refs = try Self.macReference(sentences)
        XCTAssertEqual(refs.count, sentences.count)

        let g2p = try ParadeeG2P()
        let us = try EnglishG2P(british: false, g2p: g2p), gb = try EnglishG2P(british: true, g2p: g2p)
        var port = (us: Score(), gb: Score()), phone = (us: Score(), gb: Score())
        var differences: [(String, String, String)] = []
        for (text, ref) in zip(sentences, refs) {
            let spaCy = ref.tokens.map { EnglishG2P.RawToken(text: $0.text, tag: $0.tag, ws: $0.ws) }
            port.us.add(try us.phonemize(text, tokens: spaCy), ref.us)
            port.gb.add(try gb.phonemize(text, tokens: spaCy), ref.gb)
            let got = try us.phonemize(text)
            phone.us.add(got, ref.us)
            phone.gb.add(try gb.phonemize(text), ref.gb)
            if got != ref.us { differences.append((text, ref.us, got)) }
        }
        var report = ""
        func say(_ line: String) { report += line + "\n" }
        say("\(sentences.count) sentences from \(URL(fileURLWithPath: path).lastPathComponent)")
        for (name, s) in [("port US", port.us), ("port GB", port.gb), ("iPhone US", phone.us), ("iPhone GB", phone.gb)] {
            say(String(format: "  %@: %.2f%% sentences identical, %.3f%% phonemes differ", name, s.identical * 100, s.errorRate * 100))
        }
        for (text, mac, iphone) in differences.prefix(15) {
            say("  “\(text.prefix(70))”\n    mac:    \(mac)\n    iphone: \(iphone)")
        }
        // `swift test` drops a test's own output when it isn't run in a terminal: PARADEE_REPORT
        // names a file to write the scores and differences to.
        if let out = ProcessInfo.processInfo.environment["PARADEE_REPORT"] {
            try report.write(toFile: out, atomically: true, encoding: .utf8)
        }
        XCTAssertGreaterThanOrEqual(port.us.identical, 0.99)
        XCTAssertGreaterThanOrEqual(port.gb.identical, 0.99)
        XCTAssertLessThanOrEqual(phone.us.errorRate, 0.005)
        XCTAssertLessThanOrEqual(phone.gb.errorRate, 0.005)
    }

    /// What narration would say, sentence by sentence (as RenderPipeline plans it).
    static func spokenSentences(of epub: URL) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paradee-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try BookImporter().importEPUB(at: epub, into: dir)
        var out: [String] = []
        for info in try bundle.manifest().chapters where info.audioStatus != .skipped {
            for block in try bundle.chapterText(info).blocks {
                for s in block.sentences {
                    let spoken = s.spoken ?? block.substring(s.range)
                    if spoken.contains(where: { $0.isLetter || $0.isNumber }) { out.append(spoken) }
                }
            }
        }
        return out
    }

    /// Python Paradee on the Mac (the voice engine Habla installs), as the reference.
    static func macReference(_ sentences: [String]) throws -> [Reference] {
        let voice = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Habla Studio/voice")
        let python = voice.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("the Mac's voice engine isn't installed")
        }
        let script = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/mac_reference", withExtension: "py"))
        let p = Process()
        p.executableURL = python
        p.arguments = ["-I", script.path]
        p.environment = ["HF_HOME": voice.appendingPathComponent("hf").path, "HF_HUB_OFFLINE": "1", "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        try p.run()
        // Write on another thread: a whole book is more than a pipe buffer holds.
        let data = try JSONEncoder().encode(sentences)
        DispatchQueue.global().async { input.fileHandleForWriting.write(data); try? input.fileHandleForWriting.close() }
        let reply = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "the Mac's Paradee failed")
        return try reply.split(separator: 0x0A).map { try JSONDecoder().decode(Reference.self, from: Data($0)) }
    }

    struct Score {
        var sentences = 0, same = 0, phonemes = 0, errors = 0
        var identical: Double { sentences == 0 ? 0 : Double(same) / Double(sentences) }
        var errorRate: Double { phonemes == 0 ? 0 : Double(errors) / Double(phonemes) }
        mutating func add(_ got: String, _ ref: String) {
            sentences += 1
            if got == ref { same += 1 }
            phonemes += ref.unicodeScalars.count
            errors += Self.distance(Array(got.unicodeScalars), Array(ref.unicodeScalars))
        }
        static func distance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
            if a.isEmpty { return b.count }
            var row = Array(0...b.count)
            for i in 1...a.count {
                var prev = row[0]; row[0] = i
                for j in stride(from: 1, through: b.count, by: 1) {
                    let keep = row[j]
                    row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                    prev = keep
                }
            }
            return row[b.count]
        }
    }
}
