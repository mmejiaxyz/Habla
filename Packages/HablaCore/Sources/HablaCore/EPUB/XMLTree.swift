import Foundation

/// Tiny DOM. EPUB XHTML is *supposed* to be well-formed XML; when it isn't,
/// we fall back to a forgiving tag-soup parser so one bad file doesn't sink a book.
final class XNode {
    enum Kind { case element, text }

    let kind: Kind
    let name: String          // qualified name as written ("dc:title", "p")
    var attributes: [String: String]
    var children: [XNode] = []
    var text: String          // for text nodes
    weak var parent: XNode?

    init(element name: String, attributes: [String: String] = [:]) {
        kind = .element; self.name = name; self.attributes = attributes; text = ""
    }

    init(text: String) {
        kind = .text; name = "#text"; attributes = [:]; self.text = text
    }

    /// Name without namespace prefix, lowercased.
    var localName: String {
        let n = name.split(separator: ":").last.map(String.init) ?? name
        return n.lowercased()
    }

    func attr(_ key: String) -> String? {
        if let v = attributes[key] { return v }
        // Match ignoring namespace prefix (e.g. "epub:type" vs "type", "opf:role").
        let lk = key.lowercased()
        return attributes.first { k, _ in
            let local = k.split(separator: ":").last.map { String($0).lowercased() } ?? k.lowercased()
            return local == lk || k.lowercased() == lk
        }?.value
    }

    var elements: [XNode] { children.filter { $0.kind == .element } }

    func first(_ local: String) -> XNode? {
        for c in elements {
            if c.localName == local { return c }
            if let f = c.first(local) { return f }
        }
        return nil
    }

    func all(_ local: String) -> [XNode] {
        var out: [XNode] = []
        for c in elements {
            if c.localName == local { out.append(c) }
            out.append(contentsOf: c.all(local))
        }
        return out
    }

    func child(_ local: String) -> XNode? { elements.first { $0.localName == local } }

    var textContent: String {
        kind == .text ? text : children.map(\.textContent).joined()
    }

    func append(_ node: XNode) { node.parent = self; children.append(node) }
}

enum XMLTree {
    static func parse(_ data: Data) -> XNode? {
        let cleaned = sanitize(data)
        if let root = StrictBuilder.parse(cleaned) { return root }
        return SoupParser.parse(String(decoding: cleaned, as: UTF8.self))
    }

    static func parse(_ string: String) -> XNode? { parse(Data(string.utf8)) }

    /// Replace HTML named entities (undefined in plain XML) with numeric references.
    static func sanitize(_ data: Data) -> Data {
        var s = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        // XMLParser drops U+FEFF (zero-width no-break space) inside text; e-readers count it.
        // U+2060 (word joiner) is the same invisible character and survives parsing.
        if s.unicodeScalars.contains("\u{FEFF}") {
            if s.hasPrefix("\u{FEFF}") { s.removeFirst() }      // a real byte-order mark
            s = s.replacingOccurrences(of: "\u{FEFF}", with: "\u{2060}")
        }
        guard s.contains("&") else { return Data(s.utf8) }
        let pattern = try! NSRegularExpression(pattern: "&([A-Za-z][A-Za-z0-9]*);")
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in pattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            if ["amp", "lt", "gt", "quot", "apos"].contains(name) {
                result += ns.substring(with: m.range)
            } else if let cp = htmlEntities[name] {
                result += "&#\(cp);"
            } else {
                result += "&amp;\(name);"
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        s = result
        return Data(s.utf8)
    }

    static let htmlEntities: [String: Int] = [
        "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "yen": 165, "sect": 167, "copy": 169,
        "laquo": 171, "reg": 174, "deg": 176, "plusmn": 177, "para": 182, "middot": 183, "raquo": 187,
        "frac14": 188, "frac12": 189, "frac34": 190, "iquest": 191, "times": 215, "divide": 247,
        "Agrave": 192, "Aacute": 193, "Acirc": 194, "Atilde": 195, "Auml": 196, "Aring": 197, "AElig": 198,
        "Ccedil": 199, "Egrave": 200, "Eacute": 201, "Ecirc": 202, "Euml": 203, "Igrave": 204, "Iacute": 205,
        "Icirc": 206, "Iuml": 207, "Ntilde": 209, "Ograve": 210, "Oacute": 211, "Ocirc": 212, "Otilde": 213,
        "Ouml": 214, "Oslash": 216, "Ugrave": 217, "Uacute": 218, "Ucirc": 219, "Uuml": 220, "szlig": 223,
        "agrave": 224, "aacute": 225, "acirc": 226, "atilde": 227, "auml": 228, "aring": 229, "aelig": 230,
        "ccedil": 231, "egrave": 232, "eacute": 233, "ecirc": 234, "euml": 235, "igrave": 236, "iacute": 237,
        "icirc": 238, "iuml": 239, "ntilde": 241, "ograve": 242, "oacute": 243, "ocirc": 244, "otilde": 245,
        "ouml": 246, "oslash": 248, "ugrave": 249, "uacute": 250, "ucirc": 251, "uuml": 252, "yuml": 255,
        "OElig": 338, "oelig": 339, "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217,
        "sbquo": 8218, "ldquo": 8220, "rdquo": 8221, "bdquo": 8222, "dagger": 8224, "Dagger": 8225,
        "bull": 8226, "hellip": 8230, "prime": 8242, "Prime": 8243, "lsaquo": 8249, "rsaquo": 8250,
        "euro": 8364, "trade": 8482, "thinsp": 8201, "ensp": 8194, "emsp": 8195, "zwnj": 8204, "zwj": 8205,
        "shy": 173, "larr": 8592, "rarr": 8594, "minus": 8722,
    ]
}

// MARK: - Strict (XMLParser)

private final class StrictBuilder: NSObject, XMLParserDelegate {
    var stack: [XNode] = []
    var root: XNode?
    var failed = false

