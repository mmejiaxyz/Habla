import Foundation
import CoreText
import SwiftUI
import HablaCore
#if canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#else
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#endif

/// Reader appearance: one of the Apple Books themes plus a text size.
public struct ReaderStyle: Hashable, Sendable {
    public var theme: ReaderTheme
    public var fontSize: CGFloat
    public init(theme: ReaderTheme = .original, fontSize: CGFloat = 19) { self.theme = theme; self.fontSize = fontSize }

    public static let sizes: [CGFloat] = [15, 17, 19, 21, 24, 27, 31]
    public func larger() -> ReaderStyle { var s = self; s.fontSize = Self.sizes.first { $0 > fontSize } ?? fontSize; return s }
    public func smaller() -> ReaderStyle { var s = self; s.fontSize = Self.sizes.last { $0 < fontSize } ?? fontSize; return s }
}

/// A chapter set as book typography: justified + hyphenated serif body, first-line indents
/// (none after headings and scene breaks), centred headings, ⁂ scene breaks.
/// Keeps each sentence's character range so audio can highlight and pages can resolve
/// "which sentence is here".
public struct TypesetChapter {
    public let text: NSAttributedString
    /// Sorted by location; index = position in reading order.
    public let sentences: [(id: Int, range: NSRange)]

    public func range(ofSentence id: Int) -> NSRange? { sentences.first { $0.id == id }?.range }

    /// Sentence covering (or nearest before) a character.
    public func sentence(atCharacter loc: Int) -> Int? {
        var lo = 0, hi = sentences.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if sentences[mid].range.location <= loc { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return (found.map { sentences[$0].id }) ?? sentences.first?.id
    }

    /// First sentence starting at or after a character (what "listen from this page" plays).
    public func sentence(startingAtOrAfter loc: Int) -> Int? {
        sentences.first { NSMaxRange($0.range) > loc }?.id
    }
}

public enum Typesetter {
    /// Core Text's language attribute: TextKit hyphenates by it.
    static let languageKey = NSAttributedString.Key(kCTLanguageAttributeName as String)

    /// Writing direction from the paragraph's first strong letter.
    static func direction(of text: String) -> NSWritingDirection {
        for u in text.unicodeScalars where CharacterSet.letters.contains(u) {
            switch u.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return .rightToLeft
            default: return .leftToRight
            }
        }
        return .natural
    }

