import Foundation

/// Several identical engines (e.g. four Paradee workers) behind one `TTSEngine`: each request
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

    /// Paradee workers for this Mac: each uses one CPU thread and about 0.45 GB of memory.
    /// Four saturate an M-series Mac (measured: 4 ≈ 130× real time, 8 ≈ 140×); fewer on small Macs.
    public static func recommendedWorkers(memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
                                          cores: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        let memoryGB = Double(memoryBytes) / 1_073_741_824
        let byMemory = memoryGB >= 11.5 ? 4 : memoryGB >= 7.5 ? 3 : 2
        return max(1, min(byMemory, cores / 2))
    }
}
