import Foundation
import AVFoundation

/// Re-saves chapter audio made with the older, larger setting (AAC 64 kbps) as HE-AAC 24 kbps.
/// The audio is decoded and encoded again, not narrated again; timings stay valid (the file
/// keeps its exact length).
public enum AudioUpgrade {
    /// Above this the file is in the older format (HE-AAC 24 kbps measures ~24–25 kbps).
    static let oldFormatBitsPerSecond = 40_000.0

    static func needsUpgrade(_ url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int),
              let f = try? AVAudioFile(forReading: url) else { return false }
        let seconds = Double(f.length) / f.fileFormat.sampleRate
        return seconds > 1 && Double(size) * 8 / seconds > oldFormatBitsPerSecond
    }

    /// Converts one file in place (written beside it first, swapped in only when complete).
    static func convert(_ url: URL) throws {
        let input = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        let tmp = url.deletingPathExtension().appendingPathExtension("writing.m4a")
        try? FileManager.default.removeItem(at: tmp)
        do {
            let settings: [String: Any] = [AVFormatIDKey: AudioAssembler.formatID, AVSampleRateKey: format.sampleRate,
                                           AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: AudioAssembler().bitRate]
            let out = try AVAudioFile(forWriting: tmp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { throw TTSError.synthesisFailed("audio buffer") }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try out.write(from: buffer)
            }
        }   // closes the output file
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// Upgrades every narrated chapter of a book still in the older format, then records the
    /// new files (a new revision, so the smaller audio reaches the other devices). Returns
    /// whether anything changed.
    @discardableResult
    public static func upgrade(_ bundle: BookBundle) throws -> Bool {
        let m = try bundle.manifest()
        var changed = false
        for c in m.chapters where c.audioStatus == .ready {
            guard let path = c.audioFile else { continue }
            let url = bundle.fileURL(path)
            guard FileManager.default.fileExists(atPath: url.path), needsUpgrade(url) else { continue }
            try convert(url)
            changed = true
        }
        if changed { _ = try bundle.commit(try bundle.manifest()) }
        return changed
    }
}