    /// `language`: the book's language (ISO code) — hyphenation and line breaking follow it.
    /// `openingTitle`: the chapter's name, set as its opening heading when the text itself doesn't
    /// start with one (image headings, TOC-only titles), so every chapter says which one it is.
    public static func set(_ chapter: ChapterText, style: ReaderStyle, language: String = "en",
                           openingTitle: String? = nil) -> TypesetChapter {
        let out = NSMutableAttributedString()
        var sentences: [(Int, NSRange)] = []
        let size = style.fontSize
        let ink = PlatformColor(style.theme.text)
        let body = serif(size, bold: style.theme == .bold)
        var indentNext = false

        if let title = openingTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
           chapter.blocks.first?.kind != .heading {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.hyphenationFactor = 0
            para.lineHeightMultiple = 1.05
            para.paragraphSpacingBefore = size * 2.2
            para.paragraphSpacing = size * 1.5
            out.append(NSAttributedString(string: title.replacingOccurrences(of: "\n", with: " ") + "\n", attributes: [
                .font: serif(size * 1.4, bold: style.theme == .bold), .foregroundColor: ink,
                .paragraphStyle: para, Self.languageKey: language]))
        }

        for (i, block) in chapter.blocks.enumerated() {
            let start = (out.string as NSString).length
            let para = NSMutableParagraphStyle()
            para.hyphenationFactor = 0.9
            para.lineHeightMultiple = 1.18
            para.lineBreakMode = .byWordWrapping
            para.baseWritingDirection = Self.direction(of: block.text)   // Arabic, Hebrew… read right to left
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: ink, .font: body,
                                                         Self.languageKey: language]

            switch block.kind {
            case .sceneBreak:
                para.alignment = .center
                para.paragraphSpacingBefore = size * 0.6
                para.paragraphSpacing = size * 0.6
                attrs[.paragraphStyle] = para
                attrs[.foregroundColor] = ink.withAlphaComponent(0.55)
                out.append(NSAttributedString(string: "⁂\n", attributes: attrs))
                indentNext = false
                continue

            case .heading:
                let level = block.level ?? 2
                para.alignment = .center
                para.hyphenationFactor = 0
                para.lineHeightMultiple = 1.05
                para.paragraphSpacingBefore = i == 0 ? size * 2.2 : size * 1.6
                para.paragraphSpacing = size * (level <= 2 ? 1.5 : 0.9)
                attrs[.font] = serif(size * (level <= 1 ? 1.55 : level == 2 ? 1.4 : 1.12), bold: style.theme == .bold)
                indentNext = false

            case .quote:
                para.alignment = .justified
                para.firstLineHeadIndent = size * 1.4
                para.headIndent = size * 1.4
                para.tailIndent = -size * 1.4
                para.paragraphSpacingBefore = size * 0.4
                para.paragraphSpacing = size * 0.4
                indentNext = false

            case .listItem:
                para.alignment = .natural
                para.firstLineHeadIndent = size * 0.6
                para.headIndent = size * 1.6
                para.paragraphSpacing = size * 0.25

            case .preformatted:
                para.alignment = .natural
                para.hyphenationFactor = 0
                attrs[.font] = PlatformFont.monospacedSystemFont(ofSize: size * 0.82, weight: .regular)

            case .paragraph:
                para.alignment = .justified
                para.firstLineHeadIndent = indentNext ? size * 1.4 : 0
                para.paragraphSpacing = size * 0.12
                indentNext = true
            }
            attrs[.paragraphStyle] = para

            // <br> → line separator: same UTF-16 length, so sentence ranges stay valid.
            var text = block.text.replacingOccurrences(of: "\n", with: "\u{2028}")
            if block.kind == .listItem { text = "•\u{2002}" + text }
            let prefix = block.kind == .listItem ? 2 : 0
            let piece = NSMutableAttributedString(string: text + "\n", attributes: attrs)

            for run in block.styles {
                let r = NSRange(location: run.range.location + prefix, length: run.range.length)
                guard NSMaxRange(r) <= piece.length else { continue }
                let base = (attrs[.font] as? PlatformFont) ?? body
                switch run.style {
                case .italic: piece.addAttribute(.font, value: styled(base, italic: true), range: r)
                case .bold: piece.addAttribute(.font, value: styled(base, bold: true), range: r)
                case .smallCaps: break
                }
            }
            out.append(piece)
            for s in block.sentences {
                sentences.append((s.id, NSRange(location: start + prefix + s.range.location, length: s.range.length)))
            }
        }
        if out.length == 0 { out.append(NSAttributedString(string: " ", attributes: [.font: body])) }
        return TypesetChapter(text: out, sentences: sentences.sorted { $0.1.location < $1.1.location })
    }

    // MARK: Fonts (New York — Apple's serif, the reading face in Books)

    public static func serif(_ size: CGFloat, bold: Bool = false) -> PlatformFont {
        #if canImport(UIKit)
        var d = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular).fontDescriptor
        d = d.withDesign(.serif) ?? d
        return UIFont(descriptor: d, size: size)
        #else
        var d = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular).fontDescriptor
        d = d.withDesign(.serif) ?? d
        return NSFont(descriptor: d, size: size) ?? .systemFont(ofSize: size)
        #endif
    }

    static func styled(_ f: PlatformFont, italic: Bool = false, bold: Bool = false) -> PlatformFont {
        #if canImport(UIKit)
        var traits = f.fontDescriptor.symbolicTraits
        if italic { traits.insert(.traitItalic) }
        if bold { traits.insert(.traitBold) }
        return f.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: f.pointSize) } ?? f
        #else
        var traits = f.fontDescriptor.symbolicTraits
        if italic { traits.insert(.italic) }
        if bold { traits.insert(.bold) }
        return NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(traits), size: f.pointSize) ?? f
        #endif
    }
}
