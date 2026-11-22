import Foundation

/// Paradee 1.3's acoustic model: phonemes → 24 kHz audio. A Swift port of `paradee.tts.Paradee._run`.
final class ParadeeModel: @unchecked Sendable {
    static let sampleRate = 24_000.0
    /// The text side has 512 positions, two of which are the pad tokens at each end.
    static let maxPhonemes = 510
    /// The voices of 1.3, in the order the model numbers them. This is the model's own numbering
    /// (the engine feeds this index to ONNX), not what the app offers: Habla narrates English and
    /// Spanish only — `BookLanguage.voices(for:)` decides what users see.
    static let voices = ["af_heart", "bf_isabella", "am_puck", "bm_fable", "hf_alpha", "hm_omega", "ff_siwis", "em_alex"]

    /// Keyed by Unicode scalar, as Python iterates strings (a French "ɔ̃" is two ids).
    let vocab: [Unicode.Scalar: Int64]
    private let session: ONNXSession

    init(model: URL, config: URL, threads: Int = 1) throws {
        struct Config: Decodable { var vocab: [String: Int64] }
        let cfg = try JSONDecoder().decode(Config.self, from: Data(contentsOf: config))
        var vocab: [Unicode.Scalar: Int64] = [:]
        for (k, v) in cfg.vocab { if k.unicodeScalars.count == 1, let c = k.unicodeScalars.first { vocab[c] = v } }
        self.vocab = vocab
        session = try ONNXSession(modelData: Data(contentsOf: model), threads: threads)
    }

    /// One run of the model. Phonemes outside the vocabulary are dropped, as in Python.
    func generate(phonemes: String, speed: Double, voice: String) throws -> [Float] {
        guard let v = Self.voices.firstIndex(of: voice) else { throw ParadeeError.unknownVoice(voice) }
        let ids = [Int64(0)] + phonemes.unicodeScalars.compactMap { vocab[$0] }.prefix(Self.maxPhonemes) + [0]
        let out = try session.run([
            ("input_ids", .int64(ids, shape: [1, Int64(ids.count)])),
            ("speed", .float([Float(speed)], shape: [1])),
            ("voice", .int64([Int64(v)], shape: [1])),
        ], outputs: ["waveform"])
        return out[0].floats
    }
}

public enum ParadeeError: Error, CustomStringConvertible {
    case unknownVoice(String)
    case missingResource(String)
    public var description: String {
        switch self {
        case .unknownVoice(let v): return "Paradee has no voice \(v)"
        case .missingResource(let r): return "Paradee's \(r) is missing from the app"
        }
    }
}
