import Foundation

public enum EPUBError: Error, CustomStringConvertible {
    case missingContainer, missingPackage(String), invalidPackage(String), drmProtected, noText

    public var description: String {
        switch self {
        case .missingContainer: return "META-INF/container.xml not found — is this an EPUB?"
        case .missingPackage(let p): return "Package document not found: \(p)"
        case .invalidPackage(let s): return "Invalid package document: \(s)"
        case .drmProtected: return "This EPUB is DRM-protected. Only DRM-free books can be imported."
        case .noText: return "This book has no text Habla can read (it may be made of images only)."
        }
    }
}

/// An opened EPUB: metadata, reading order (spine), table of contents and cover.
public struct EPUBPackage {
    public struct ManifestItem {
        public let id: String
        public let href: String        // full path inside the zip
        public let mediaType: String
        public let properties: Set<String>
    }

    public struct SpineItem {
        public let index: Int
        public let item: ManifestItem
        public let linear: Bool
    }

    public struct TOCEntry {
        public let title: String
        public let href: String        // full path, no fragment
        public let fragment: String?
        public let depth: Int
    }

    public let archive: ZipArchive
    public let packagePath: String
    public let title: String
    public let authors: [String]
    public let language: String
    public let publisher: String?
    public let summary: String?
    public let manifest: [String: ManifestItem]
    public let spine: [SpineItem]
    public let toc: [TOCEntry]
    public let coverHref: String?

    public init(url: URL) throws {
        try self.init(archive: ZipArchive(url: url))
    }

    public init(archive: ZipArchive) throws {
        self.archive = archive

        if archive.contains("META-INF/encryption.xml"),
           let enc = try? archive.readString("META-INF/encryption.xml"),
           !Self.onlyFontObfuscation(enc) {
            throw EPUBError.drmProtected
        }

        guard let containerXML = try? archive.read("META-INF/container.xml"),
              let container = XMLTree.parse(containerXML),
              let rootfile = container.first("rootfile")?.attr("full-path")
        else { throw EPUBError.missingContainer }

        packagePath = rootfile
        guard let opfData = try? archive.read(rootfile), let opf = XMLTree.parse(opfData) else {
            throw EPUBError.missingPackage(rootfile)
        }
        let baseDir = (rootfile as NSString).deletingLastPathComponent

        // Metadata
        let metadata = opf.first("metadata")
        func dc(_ name: String) -> [String] {
            (metadata?.all(name) ?? []).map { $0.textContent.collapsedWhitespace }.filter { !$0.isEmpty }
        }
        title = dc("title").first ?? "Untitled"
        authors = dc("creator")
        language = dc("language").first ?? "en"
        publisher = dc("publisher").first
        summary = dc("description").first.map { Self.stripTags($0) }

        // Manifest
        var items: [String: ManifestItem] = [:]
        for node in opf.first("manifest")?.all("item") ?? [] {
            guard let id = node.attr("id"), let href = node.attr("href") else { continue }
            let props = Set((node.attr("properties") ?? "").split(separator: " ").map(String.init))
            items[id] = ManifestItem(id: id, href: Self.resolve(href, base: baseDir),
                                     mediaType: node.attr("media-type") ?? "", properties: props)
        }
        manifest = items

        // Spine
        guard let spineNode = opf.first("spine") else { throw EPUBError.invalidPackage("no spine") }
        var spineItems: [SpineItem] = []
        for ref in spineNode.all("itemref") {
            guard let idref = ref.attr("idref"), let item = items[idref] else { continue }
            spineItems.append(SpineItem(index: spineItems.count, item: item, linear: ref.attr("linear") != "no"))
        }
        spine = spineItems

        // Cover: EPUB 3 property, then EPUB 2 <meta name="cover">, then a guess.
        var cover = items.values.first { $0.properties.contains("cover-image") }?.href
        if cover == nil, let coverID = metadata?.all("meta").first(where: { $0.attr("name") == "cover" })?.attr("content") {
            cover = items[coverID]?.href
        }
        if cover == nil {
            cover = items.values.first {
                $0.mediaType.hasPrefix("image/") && $0.href.lowercased().contains("cover")
            }?.href
        }
        coverHref = cover

        // Table of contents: EPUB 3 nav, falling back to NCX.
        var entries: [TOCEntry] = []
        if let nav = items.values.first(where: { $0.properties.contains("nav") }),
           let data = try? archive.read(nav.href), let doc = XMLTree.parse(data) {
            entries = Self.parseNav(doc, base: (nav.href as NSString).deletingLastPathComponent)
        }
        if entries.isEmpty {
            let ncxID = spineNode.attr("toc")
            let ncx = ncxID.flatMap { items[$0] } ?? items.values.first { $0.mediaType == "application/x-dtbncx+xml" }
            if let ncx, let data = try? archive.read(ncx.href), let doc = XMLTree.parse(data) {
                entries = Self.parseNCX(doc, base: (ncx.href as NSString).deletingLastPathComponent)
            }
        }
        toc = entries
    }

