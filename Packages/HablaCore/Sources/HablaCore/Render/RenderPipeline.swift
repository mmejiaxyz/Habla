import Foundation
import CryptoKit

public struct RenderProgress: Sendable {
    public var chapterIndex: Int
    public var chapterTitle: String
    public var sentence: Int
    public var sentenceCount: Int
    public var chaptersDone: Int
    public var chaptersTotal: Int
    public var cacheHit: Bool
}

/// Renders a bundle's pending chapters with a voice engine (Mac side).
///
/// Each sentence is cached by `engine version + voice + speed + spoken text`, so:
/// re-running only renders what is missing, an interrupted chapter resumes where
/// it stopped, and fixing one sentence's text re-renders just that sentence.
public final class RenderPipeline: @unchecked Sendable {
    public let engine: TTSEngine
    public let cacheDirectory: URL
    var assembler = AudioAssembler()

    /// Pauses (seconds) that make narration breathe like a human reader.
    public struct Pauses: Sendable {
        public var sentence = 0.28
        public var paragraph = 0.65
        public var listItem = 0.45
        public var heading = 1.1
        public var sceneBreak = 1.6
        public init() {}
    }
    public var pauses = Pauses()

    public init(engine: TTSEngine, cacheDirectory: URL) {
        self.engine = engine
        self.cacheDirectory = cacheDirectory
    }

    /// Sentences voiced ahead of the one being written: enough to keep every engine busy.
    var lookahead: Int { max(1, (engine as? EnginePool)?.size ?? 1) + 1 }

    /// Renders pending chapters (all narratable ones if the voice changed).
    /// The manifest is committed after every chapter so a partially rendered
    /// book can already sync and play.
    public func render(_ bundle: BookBundle, voice: VoiceInfo, only chapterIndices: Set<Int>? = nil,
                       progress: (@Sendable (RenderProgress) -> Void)? = nil) async throws {
        var manifest = try bundle.manifest()
        if manifest.voice != voice {
            // Keep the old voice's chapters playable until each is replaced: stamp them, then switch.
            for i in manifest.chapters.indices where manifest.chapters[i].audioStatus == .ready && manifest.chapters[i].voiceID == nil {
                manifest.chapters[i].voiceID = manifest.voice?.voiceID
            }
            manifest.voice = voice
            manifest = try bundle.commit(manifest)
        }

        let todo = manifest.chaptersToNarrate(voiceID: voice.voiceID).filter { chapterIndices?.contains($0.index) ?? true }
        for (n, info) in todo.enumerated() {
            try Task.checkCancellation()
            let text = try bundle.chapterText(info)
            let plan = plan(text)
            let audioPath = BookBundle.audioPath(info.index)
            let timingPath = BookBundle.timingPath(info.index)
            guard FileManager.default.fileExists(atPath: bundle.url.path) else { throw CancellationError() }

            let writer = AudioAssembler.Writer(assembler: assembler, url: bundle.fileURL(audioPath))
            // Voice a few sentences ahead (in parallel on an engine pool); write them in order.
            var ahead: [Int: Task<(SpeechAudio, Bool), Error>] = [:]
            func launch(_ k: Int) {
                guard k < plan.count, ahead[k] == nil else { return }
                let text = plan[k].spoken
                if text.isEmpty {
                    ahead[k] = Task { (SpeechAudio(samples: [Float](repeating: 0, count: 7_200), sampleRate: 24_000), true) }
                    return
                }
                ahead[k] = Task { try await self.sentenceAudioWithRetry(text, voice: voice) }
            }
            defer { ahead.values.forEach { $0.cancel() } }
            do {
                for k in 0..<min(lookahead, plan.count) { launch(k) }
                for (k, item) in plan.enumerated() {
                    try Task.checkCancellation()
                    launch(k)
                    let (audio, hit) = try await withTaskCancellationHandler {
                        try await ahead[k]!.value
                    } onCancel: { [ahead] in ahead.values.forEach { $0.cancel() } }
                    ahead[k] = nil
                    launch(k + lookahead)
                    try writer.append(.init(sentenceID: item.id, audio: audio, pauseAfter: item.pause))
                    progress?(RenderProgress(chapterIndex: info.index, chapterTitle: info.title, sentence: k + 1,
                                             sentenceCount: plan.count, chaptersDone: n, chaptersTotal: todo.count,
                                             cacheHit: hit))
                }
            } catch {
                writer.discard()
                throw error
            }
            // The book may have been deleted while this chapter was being narrated.
            guard FileManager.default.fileExists(atPath: bundle.fileURL(BookBundle.manifestFile).path) else {
                writer.discard(); throw CancellationError()
            }
            let (duration, timings) = try writer.finish()
            try bundle.write(ChapterTiming(index: info.index, duration: duration, sentences: timings), to: timingPath)

            manifest = try bundle.manifest()
            if let i = manifest.chapters.firstIndex(where: { $0.index == info.index }) {
                manifest.chapters[i].audioFile = audioPath
                manifest.chapters[i].timingFile = timingPath
                manifest.chapters[i].duration = duration
                manifest.chapters[i].audioStatus = .ready
                manifest.chapters[i].voiceID = voice.voiceID
                manifest.chapters[i].model = engine.modelDescription
            }
            manifest = try bundle.commit(manifest)
            pruneCache()
        }
    }

