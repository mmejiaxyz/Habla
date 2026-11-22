import Foundation
import HablaCore

/// Paradee 1.3 running on the device: the same voice, model file and pronunciation rules as Habla
/// for Mac (`VoiceEngine`, Python), ported to Swift. Same `cacheVersion`, so a sentence voiced on
/// either device is interchangeable. Habla narrates English and Spanish only.
///
/// Port of `paradee.tts.Paradee.__call__`: sentences → phonemes (misaki-style English, or
/// Paradee's own G2P for Spanish) → runs of at most 510 phonemes cut at a space → the model.
/// The model and dictionaries load on first use (about a second) and stay until `shutdown()`.
public final class ParadeeEngine: TTSEngine, @unchecked Sendable {
    public let name = "paradee"
    public let cacheVersion = "paradee-1.3"
    public let modelDescription = "Paradee 1.3"
    /// The voices Habla offers (Paradee also has French and Hindi ones; Habla doesn't use them).
    public static let voiceIDs = ["af_heart", "am_puck", "bf_isabella", "bm_fable", "em_alex"]

    private let queue = DispatchQueue(label: "habla.paradee", qos: .utility)
    private var model: ParadeeModel?
    private var g2p: ParadeeG2P?
    private var english: [Bool: EnglishG2P] = [:]   // keyed by british

    public init() {}

    public func voices() async throws -> [String] { Self.voiceIDs }

    public func synthesize(_ text: String, voice: VoiceInfo) async throws -> SpeechAudio {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<SpeechAudio, Error>) in
            queue.async {
                c.resume(with: Result { try self.speak(text, voice: voice.voiceID, speed: voice.speed) })
            }
        }
    }

    public func shutdown() async {
        queue.sync { model = nil; g2p = nil; english = [:] }
    }

    // MARK: On the engine's queue

    private func speak(_ text: String, voice: String, speed: Double) throws -> SpeechAudio {
        guard Self.voiceIDs.contains(voice) else { throw ParadeeError.unknownVoice(voice) }
        let model = try loadedModel()
        var samples: [Float] = []
        for sentence in Self.sentences(text) {
            var ps = try phonemize(sentence, voice: voice)
            // A very long sentence: cut at the last space that fits, as Python does.
            while ps.unicodeScalars.count > ParadeeModel.maxPhonemes {
                let scalars = Array(ps.unicodeScalars)
                let head = scalars[..<ParadeeModel.maxPhonemes]
                let cut = head.lastIndex(of: " ").flatMap { $0 > 0 ? $0 : nil } ?? ParadeeModel.maxPhonemes
                samples += try model.generate(phonemes: String(String.UnicodeScalarView(scalars[..<cut])), speed: speed, voice: voice)
                ps = String(String.UnicodeScalarView(scalars[cut...])).trimmingCharacters(in: .whitespaces)
            }
            if !ps.isEmpty { samples += try model.generate(phonemes: ps, speed: speed, voice: voice) }
        }
        return SpeechAudio(samples: samples, sampleRate: ParadeeModel.sampleRate)
    }

    private func phonemize(_ sentence: String, voice: String) throws -> String {
        let g2p = try loadedG2P()
        switch voice.first {
        case "e": return try g2p.g2p(sentence, lang: "es")
        default:
            let british = voice.first == "b"
            if english[british] == nil { english[british] = try EnglishG2P(british: british, g2p: g2p) }
            return try english[british]!.phonemize(sentence)
        }
    }

    private func loadedModel() throws -> ParadeeModel {
        if let model { return model }
        let m = try ParadeeModel(model: ParadeeResources.url("paradee_int8.onnx"), config: ParadeeResources.url("paradee_config.json"))
        model = m
        return m
    }

    private func loadedG2P() throws -> ParadeeG2P {
        if let g2p { return g2p }
        let g = try ParadeeG2P()
        g2p = g
        return g
    }

    /// `Paradee._sentences`: split after . ! ? … followed by space, and at line breaks.
    static func sentences(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let re = try? NSRegularExpression(pattern: #"(?<=[.!?…])\s+|\n+"#) else { return [trimmed] }
        let ns = trimmed as NSString
        var out: [String] = [], start = 0
        for m in re.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            start = NSMaxRange(m.range)
        }
        out.append(ns.substring(from: start))
        return out.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
