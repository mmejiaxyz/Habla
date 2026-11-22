import SwiftUI
import HablaCore

/// The book's imprint (colophon): which voice model narrated it, in which voice, and when
/// Habla prepared it. Shown on the book page (iPhone) and the book detail (Mac).
public enum Imprint {
    public static func lines(_ m: BookManifest) -> [String] {
        var out: [String] = []
        let narrated = m.chapters.contains { $0.audioStatus == .ready }
        if narrated {
            var models = m.narrationModels
            if models.isEmpty { models = ["Kokoro v1.0"] }          // narrated before models were recorded
            let voice = m.voice.map { " · voice \(voiceName($0.voiceID))" } ?? ""
            out.append("Narrated with \(models.joined(separator: " and "))\(voice)")
            if m.narrationModels.count > 1 { out.append("Narrated across a model change; later chapters use the newer model.") }
        } else {
            out.append("Not narrated yet")
        }
        out.append("Prepared by Habla on \(m.createdAt.formatted(date: .long, time: .omitted))")
        if !m.sourceFileName.isEmpty { out.append("From \(m.sourceFileName)") }
        return out
    }

    /// The app's About lines: version, and the voice models behind the books on this device.
    public static func about(models: [String], engine: String? = nil) -> [String] {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        var out = ["Habla \(version) (build \(build))"]
        if let engine { out.append("Voice engine: \(engine)") }
        out.append(models.isEmpty ? "No narrated books yet" : "Books narrated with \(models.joined(separator: " and "))")
        out.append("Narration made on your Mac with Kokoro, free and offline")
        return out
    }

    /// "af_heart" → "Heart", "bm_george" → "George".
    public static func voiceName(_ id: String) -> String {
        (id.split(separator: "_").last.map(String.init) ?? id).capitalized
    }
}
