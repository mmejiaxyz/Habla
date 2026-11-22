import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Splits a typeset chapter into pages with TextKit (one text container per page) and
/// draws a page into any CGContext — used by the iPhone, the Mac and the snapshot tool.
public final class PageLayout {
    public let chapter: TypesetChapter
    public let pageSize: CGSize
    private let storage: NSTextStorage
    private let manager = NSLayoutManager()
    private var containers: [NSTextContainer] = []

    public init(chapter: TypesetChapter, pageSize: CGSize) {
        self.chapter = chapter
        self.pageSize = CGSize(width: max(80, pageSize.width.rounded(.down)), height: max(80, pageSize.height.rounded(.down)))
        storage = NSTextStorage(attributedString: chapter.text)
        storage.addLayoutManager(manager)
        manager.usesFontLeading = true
        paginate()
    }

    private func paginate() {
        let total = manager.numberOfGlyphs
        var guardCount = 0
        while guardCount < 5000 {
            guardCount += 1
            let c = NSTextContainer(size: pageSize)
            c.lineFragmentPadding = 0
            manager.addTextContainer(c)
            let gr = manager.glyphRange(for: c)
            if gr.length == 0 {
                // Nothing fits (or nothing left): drop the empty page unless it is the only one.
                if containers.count > 0 { manager.removeTextContainer(at: manager.textContainers.count - 1) }
                else { containers.append(c) }
                break
            }
            containers.append(c)
            if NSMaxRange(gr) >= total { break }
        }
    }

    public var pageCount: Int { max(1, containers.count) }

    public func characterRange(ofPage page: Int) -> NSRange {
        guard containers.indices.contains(page) else { return NSRange(location: chapter.text.length, length: 0) }
        return manager.characterRange(forGlyphRange: manager.glyphRange(for: containers[page]), actualGlyphRange: nil)
    }

    public func page(forCharacter loc: Int) -> Int {
        guard chapter.text.length > 0 else { return 0 }
        let g = manager.glyphIndexForCharacter(at: min(max(0, loc), chapter.text.length - 1))
        guard let c = manager.textContainer(forGlyphAt: g, effectiveRange: nil),
              let i = containers.firstIndex(where: { $0 === c }) else { return 0 }
        return i
    }

    public func page(forSentence id: Int) -> Int? {
        chapter.range(ofSentence: id).map { page(forCharacter: $0.location) }
    }

    /// First sentence that begins on (or continues onto) this page.
    public func firstSentence(onPage page: Int) -> Int? {
        chapter.sentence(startingAtOrAfter: characterRange(ofPage: page).location)
    }

    /// Sentence under a point on the page (for "listen from here").
    public func sentence(at point: CGPoint, onPage page: Int) -> Int? {
        guard containers.indices.contains(page) else { return nil }
        let g = manager.glyphIndex(for: point, in: containers[page])
        return chapter.sentence(atCharacter: manager.characterIndexForGlyph(at: g))
    }

