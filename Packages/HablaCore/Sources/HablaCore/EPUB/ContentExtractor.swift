import Foundation

/// Turns one XHTML spine document into clean, reader-ready blocks
/// (headings, paragraphs, quotes, scene breaks) with italic/bold runs
/// and a KOReader-style source path for each block.
struct ContentExtractor {
    struct Result {
        var blocks: [TextBlock]
        /// epub:type values found on <body>/<section> (e.g. "frontmatter", "copyright-page").
        var structuralTypes: Set<String>
        var firstHeading: String?
    }

    let spineIndex: Int
    let href: String

    static let blockTags: Set<String> = [
        "p", "div", "section", "article", "aside", "header", "footer", "main", "blockquote",
        "h1", "h2", "h3", "h4", "h5", "h6", "hgroup", "li", "ul", "ol", "dl", "dt", "dd",
        "pre", "figure", "figcaption", "table", "tbody", "thead", "tr", "td", "th", "caption",
        "address", "center", "body", "nav", "hr",
    ]
    static let skipTags: Set<String> = [
        "script", "style", "head", "title", "img", "svg", "math", "object", "video", "audio",
        "iframe", "rt", "rp", "noscript", "template", "button", "input", "select", "textarea",
    ]
    /// Elements CrossPoint ignores when counting (VisibleTextUtils::isNonVisibleElement).
    static let nonVisibleTags: Set<String> = ["head", "style", "script", "title", "rp"]
    static let skipEpubTypes: Set<String> = [
        "noteref", "footnote", "endnote", "rearnote", "footnotes", "endnotes", "pagebreak", "annoref",
    ]
    static let skipRoles: Set<String> = [
        "doc-noteref", "doc-footnote", "doc-endnote", "doc-endnotes", "doc-pagebreak", "doc-backlink",
    ]

    func extract(_ data: Data) -> Result {
        guard let root = XMLTree.parse(data) else { return Result(blocks: [], structuralTypes: [], firstHeading: nil) }
        let body = root.localName == "body" ? root : (root.first("body") ?? root)

        var types = Set<String>()
        for node in [body] + body.all("section") {
            for t in (node.attr("epub:type") ?? node.attr("type") ?? "").split(separator: " ") {
                types.insert(String(t).lowercased())
            }
        }

        var builder = Builder(spineIndex: spineIndex, href: href)
        let bodyPath = "/body/DocFragment[\(spineIndex + 1)]/body"
        builder.walk(body, path: bodyPath, blockPath: bodyPath, context: .init())
        builder.flush()
        let heading = builder.blocks.first { $0.kind == .heading }?.text
        return Result(blocks: builder.blocks, structuralTypes: types, firstHeading: heading)
    }

    // MARK: - Builder

    struct Context {
        var italic = 0, bold = 0, smallCaps = 0
        var inQuote = false, inPre = false, inList = false
        var heading: Int?
    }

    struct Builder {
        let spineIndex: Int
        let href: String
        var blocks: [TextBlock] = []

        // Current block being accumulated.
        var text = ""
        var utf16Count = 0
        var lastWasSpace = true
        var styles: [StyleRun] = []
        var openStyles: [(StyleRun.Style, Int)] = []
        var kind: TextBlock.Kind = .paragraph
        var level: Int?
        var path = ""
        var anchors: [TextAnchor] = []

        init(spineIndex: Int, href: String) { self.spineIndex = spineIndex; self.href = href }

