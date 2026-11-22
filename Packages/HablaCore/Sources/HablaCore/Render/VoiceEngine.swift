#if os(macOS)
import Foundation

/// Habla's voice: Paradee (an 8M-parameter model distilled from Kokoro) in a long-running
/// Python worker (`Tools/voice/paradee_worker.py`). The worker loads the model once and keeps it
/// until `shutdown()`. One thread per worker: Habla runs several workers in an `EnginePool`.
public actor VoiceEngine: TTSEngine {
    public nonisolated let name = "paradee"
    /// Cached sentences are only reused for the same engine and version.
    public nonisolated let cacheVersion = "paradee-1.3"
    public nonisolated let modelDescription = "Paradee 1.3"

    public struct Configuration: Sendable {
        public var python: URL
        public var worker: URL
        /// Where the model lives (HF_HOME); nothing is downloaded at run time.
        public var home: URL

        public init(python: URL, worker: URL, home: URL) {
            self.python = python; self.worker = worker; self.home = home
        }

        /// Layout produced by `Tools/voice/install.sh`.
        public init(toolsDirectory dir: URL) {
            self.init(python: dir.appendingPathComponent(".venv/bin/python"),
                      worker: dir.appendingPathComponent("paradee_worker.py"),
                      home: dir.appendingPathComponent("hf", isDirectory: true))
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
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("habla-voice-\(UUID().uuidString)")
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

        let request: [String: Any] = ["text": text, "voice": voice.voiceID, "speed": voice.speed, "out": out.path]
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)
        do { try stdin?.write(contentsOf: line) }
        catch { await shutdown(); throw TTSError.synthesisFailed("voice worker stopped") }

        // Watchdog: a worker that hangs is killed, which ends the wait below.
        let proc = process
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if !Task.isCancelled { proc?.terminate() }
        }
        defer { watchdog.cancel() }
        guard let reply = try await nextMessage() else {
            await shutdown()
            throw TTSError.synthesisFailed("voice worker exited")
        }
        guard reply["ok"] as? Bool == true else {
            throw TTSError.synthesisFailed(reply["error"] as? String ?? "unknown error")
        }
        let rate = (reply["sample_rate"] as? NSNumber)?.doubleValue ?? 24_000
        let data = try Data(contentsOf: out)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return SpeechAudio(samples: samples, sampleRate: rate)
    }

    public func shutdown() async {
        try? stdin?.close()
        process?.terminate()
        process = nil; stdin = nil; lines = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    /// How long the worker may take to load the model before it's considered stuck.
    public static var startTimeout: TimeInterval = 90

    private func start() async throws {
        if process?.isRunning == true { return }
        signal(SIGPIPE, SIG_IGN)   // a dead worker must not take the app down with it
        let fm = FileManager.default
        for (label, url) in [("Python environment", config.python), ("worker", config.worker), ("voice model", config.home)]
        where !fm.fileExists(atPath: url.path) {
            throw TTSError.engineUnavailable("The voice engine isn't installed (\(label) missing). Install it from Habla on your Mac.")
        }
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = config.python
        p.arguments = ["-I", config.worker.path]
        p.environment = ["HF_HOME": config.home.path, "HF_HUB_OFFLINE": "1", "PYTHONUNBUFFERED": "1",
                         "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        // Keep the worker's own messages for diagnosis (worker.log next to the worker). Appended,
        // so a restart after a crash keeps the crash; trimmed when it grows past 1 MB.
        let logURL = config.worker.deletingLastPathComponent().appendingPathComponent("worker.log")
        if ((try? fm.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0) > 1_000_000 {
            try? fm.removeItem(at: logURL)
        }
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        let log = try? FileHandle(forWritingTo: logURL)
        _ = try? log?.seekToEnd()
        try? log?.write(contentsOf: Data("\n--- worker started \(Date().formatted(.iso8601)) ---\n".utf8))
        p.standardError = log ?? FileHandle.nullDevice
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        lines = LineReader(outPipe.fileHandleForReading)

        // Loading the model takes a few seconds; a worker that hangs here (damaged model, stuck
        // disk) is stopped instead of blocking narration forever.
        let starting = p
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.startTimeout * 1_000_000_000))
            if !Task.isCancelled { starting.terminate() }
        }
        defer { watchdog.cancel() }
        guard let ready = try await nextMessage(), ready["ready"] as? Bool == true else {
            await shutdown()
            throw TTSError.engineUnavailable("The voice engine didn't start. Try installing it again.")
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