    /// The word under a point (nil when the point is in a margin or between paragraphs).
    public func wordRange(at point: CGPoint, onPage page: Int) -> NSRange? {
        guard containers.indices.contains(page), chapter.text.length > 0 else { return nil }
        let c = containers[page]
        let g = manager.glyphIndex(for: point, in: c)
        let box = manager.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: c)
        guard box.insetBy(dx: -6, dy: -4).contains(point) else { return nil }
        let ns = chapter.text.string as NSString
        let i = manager.characterIndexForGlyph(at: g)
        func isWord(_ k: Int) -> Bool {
            guard k >= 0, k < ns.length, let u = Unicode.Scalar(ns.character(at: k)) else { return false }
            return CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u)
                || u == "'" || u == "’" || u == "-" || CharacterSet.nonBaseCharacters.contains(u)
        }
        guard isWord(i) else { return nil }
        var a = i, b = i
        while isWord(a - 1) { a -= 1 }
        while isWord(b + 1) { b += 1 }
        // Trim apostrophes / hyphens at the edges ("’tis" keeps its letters, "word-" loses the dash).
        let edge: Set<unichar> = [39, 0x2019, 45]
        while a < b, edge.contains(ns.character(at: a)) { a += 1 }
        while b > a, edge.contains(ns.character(at: b)) { b -= 1 }
        return NSRange(location: a, length: b - a + 1)
    }

    /// Bounding box of a character range on a page (to place the word card).
    public func rect(for range: NSRange, onPage page: Int) -> CGRect? {
        guard containers.indices.contains(page) else { return nil }
        let gr = NSIntersectionRange(manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil),
                                     manager.glyphRange(for: containers[page]))
        guard gr.length > 0 else { return nil }
        return manager.boundingRect(forGlyphRange: gr, in: containers[page])
    }

    /// Draws one page at `origin`: optional narrated sentence and selection behind the text,
    /// underlines beneath it.
    public func draw(page: Int, in cg: CGContext, origin: CGPoint, highlight: (sentence: Int, color: CGColor)? = nil,
                     selection: (range: NSRange, color: CGColor)? = nil,
                     underlines: [NSRange] = [], underlineColor: CGColor? = nil) {
        guard containers.indices.contains(page) else { return }
        let container = containers[page]
        let glyphs = manager.glyphRange(for: container)

        func rects(_ chars: NSRange, _ body: (CGRect) -> Void) {
            let inter = NSIntersectionRange(manager.glyphRange(forCharacterRange: chars, actualCharacterRange: nil), glyphs)
            guard inter.length > 0 else { return }
            var found: [CGRect] = []
            manager.enumerateEnclosingRects(forGlyphRange: inter, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: container) { rect, _ in found.append(rect.offsetBy(dx: origin.x, dy: origin.y)) }
            found.forEach(body)
        }
        if let sel = selection {
            cg.setFillColor(sel.color)
            rects(sel.range) { r in
                cg.addPath(CGPath(roundedRect: r.insetBy(dx: -2, dy: 0), cornerWidth: 3, cornerHeight: 3, transform: nil)); cg.fillPath()
            }
        }
        if let color = underlineColor, !underlines.isEmpty {
            cg.setFillColor(color)
            for u in underlines {
                let ug = NSIntersectionRange(manager.glyphRange(forCharacterRange: u, actualCharacterRange: nil), glyphs)
                guard ug.length > 0 else { continue }
                // One line per line fragment, just under its baseline, like a pencil line.
                var lines: [CGRect] = []
                manager.enumerateLineFragments(forGlyphRange: ug) { fragment, _, _, lineGlyphs, _ in
                    let part = NSIntersectionRange(lineGlyphs, ug)
                    guard part.length > 0 else { return }
                    var span = self.manager.boundingRect(forGlyphRange: part, in: container)
                    // Leave out the trailing space a line ends with.
                    let last = self.manager.characterIndexForGlyph(at: NSMaxRange(part) - 1)
                    if part.length > 1, let sc = Unicode.Scalar((self.chapter.text.string as NSString).character(at: last)),
                       CharacterSet.whitespacesAndNewlines.contains(sc) {
                        span = self.manager.boundingRect(forGlyphRange: NSRange(location: part.location, length: part.length - 1), in: container)
                    }
                    let baseline = fragment.minY + self.manager.location(forGlyphAt: part.location).y
                    lines.append(CGRect(x: span.minX + origin.x, y: baseline + 2.5 + origin.y, width: span.width, height: 1.6))
                }
                lines.forEach { cg.fill($0) }
            }
        }

        if let h = highlight, let r = chapter.range(ofSentence: h.sentence) {
            let sg = manager.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            let inter = NSIntersectionRange(sg, glyphs)
            if inter.length > 0 {
                cg.setFillColor(h.color)
                manager.enumerateEnclosingRects(forGlyphRange: inter, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                in: container) { rect, _ in
                    let box = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: 0)
                    cg.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
                    cg.fillPath()
                }
            }
        }

        #if canImport(UIKit)
        UIGraphicsPushContext(cg)
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        UIGraphicsPopContext()
        #else
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        manager.drawGlyphs(forGlyphRange: glyphs, at: origin)
        NSGraphicsContext.restoreGraphicsState()
        #endif
    }
}
