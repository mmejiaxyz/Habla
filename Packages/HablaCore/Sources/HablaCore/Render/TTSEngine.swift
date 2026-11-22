import Foundation

/// Mono PCM audio for one sentence.
public struct SpeechAudio: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public init(samples: [Float], sampleRate: Double) { self.samples = samples; self.sampleRate = sampleRate }
    public var duration: TimeInterval { Double(samples.count) / sampleRate }
}

/// A voice. Renders run on the Mac; the iPhone only plays the results.
public protocol TTSEngine: Sendable {
    /// Stable identifier, e.g. "kokoro".
    var name: String { get }
    /// Part of the sentence cache key: bump it to invalidate cached audio.
    var cacheVersion: String { get }
    func voices() async throws -> [String]
    func synthesize(_ text: String, voice: VoiceInfo) async throws -> SpeechAudio
    /// Release the model / worker process.
    func shutdown() async
}

public extension TTSEngine {
    func shutdown() async {}
}

public enum TTSError: Error, CustomStringConvertible {
    case engineUnavailable(String)
    case synthesisFailed(String)

    public var description: String {
        switch self {
        case .engineUnavailable(let s): return "Voice engine unavailable: \(s)"
        case .synthesisFailed(let s): return "Speech synthesis failed: \(s)"
        }
    }
}

/// Deterministic test engine: a soft tone whose length follows the text length.
public struct ToneEngine: TTSEngine {
    public let name = "tone"
    public let cacheVersion = "tone-1"
    public var sampleRate = 24_000.0
    public init() {}

    public func voices() async throws -> [String] { ["tone"] }

    public func synthesize(_ text: String, voice: VoiceInfo) async throws -> SpeechAudio {
        let seconds = max(0.3, Double(text.count) * 0.055 / voice.speed)
        let n = Int(seconds * sampleRate)
        let samples = (0..<n).map { i in Float(0.15 * sin(2 * Double.pi * 220 * Double(i) / sampleRate)) }
        return SpeechAudio(samples: samples, sampleRate: sampleRate)
    }
}