    /// One retry (the engine restarts its worker on failure). A sentence that still fails
    /// becomes a short silence rather than stopping the whole book; it is not cached, so a
    /// later re-narration tries it again.
    public var skippedSentences: Int { skipLock.withLock { skipped } }
    private var skipped = 0
    private let skipLock = NSLock()

    func sentenceAudioWithRetry(_ text: String, voice: VoiceInfo) async throws -> (SpeechAudio, Bool) {
        do { return try await sentenceAudio(text, voice: voice) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if case TTSError.engineUnavailable = error { throw error }
            if "\(error)".contains("worker") { await engine.shutdown() }   // crashed / hung: fresh worker
            do { return try await sentenceAudio(text, voice: voice) }
            catch is CancellationError { throw CancellationError() }
            catch {
                // Engine unusable (not installed, model missing): stop, so the user sees why.
                if case TTSError.engineUnavailable = error { throw error }
                skipLock.withLock { skipped += 1 }
                return (SpeechAudio(samples: [Float](repeating: 0, count: 12_000), sampleRate: 24_000), false)
            }
        }
    }

    /// Keeps the sentence cache under `cacheLimit` bytes, dropping the oldest entries.
    /// (Finished chapters never need their cache; it only speeds up resumes and re-narrations.)
    public var cacheLimit = 2_000_000_000

    func pruneCache() {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var files: [(URL, Int, Date)] = []
        var total = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = v.fileSize else { continue }
            files.append((u, size, v.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > cacheLimit else { return }
        for f in files.sorted(by: { $0.2 < $1.2 }) {
            try? fm.removeItem(at: f.0)
            total -= f.1
            if total <= cacheLimit * 8 / 10 { break }
        }
    }

    // MARK: - Planning

    struct PlannedSentence { var id: Int; var spoken: String; var pause: TimeInterval }

    func plan(_ chapter: ChapterText) -> [PlannedSentence] {
        var out: [PlannedSentence] = []
        for block in chapter.blocks {
            if block.kind == .sceneBreak {
                if !out.isEmpty { out[out.count - 1].pause = max(out[out.count - 1].pause, pauses.sceneBreak) }
                continue
            }
            for (j, s) in block.sentences.enumerated() {
                var spoken = s.spoken ?? block.substring(s.range)
                // Nothing to say (only emoji or symbols): keep the sentence as a short silence, so
                // every sentence has a timing and highlights/seeking stay aligned with the text.
                if !spoken.contains(where: { $0.isLetter || $0.isNumber }) { spoken = "" }
                let last = j == block.sentences.count - 1
                let pause: TimeInterval
                switch (last, block.kind) {
                case (false, _): pause = pauses.sentence
                case (true, .heading): pause = pauses.heading
                case (true, .listItem): pause = pauses.listItem
                default: pause = pauses.paragraph
                }
                out.append(PlannedSentence(id: s.id, spoken: spoken, pause: pause))
            }
        }
        return out
    }

    // MARK: - Sentence cache

    func cacheKey(_ text: String, voice: VoiceInfo) -> String {
        let raw = "\(engine.cacheVersion)|\(voice.voiceID)|\(voice.speed)|\(text)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func sentenceAudio(_ text: String, voice: VoiceInfo) async throws -> (SpeechAudio, Bool) {
        let key = cacheKey(text, voice: voice)
        let dir = cacheDirectory.appendingPathComponent("v2/\(key.prefix(2))", isDirectory: true)
        let file = dir.appendingPathComponent("\(key).pcm16")

        // Format: sample rate (Float64), then Int16 samples.
        if let data = try? Data(contentsOf: file), data.count > 8 {
            let rate = data.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
            let samples = data.dropFirst(8).withUnsafeBytes { raw in
                raw.bindMemory(to: Int16.self).map { Float($0) / 32767 }
            }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)  // LRU touch
            return (SpeechAudio(samples: samples, sampleRate: rate), true)
        }

        let audio = try await engine.synthesize(text, voice: voice)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var data = withUnsafeBytes(of: audio.sampleRate) { Data($0) }
        let ints = audio.samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        ints.withUnsafeBufferPointer { data.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }
        try? data.write(to: file, options: .atomic)   // the cache is best-effort; the audio is what matters
        return (audio, false)
    }
}
