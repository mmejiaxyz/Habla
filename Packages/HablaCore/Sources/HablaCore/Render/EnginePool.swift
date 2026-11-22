import Foundation

/// Several identical engines (e.g. two Kokoro workers) behind one `TTSEngine`: each request
/// goes to a free engine, so sentences are voiced in parallel on multi-core Macs.
/// Every engine must produce identical audio (same model), so the sentence cache stays valid.
public actor EnginePool: TTSEngine {
    public nonisolated let name: String
    public nonisolated let cacheVersion: String
    public nonisolated let size: Int
    public nonisolated let modelDescription: String
    private let engines: [TTSEngine]
    private var free: [Int]
    private var waiters: [CheckedContinuation<Int, Never>] = []

    public init(_ engines: [TTSEngine]) {
        precondition(!engines.isEmpty)
        self.engines = engines
        name = engines[0].name
        cacheVersion = engines[0].cacheVersion
        size = engines.count
        modelDescription = engines[0].modelDescription
        free = Array(engines.indices)
    }

    public func voices() async throws -> [String] { try await engines[0].voices() }

    public func synthesize(_ text: String, voice: VoiceInfo) async throws -> SpeechAudio {
        let i = await take()
        do {
            let audio = try await engines[i].synthesize(text, voice: voice)
            give(i)
            return audio
        } catch {
            give(i)
            throw error
        }
    }

    public func shutdown() async {
        for e in engines { await e.shutdown() }
    }

    private func take() async -> Int {
        if let i = free.popLast() { return i }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func give(_ i: Int) {
        if waiters.isEmpty { free.append(i) } else { waiters.removeFirst().resume(returning: i) }
    }

    /// Sensible worker count for this Mac: one per ~4 performance cores, two at most,
    /// and only one on Macs with little memory (each worker keeps the model loaded).
    public static var recommendedWorkers: Int {
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return (memoryGB >= 7.5 && cores >= 8) ? 2 : 1
    }
}
