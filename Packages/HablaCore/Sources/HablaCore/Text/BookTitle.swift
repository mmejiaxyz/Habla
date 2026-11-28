import Foundation

/// The name a book shows outside Habla's own devices (the Xteink's catalog and its file names):
/// only its title and subtitle. Where it came from (Project Gutenberg, a university, a shop or
/// library site, a series note) is left out.
public enum BookTitle {
    static let prefixes = [
        "the project gutenberg ebook of ", "the project gutenberg e-book of ", "project gutenberg's ",
        "project gutenberg ebook of ", "the gutenberg ebook of ",
    ]
    /// Words that mark a trailing part as a source, not the title.
    static let sourceWords = [
        "gutenberg", "university", "universidad", "press", "library", "z-lib", "zlib", "ebook", "e-book",
        "edition", "standard ebooks", "archive.org", "publisher", "publishing", "books", "kindle", "epub",
    ]

    public static func clean(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for p in prefixes where t.lowercased().hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        // Trailing groups in brackets: series notes and sources, e.g. "(Book 2)", "[z-lib.org]".
        while let last = t.last, ")]}".contains(last),
              let open = t.lastIndex(where: { "([{".contains($0) }), open > t.startIndex {
            t = String(t[..<open]).trimmingCharacters(in: .whitespaces)
        }
        // "Title | Source", "Title - University Press", "Title, by Someone".
        for sep in [" | ", " — ", " – ", " - "] {
            if let r = t.range(of: sep, options: .backwards) {
                let tail = t[r.upperBound...].lowercased()
                if sep == " | " || sourceWords.contains(where: { tail.contains($0) }) { t = String(t[..<r.lowerBound]) }
            }
        }
        if let r = t.range(of: ", by ", options: [.backwards, .caseInsensitive]) { t = String(t[..<r.lowerBound]) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:-–—"))
        return t.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : t
    }
}
