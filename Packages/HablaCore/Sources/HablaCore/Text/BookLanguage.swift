import Foundation
import NaturalLanguage

/// The languages Habla reads, and which of them can be narrated (Kokoro on the Mac, Paradee on
/// the iPhone: the same languages, more voices on the Mac).
///
/// Reading works for all of them (text, layout, hyphenation, Find, dictionary, translate).
/// Narration needs a Paradee voice: English and Spanish have one. Other languages (German,
/// Russian, Ukrainian, French, Hindi…) are read-only instead of being read with the wrong accent.
public enum BookLanguage {
    public static let supported = ["en", "es", "de", "ru", "uk"]

    /// "en-US" → "en", "ukr" → "uk", "spa" → "es", "deu"/"ger" → "de", "rus" → "ru".
    public static func normalize(_ code: String?) -> String? {
        guard let raw = code?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        let base = String(raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(raw))
        switch base {
        case "eng": return "en"
        case "spa", "esp": return "es"
        case "deu", "ger": return "de"
        case "rus": return "ru"
        case "ukr": return "uk"
        default: return base
        }
    }

    /// The book's language: what the text really is, when the recogniser is confident;
    /// otherwise what the EPUB declares; English as a last resort.
    public static func detect(declared: String?, sample: String) -> String {
        let declaredCode = normalize(declared)
        let r = NLLanguageRecognizer()
        r.processString(String(sample.prefix(4000)))
        if let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p > 0.75 {
            let code = normalize(lang.rawValue) ?? "en"
            // Trust the declaration when it agrees, or when the text is too short to judge.
            if code != declaredCode, sample.count > 200 { return code }
        }
        return declaredCode ?? "en"
    }

    /// The voice models. Kokoro narrates on the Mac; Paradee (distilled from Kokoro, fewer
    /// voices) is the iPhone's backup.
    public enum Narrator: Sendable { case kokoro, paradee }

    /// There is a voice for this language.
    public static func hasVoice(_ lang: String) -> Bool { ["en", "es"].contains(normalize(lang) ?? lang) }

    /// Voices offered for a book in this language (first is the default). Languages without a voice
    /// fall back to the English voices, so old voice ids still map somewhere — everything that starts
    /// narration or offers a voice picker must check `hasVoice` first.
    public static func voices(for lang: String, narrator: Narrator = .paradee) -> [String] {
        switch (normalize(lang), narrator) {
        case ("es", .paradee): return ["em_alex"]
        case ("es", .kokoro): return ["ef_dora", "em_alex", "em_santa"]
        case (_, .paradee): return ["af_heart", "am_puck", "bf_isabella", "bm_fable"]
        case (_, .kokoro): return ["af_heart", "af_bella", "af_nicole", "af_sarah", "am_michael", "am_fenrir", "am_puck",
                                   "bf_emma", "bf_isabella", "bm_george", "bm_fable"]
        }
    }

    public static func defaultVoice(for lang: String, narrator: Narrator = .paradee) -> String { voices(for: lang, narrator: narrator)[0] }

    /// Does this voice speak this language? (Voice ids start with a language letter.)
    public static func voice(_ id: String, speaks lang: String, narrator: Narrator = .paradee) -> Bool {
        voices(for: lang, narrator: narrator).contains(id)
    }

    /// The closest available voice to one chosen earlier (e.g. a Kokoro voice Paradee doesn't have):
    /// same accent and gender when possible, else the language's default.
    public static func closestVoice(to id: String, for lang: String, narrator: Narrator = .paradee) -> String {
        let available = voices(for: lang, narrator: narrator)
        if available.contains(id) { return id }
        return available.first { $0.prefix(2) == id.prefix(2) } ?? defaultVoice(for: lang, narrator: narrator)
    }

    /// Word used for numbered chapters in this language.
    public static func chapterWord(_ lang: String) -> String {
        switch normalize(lang) {
        case "es": return "Capítulo"
        case "de": return "Kapitel"
        case "ru": return "Глава"
        case "uk": return "Розділ"
        default: return "Chapter"
        }
    }

    public static func partWord(_ lang: String) -> String {
        switch normalize(lang) {
        case "es": return "Parte"
        case "de": return "Teil"
        case "ru": return "Часть"
        case "uk": return "Частина"
        default: return "Part"
        }
    }

    /// English name, for messages ("No German voice yet").
    public static func name(_ lang: String) -> String {
        let code = normalize(lang) ?? lang
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }
}