    static func parse(_ data: Data) -> XNode? {
        let b = StrictBuilder()
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = false
        p.shouldResolveExternalEntities = false
        p.delegate = b
        let ok = p.parse()
        return ok && !b.failed ? b.root : nil
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let n = XNode(element: name, attributes: attributes)
        if let top = stack.last { top.append(n) } else { root = n }
        stack.append(n)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // XMLParser may deliver one DOM text node in pieces (around entities); keep it one node,
        // as e-readers count text nodes (KOReader/CrossPoint `text()[N]`).
        if let last = stack.last?.children.last, last.kind == .text { last.text += string; return }
        stack.last?.append(XNode(text: string))
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        stack.last?.append(XNode(text: String(decoding: data, as: UTF8.self)))
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { failed = true }
}

// MARK: - Tag soup fallback

private enum SoupParser {
    static let voidElements: Set<String> = [
        "br", "hr", "img", "meta", "link", "input", "col", "area", "base", "wbr", "source",
    ]

    static func parse(_ s: String) -> XNode? {
        let root = XNode(element: "#document")
        var stack = [root]
        let tag = try! NSRegularExpression(
            pattern: "<!--.*?-->|<!\\[CDATA\\[.*?\\]\\]>|<[!?][^>]*>|<(/?)([A-Za-z][A-Za-z0-9:_-]*)((?:[^>\"']|\"[^\"]*\"|'[^']*')*?)(/?)>",
            options: [.dotMatchesLineSeparators])
        let ns = s as NSString
        var last = 0
        for m in tag.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                let raw = ns.substring(with: NSRange(location: last, length: m.range.location - last))
                stack.last!.append(XNode(text: decodeEntities(raw)))
            }
            last = m.range.location + m.range.length
            guard m.range(at: 2).location != NSNotFound else { continue } // comment/doctype/PI
            let closing = ns.substring(with: m.range(at: 1)) == "/"
            let name = ns.substring(with: m.range(at: 2))
            let lname = name.lowercased()
            if closing {
                if let idx = stack.lastIndex(where: { $0.name.lowercased() == lname }), idx > 0 {
                    stack.removeSubrange(idx...)
                }
            } else {
                let attrs = parseAttributes(m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3)))
                let node = XNode(element: name, attributes: attrs)
                stack.last!.append(node)
                let selfClosing = ns.substring(with: m.range(at: 4)) == "/"
                if !selfClosing && !voidElements.contains(lname) { stack.append(node) }
            }
        }
        if last < ns.length { stack.last!.append(XNode(text: decodeEntities(ns.substring(from: last)))) }
        return root.elements.first { $0.localName == "html" } ?? root
    }

    static func parseAttributes(_ s: String) -> [String: String] {
        let re = try! NSRegularExpression(pattern: "([A-Za-z_:][-A-Za-z0-9_:.]*)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
        let ns = s as NSString
        var out: [String: String] = [:]
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let k = ns.substring(with: m.range(at: 1))
            var v = ""
            for g in 3...5 where m.range(at: g).location != NSNotFound { v = ns.substring(with: m.range(at: g)) }
            out[k] = decodeEntities(v)
        }
        return out
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let re = try! NSRegularExpression(pattern: "&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);")
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let e = ns.substring(with: m.range(at: 1))
            var cp: Int?
            if e.hasPrefix("#x") { cp = Int(e.dropFirst(2), radix: 16) }
            else if e.hasPrefix("#") { cp = Int(e.dropFirst()) }
            else { cp = ["amp": 38, "lt": 60, "gt": 62, "quot": 34, "apos": 39][e] ?? XMLTree.htmlEntities[e] }
            if let cp, let scalar = Unicode.Scalar(cp) { out.unicodeScalars.append(scalar) }
            else { out += ns.substring(with: m.range) }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
