import Foundation
import AVFoundation

/// Joins sentence clips into one chapter file (AAC .m4a), with natural pauses,
/// silence trimming and tiny fades so joins never click. Records sentence timings.
struct AudioAssembler {
    var bitRate = 64_000
    /// Fade length at each clip edge.
    var fade: TimeInterval = 0.008
    /// Silence kept at clip edges after trimming the engine's own padding.
    var edgePadding: TimeInterval = 0.03

    struct Clip {
        var sentenceID: Int
        var audio: SpeechAudio
        var pauseAfter: TimeInterval
    }

    /// Streams sentence clips into a chapter file as they are synthesised (constant memory),
    /// into `<url>.part`, swapped in only when complete — a phone syncing meanwhile never sees half a chapter.
    final class Writer {
        let assembler: AudioAssembler
        let url: URL
        let leadIn: TimeInterval
        private var file: AVAudioFile?
        private var format: AVAudioFormat?
        private var rate: Double = 24_000
        private var position = 0
        private(set) var timings: [SentenceTiming] = []

        init(assembler: AudioAssembler, url: URL, leadIn: TimeInterval = 0.35) {
            self.assembler = assembler; self.url = url; self.leadIn = leadIn
        }

        var partURL: URL { url.appendingPathExtension("part") }

        func append(_ clip: Clip) throws {
            if file == nil { try open(rate: clip.audio.sampleRate) }
            let samples = clip.audio.sampleRate == rate ? clip.audio.samples : []
            let start = Double(position) / rate
            try write(assembler.shape(samples, rate: rate))
            timings.append(SentenceTiming(id: clip.sentenceID, start: start, end: Double(position) / rate))
            try write([Float](repeating: 0, count: Int(clip.pauseAfter * rate)))
        }

        func finish() throws -> (duration: TimeInterval, timings: [SentenceTiming]) {
            if file == nil { try open(rate: rate) }
            close()      // finalises the AAC file and moves it to <url>.part
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: partURL) }
            else { try fm.moveItem(at: partURL, to: url) }
            return (Double(position) / rate, timings)
        }

        func discard() {
            file = nil
            if let tmp = pendingRename { try? FileManager.default.removeItem(at: tmp) }
            try? FileManager.default.removeItem(at: partURL)
        }

        private func open(rate r: Double) throws {
            rate = r
            guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: r, channels: 1, interleaved: false)
            else { throw TTSError.synthesisFailed("audio format") }
            format = f
            try? FileManager.default.removeItem(at: partURL)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: r,
                                           AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: assembler.bitRate]
            // AVAudioFile picks the container from the extension; write as .m4a then rename.
            let tmp = partURL.deletingPathExtension().deletingPathExtension().appendingPathExtension("writing.m4a")
            try? FileManager.default.removeItem(at: tmp)
            file = try AVAudioFile(forWriting: tmp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            pendingRename = tmp
            try write([Float](repeating: 0, count: Int(leadIn * r)))
        }

        private var pendingRename: URL?

        private func write(_ samples: [Float]) throws {
            guard !samples.isEmpty, let file, let format,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
            position += samples.count
        }

        deinit { file = nil }

        func close() {
            file = nil
            if let tmp = pendingRename {
                try? FileManager.default.removeItem(at: partURL)
                try? FileManager.default.moveItem(at: tmp, to: partURL)
                pendingRename = nil
            }
        }
    }

    func write(_ clips: [Clip], leadIn: TimeInterval = 0.35, to url: URL) throws -> (duration: TimeInterval, timings: [SentenceTiming]) {
        let rate = clips.first?.audio.sampleRate ?? 24_000
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        else { throw TTSError.synthesisFailed("audio format") }

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        var position = 0  // samples written
        var timings: [SentenceTiming] = []

        func append(_ samples: [Float]) throws {
            guard !samples.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
            else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
            try file.write(from: buffer)
            position += samples.count
        }

        try append([Float](repeating: 0, count: Int(leadIn * rate)))
        for clip in clips {
            precondition(clip.audio.sampleRate == rate, "all clips must share a sample rate")
            let shaped = shape(clip.audio.samples, rate: rate)
            let start = Double(position) / rate
            try append(shaped)
            timings.append(SentenceTiming(id: clip.sentenceID, start: start, end: Double(position) / rate))
            try append([Float](repeating: 0, count: Int(clip.pauseAfter * rate)))
        }
        return (Double(position) / rate, timings)
    }

    /// Trim leading/trailing near-silence, keep a little air, fade the edges.
    func shape(_ input: [Float], rate: Double) -> [Float] {
        let threshold: Float = 0.004
        guard let first = input.firstIndex(where: { abs($0) > threshold }),
              let last = input.lastIndex(where: { abs($0) > threshold }) else { return [] }
        let pad = Int(edgePadding * rate)
        var out = Array(input[max(0, first - pad)...min(input.count - 1, last + pad)])
        let n = min(Int(fade * rate), out.count / 2)
        for i in 0..<n {
            let g = Float(i) / Float(n)
            out[i] *= g
            out[out.count - 1 - i] *= g
        }
        return out
    }
}
