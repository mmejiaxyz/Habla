#if os(macOS)
import Foundation

/// Kokoro-82M via a long-running Python worker (`Tools/kokoro/kokoro_worker.py`).
/// The worker starts on first use and keeps the model loaded until `shutdown()`.
public actor KokoroEngine: TTSEngine {
    public nonisolated let name = "kokoro"
    /// Cached audio is only reused for the same model file (the int8 model sounds a little different).
    public nonisolated let cacheVersion: String

    public struct Configuration: Sendable {
        public var python: URL
        public var worker: URL
        public var model: URL
        public var voicesFile: URL
        public var language = "en-us"

        public init(python: URL, worker: URL, model: URL, voicesFile: URL) {
            self.python = python; self.worker = worker; self.model = model; self.voicesFile = voicesFile
        }

        /// Layout produced by `Tools/kokoro/setup.sh`.
        public init(toolsDirectory dir: URL) {
            self.init(python: dir.appendingPathComponent(".venv/bin/python"),
                      worker: dir.appendingPathComponent("kokoro_worker.py"),
                      model: dir.appendingPathComponent("models/kokoro-v1.0.onnx"),
                      voicesFile: dir.appendingPathComponent("models/voices-v1.0.bin"))
        }
    }

    private let config: Configuration
    private var process: Process?
    private var stdin: FileHandle?
    private var lines: LineReader?
    private var availableVoices: [String] = []
    private let scratch: URL

    public init(configuration: Configuration) {
        config = configuration
        let model = configuration.model.deletingPathExtension().lastPathComponent   // "kokoro-v1.0"
        cacheVersion = model == "kokoro-v1.0" ? "kokoro-v1.0-onnx" : "\(model)-onnx"
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("habla-kokoro-\(UUID().uuidString)")
    }

    public func voices() async throws -> [String] {
        try await start()
        return availableVoices
    }

    // One request at a time: the worker answers in order on one pipe, and the actor
    // re-enters at every await (a preview must never read narration's reply).
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    public func synthesize(_ text: String, voice: VoiceInfo) async throws -> SpeechAudio {
        await acquire()
        defer { release() }
        try await start()
        let out = scratch.appendingPathComponent("\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: out) }

        let request: [String: Any] = ["text": text, "voice": voice.voiceID, "speed": voice.speed,
                                      "lang": Self.language(for: voice.voiceID, default: config.language), "out": out.path]
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)
        do { try stdin?.write(contentsOf: line) }
        catch { await shutdown(); throw TTSError.synthesisFailed("Kokoro worker stopped") }

        // Watchdog: a worker that hangs is killed, which ends the wait below.
        let proc = process
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if !Task.isCancelled { proc?.terminate() }
        }
        defer { watchdog.cancel() }
        guard let reply = try await nextMessage() else {
            await shutdown()
            throw TTSError.synthesisFailed("Kokoro worker exited")
        }
        guard reply["ok"] as? Bool == true else {
            throw TTSError.synthesisFailed(reply["error"] as? String ?? "unknown error")
        }
        let rate = (reply["sample_rate"] as? NSNumber)?.doubleValue ?? 24_000
        let data = try Data(contentsOf: out)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return SpeechAudio(samples: samples, sampleRate: rate)
    }

    /// Kokoro voice ids start with a language letter: a = American, b = British English.
    static func language(for voiceID: String, default fallback: String) -> String {
        switch voiceID.first {
        case "a": return "en-us"
        case "b": return "en-gb"
        default: return fallback
        }
    }

    public func shutdown() async {
        try? stdin?.close()
        process?.terminate()
        process = nil; stdin = nil; lines = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    private func start() async throws {
        if process?.isRunning == true { return }
        signal(SIGPIPE, SIG_IGN)   // a dead worker must not take the app down with it
        let fm = FileManager.default
        for (label, url) in [("Python env", config.python), ("worker", config.worker),
                             ("model", config.model), ("voices", config.voicesFile)]
        where !fm.fileExists(atPath: url.path) {
            throw TTSError.engineUnavailable("\(label) missing at \(url.path) — run Tools/kokoro/setup.sh")
        }
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = config.python
        p.arguments = ["-I", config.worker.path, "--model", config.model.path, "--voices", config.voicesFile.path]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        // Keep the worker's own messages for diagnosis (worker.log next to the worker).
        let logURL = config.worker.deletingLastPathComponent().appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        p.standardError = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        lines = LineReader(outPipe.fileHandleForReading)

        guard let ready = try await nextMessage(), ready["ready"] as? Bool == true else {
            await shutdown()
            throw TTSError.engineUnavailable("Kokoro worker failed to start")
        }
        availableVoices = ready["voices"] as? [String] ?? []
    }

    private func nextMessage() async throws -> [String: Any]? {
        while let line = try await lines?.next() {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { return obj }
        }
        return nil
    }
}

/// Owns the async line iterator outside the actor (iterators are mutated across awaits).
private final class LineReader: @unchecked Sendable {
    private var iterator: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator
    init(_ handle: FileHandle) { iterator = handle.bytes.lines.makeAsyncIterator() }
    func next() async throws -> String? { try await iterator.next() }
}
#endif