        /// `nodePath`: this element's own path; `blockPath`: the enclosing block's path.
        mutating func walk(_ node: XNode, path nodePath: String, blockPath: String, context: Context) {
            var siblingCounts: [String: Int] = [:]
            var siblingTotals: [String: Int] = [:]
            for c in node.elements { siblingTotals[c.localName, default: 0] += 1 }
            var textNodes = 0
            var closedElements = 0   // direct child elements before this point (CrossPoint's reader numbering)

            for child in node.children {
                if child.kind == .text {
                    guard !child.text.isEmpty else { continue }
                    textNodes += 1
                    if path.isEmpty { path = blockPath; configure(for: context) }
                    anchors.append(TextAnchor(offset: utf16Count, path: nodePath, node: textNodes, readerNode: closedElements + 1))
                    appendText(child.text, preserve: context.inPre, anchor: anchors.count - 1)
                    continue
                }
                if !ContentExtractor.nonVisibleTags.contains(child.localName) { closedElements += 1 }
                let name = child.localName
                siblingCounts[name, default: 0] += 1
                let seg = (siblingTotals[name] ?? 1) > 1 ? "\(name)[\(siblingCounts[name]!)]" : name
                let childPath = "\(nodePath)/\(seg)"

                if shouldSkip(child) { continue }

                if name == "br" {
                    appendRaw("\n")
                    continue
                }
                if name == "hr" {
                    flush()
                    blocks.append(TextBlock(kind: .sceneBreak, level: nil, text: "", styles: [], sentences: [],
                                            source: SourceRef(spineIndex: spineIndex, href: href, xpointer: childPath)))
                    continue
                }

                var ctx = context
                switch name {
                case "em", "i", "cite", "dfn", "var": ctx.italic += 1
                case "strong", "b": ctx.bold += 1
                case "blockquote": ctx.inQuote = true
                case "pre": ctx.inPre = true
                case "li", "dd", "dt": ctx.inList = true
                case "h1", "h2", "h3", "h4", "h5", "h6": ctx.heading = Int(String(name.last!))
                default: break
                }
                let cls = (child.attr("class") ?? "").lowercased()
                if cls.contains("smallcaps") || cls.contains("small-caps") || cls.contains("sc") && cls.split(separator: " ").contains("sc") {
                    ctx.smallCaps += 1
                }
                // Inline italics expressed via class names are common in older EPUBs.
                if cls.split(separator: " ").contains(where: { $0 == "italic" || $0 == "ital" || $0 == "i" || $0 == "em" }) {
                    ctx.italic += 1
                }

                if Self.isBlock(name) {
                    flush()
                    walk(child, path: childPath, blockPath: childPath, context: ctx)
                    flush()
                } else {
                    let starts = styleStarts(from: context, to: ctx)
                    for s in starts { openStyles.append((s, utf16Count)) }
                    walk(child, path: childPath, blockPath: blockPath, context: ctx)
                    for s in starts.reversed() { closeStyle(s) }
                }
            }
        }

        func shouldSkip(_ n: XNode) -> Bool {
            if ContentExtractor.skipTags.contains(n.localName) { return true }
            let types = (n.attr("epub:type") ?? "").lowercased().split(separator: " ").map(String.init)
            if types.contains(where: ContentExtractor.skipEpubTypes.contains) { return true }
            if let role = n.attr("role")?.lowercased(), ContentExtractor.skipRoles.contains(role) { return true }
            // Footnote blocks marked only by class (many EPUBs have no epub:type): same as above.
            if ["aside", "div", "section", "p", "ol", "ul", "li", "dl"].contains(n.localName),
               let cls = n.attr("class")?.lowercased(),
               cls.split(whereSeparator: { $0 == " " }).contains(where: { ["footnote", "footnotes", "endnote", "endnotes"].contains($0) }) {
                return true
            }
            if n.attr("hidden") != nil || (n.attr("style") ?? "").replacingOccurrences(of: " ", with: "").contains("display:none") {
                return true
            }
            // Superscript note markers like <sup><a href="#fn1">1</a></sup>.
            if n.localName == "sup" || n.localName == "a" {
                let t = n.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                let linksToNote = n.localName == "a" ? (n.attr("href")?.contains("#") ?? false)
                                                     : n.first("a")?.attr("href")?.contains("#") ?? false
                if linksToNote, t.count <= 4, t.allSatisfy({ $0.isNumber || "*†‡§[]".contains($0) || $0.isLetter && t.count == 1 }) {
                    return true
                }
            }
            return false
        }

        static func isBlock(_ name: String) -> Bool { ContentExtractor.blockTags.contains(name) }

        func styleStarts(from a: Context, to b: Context) -> [StyleRun.Style] {
            var out: [StyleRun.Style] = []
            if a.italic == 0 && b.italic > 0 { out.append(.italic) }
            if a.bold == 0 && b.bold > 0 { out.append(.bold) }
            if a.smallCaps == 0 && b.smallCaps > 0 { out.append(.smallCaps) }
            return out
        }