    public var author: String {
        authors.isEmpty ? "Unknown" : ListFormatter.localizedString(byJoining: authors)
    }

    public func coverData() -> Data? {
        guard let coverHref else { return nil }
        if let item = manifest.values.first(where: { $0.href == coverHref }), !item.mediaType.hasPrefix("image/") {
            // Cover is an XHTML page — use the first image it references.
            guard let data = try? archive.read(coverHref), let doc = XMLTree.parse(data) else { return nil }
            let base = (coverHref as NSString).deletingLastPathComponent
            let src = doc.first("img")?.attr("src") ?? doc.first("image")?.attr("href")
            return src.flatMap { try? archive.read(Self.resolve($0, base: base)) }
        }
        return try? archive.read(coverHref)
    }

    // MARK: Helpers

    static func resolve(_ href: String, base: String) -> String {
        let clean = (href.removingPercentEncoding ?? href).components(separatedBy: "#")[0]
        if clean.hasPrefix("/") { return String(clean.dropFirst()) }
        var parts = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for comp in clean.split(separator: "/") {
            if comp == ".." { _ = parts.popLast() } else if comp != "." { parts.append(String(comp)) }
        }
        return parts.joined(separator: "/")
    }

    static func splitFragment(_ href: String) -> (String, String?) {
        let parts = href.components(separatedBy: "#")
        return (parts[0], parts.count > 1 ? parts[1] : nil)
    }

    static func parseNav(_ doc: XNode, base: String) -> [TOCEntry] {
        let navs = doc.all("nav")
        guard let toc = navs.first(where: { ($0.attr("type") ?? "").contains("toc") }) ?? navs.first,
              let list = toc.first("ol") else { return [] }
        var out: [TOCEntry] = []
        func walk(_ ol: XNode, depth: Int) {
            for li in ol.elements where li.localName == "li" {
                if let a = li.child("a") ?? li.first("a"), let href = a.attr("href") {
                    let (path, frag) = splitFragment(href)
                    let title = a.textContent.collapsedWhitespace
                    if !title.isEmpty {
                        out.append(TOCEntry(title: title, href: resolve(path, base: base), fragment: frag, depth: depth))
                    }
                }
                if let sub = li.child("ol") { walk(sub, depth: depth + 1) }
            }
        }
        walk(list, depth: 0)
        return out
    }

    static func parseNCX(_ doc: XNode, base: String) -> [TOCEntry] {
        guard let navMap = doc.first("navmap") else { return [] }
        var out: [TOCEntry] = []
        func walk(_ node: XNode, depth: Int) {
            for p in node.elements where p.localName == "navpoint" {
                let title = p.child("navlabel")?.textContent.collapsedWhitespace ?? ""
                if let src = p.child("content")?.attr("src"), !title.isEmpty {
                    let (path, frag) = splitFragment(src)
                    out.append(TOCEntry(title: title, href: resolve(path, base: base), fragment: frag, depth: depth))
                }
                walk(p, depth: depth + 1)
            }
        }
        walk(navMap, depth: 0)
        return out
    }

    /// Font obfuscation (IDPF / Adobe) also lives in encryption.xml but isn't DRM.
    static func onlyFontObfuscation(_ xml: String) -> Bool {
        guard let doc = XMLTree.parse(xml) else { return false }
        let methods = doc.all("encryptionmethod").compactMap { $0.attr("Algorithm") }
        return !methods.isEmpty && methods.allSatisfy {
            $0 == "http://www.idpf.org/2008/embedding" || $0 == "http://ns.adobe.com/pdf/enc#RC"
        }
    }

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression).collapsedWhitespace
    }
}

extension String {
    var collapsedWhitespace: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