        mutating func closeStyle(_ style: StyleRun.Style) {
            guard let i = openStyles.lastIndex(where: { $0.0 == style }) else { return }
            let start = openStyles.remove(at: i).1
            if utf16Count > start {
                styles.append(StyleRun(range: TextRange(location: start, length: utf16Count - start), style: style))
            }
        }

        mutating func configure(for ctx: Context) {
            if let h = ctx.heading { kind = .heading; level = h }
            else if ctx.inPre { kind = .preformatted }
            else if ctx.inQuote { kind = .quote }
            else if ctx.inList { kind = .listItem }
            else { kind = .paragraph }
        }

        /// Appends a source text node, collapsing whitespace like a browser, and records where the
        /// displayed text diverges from the raw source (so e-reader offsets, counted in raw code
        /// points, map exactly). Invisible characters (soft hyphen, ZWSP, word joiner) are kept.
        mutating func appendText(_ s: String, preserve: Bool, anchor: Int? = nil) {
            if preserve { appendRaw(s); return }
            let start = utf16Count
            var raw = 0
            var gaps: [[Int]] = []
            for scalar in s.unicodeScalars {
                raw += 1
                if scalar != "\u{00A0}" && CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    if !lastWasSpace { appendRaw(" ") }
                    else {
                        // Skipped (collapsed) whitespace: display stays, raw advances.
                        let d = utf16Count - start
                        if let last = gaps.last, last[0] == d { gaps[gaps.count - 1][1] = raw } else { gaps.append([d, raw]) }
                    }
                } else {
                    appendRaw(String(scalar))
                }
            }
            if let anchor, !gaps.isEmpty { anchors[anchor].gaps = gaps }
        }

        mutating func appendRaw(_ s: String) {
            if s == "\n" {
                // Trim trailing space before a line break.
                if text.hasSuffix(" ") { text.removeLast(); utf16Count -= 1 }
                if text.isEmpty { return }
            }
            text += s
            utf16Count += s.utf16.count
            lastWasSpace = s == " " || s == "\n"
        }

        mutating func flush() {
            // Close styles still open at block end, then reopen them for the next block.
            let stillOpen = openStyles
            for (s, _) in stillOpen.reversed() { closeStyle(s) }

            var t = text
            var leading = 0
            while let f = t.first, f == " " || f == "\n" { t.removeFirst(); leading += 1 }
            while let l = t.last, l == " " || l == "\n" { t.removeLast() }
            let length = t.utf16.count

            if !t.isEmpty {
                let adjusted = styles.compactMap { run -> StyleRun? in
                    let start = max(0, run.range.location - leading)
                    let end = min(length, run.range.location + run.range.length - leading)
                    return end > start ? StyleRun(range: TextRange(location: start, length: end - start), style: run.style) : nil
                }
                var k = kind
                if Self.isSceneBreakText(t) { k = .sceneBreak }
                let shifted = anchors.map { a -> TextAnchor in
                    var a = a; a.offset = min(length, max(0, a.offset - leading)); return a
                }
                var block = TextBlock(
                    kind: k, level: k == .heading ? level : nil,
                    text: k == .sceneBreak ? "" : t, styles: k == .sceneBreak ? [] : adjusted, sentences: [],
                    source: SourceRef(spineIndex: spineIndex, href: href, xpointer: path))
                block.anchors = k == .sceneBreak ? nil : shifted
                blocks.append(block)
            }
            text = ""; utf16Count = 0; lastWasSpace = true; styles = []; path = ""; level = nil; kind = .paragraph
            anchors = []
            openStyles = stillOpen.map { ($0.0, 0) }
        }

        static func isSceneBreakText(_ t: String) -> Bool {
            let stripped = t.filter { !$0.isWhitespace }
            guard !stripped.isEmpty, stripped.count <= 12 else { return false }
            return stripped.allSatisfy { "*⁂•·~#-–—=_◆◇❧☙✻✦".contains($0) }
        }
    }
}
