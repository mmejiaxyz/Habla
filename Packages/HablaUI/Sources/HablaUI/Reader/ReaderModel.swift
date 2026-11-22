import Foundation
import SwiftUI
import HablaCore

/// The six Apple Books themes (colours approximated).
public enum ReaderTheme: String, CaseIterable, Hashable, Sendable, Codable {
    case original, quiet, paper, bold, calm, focus

    public var name: String { rawValue.capitalized }

    public var background: Color {
        switch self {
        case .original, .bold: return .white
        case .quiet: return Color(hex: "#4A4A4C")
        case .paper: return Color(hex: "#EFEDE8")
        case .calm: return Color(hex: "#F3E8D2")
        case .focus: return Color(hex: "#1D1B19")
        }
    }

    public var text: Color {
        switch self {
        case .original: return Color(hex: "#1C1C1E")
        case .quiet: return Color(hex: "#E2E2E2")
        case .paper: return Color(hex: "#2A2826")
        case .bold: return .black
        case .calm: return Color(hex: "#42331F")
        case .focus: return Color(hex: "#EEE2CC")
        }
    }

    public var secondary: Color { text.opacity(0.45) }
    public var control: Color { isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.06) }
    public var isDark: Bool { self == .quiet || self == .focus }
    public var highlight: Color { Theme.accent.opacity(isDark ? 0.40 : 0.48) }
}

/// Reading state for one book: chapter, page, style, narration highlight. Shared by the
/// iPhone reader (one page) and the Mac reader (two-page spread).
@MainActor
public final class ReaderModel: ObservableObject {
    public let bundle: BookBundle
    public let manifest: BookManifest
    public let columns: Int

    @Published public private(set) var chapter: Int
    @Published public private(set) var page = 0
    @Published public private(set) var layout: PageLayout?
    @Published public var style: ReaderStyle { didSet { if style != oldValue { relayout() } } }
    /// Sentence being narrated (in `highlightChapter`), drawn behind the text.
    @Published public private(set) var highlight: (chapter: Int, sentence: Int)?
    /// The search result on screen (chapter, range in the typeset chapter text).
    @Published public var found: (chapter: Int, range: NSRange)?

    /// Called when the reader settles on a new place (to save / sync the position).
    public var onPosition: ((Int, Int) -> Void)?

    private var pageSize: CGSize = .zero
    private var anchor: Int?          // sentence to keep on screen across relayouts
    private var texts: [Int: ChapterText] = [:]
    public private(set) var loadError: String?

    public init(bundle: BookBundle, manifest: BookManifest, chapter: Int, sentence: Int?,
                style: ReaderStyle, columns: Int = 1) {
        self.bundle = bundle; self.manifest = manifest; self.columns = columns
        self.chapter = manifest.chapters.contains { $0.index == chapter } ? chapter : (manifest.chapters.first?.index ?? 0)
        self.style = style
        self.anchor = sentence
    }

    public var chapterInfo: ChapterInfo? { manifest.chapters.first { $0.index == chapter } }
    public var chapterTitle: String { chapterInfo.map(ChapterNaming.title) ?? "" }
    public var pageCount: Int { layout?.pageCount ?? 1 }

    /// Sentence at the top of what's on screen.
    public var currentSentence: Int? { layout?.firstSentence(onPage: page) }

    public var bookFraction: Double { manifest.fraction(chapter: chapter, sentence: currentSentence ?? 0) }

    // MARK: Layout

    public func setPageSize(_ size: CGSize) {
        guard size.width > 50, size.height > 50, abs(size.width - pageSize.width) > 0.5 || abs(size.height - pageSize.height) > 0.5 else { return }
        if layout != nil { anchor = currentSentence }
        pageSize = size
        relayout()
    }

    private func relayout() {
        guard pageSize != .zero else { return }
        if layout != nil, anchor == nil { anchor = currentSentence }
        guard let text = chapterText(chapter) else {
            layout = nil; loadError = "This chapter couldn't be opened."
            return
        }
        let l = PageLayout(chapter: Typesetter.set(text, style: style), pageSize: pageSize)
        loadError = nil
        layout = l
        var p = anchor.flatMap { l.page(forSentence: $0) } ?? min(page, l.pageCount - 1)
        if let a = anchor, a >= Int.max / 2 { p = l.pageCount - 1 }   // "last page" marker
        page = align(p)
        anchor = nil
    }

    private func chapterText(_ index: Int) -> ChapterText? {
        if let t = texts[index] { return t }
        guard let info = manifest.chapters.first(where: { $0.index == index }),
              let t = try? bundle.chapterText(info) else { return nil }
        texts[index] = t
        return t
    }

    private func align(_ p: Int) -> Int { columns > 1 ? p - p % columns : p }

    // MARK: Navigation

    public var canGoBack: Bool { page > 0 || previousChapter != nil }
    public var canGoForward: Bool { page + columns < pageCount || nextChapter != nil }

    var nextChapter: Int? { manifest.chapters.first { $0.index > chapter }?.index }
    var previousChapter: Int? { manifest.chapters.last { $0.index < chapter }?.index }

    public func next() {
        if page + columns < pageCount { page += columns }
        else if let n = nextChapter { switchChapter(n, sentence: nil) }
        settle()
    }

    public func previous() {
        if page > 0 { page = max(0, page - columns) }
        else if let p = previousChapter { switchChapter(p, sentence: Int.max) }
        settle()
    }

    public func go(chapter c: Int, sentence: Int?) {
        if c == chapter && sentence == nil && layout != nil { return }   // already here: keep the place
        if c == chapter, let s = sentence, let p = layout?.page(forSentence: s) { page = align(p) }
        else { switchChapter(c, sentence: sentence) }
        settle()
    }

    /// Shows a page of the current chapter (keeps two-page spreads aligned).
    public func goToPage(_ p: Int) {
        page = align(min(max(0, p), pageCount - 1))
        settle()
    }

    private func switchChapter(_ c: Int, sentence: Int?) {
        chapter = c
        page = 0
        anchor = sentence
        layout = nil
        relayout()
    }

    private func settle() {
        if let s = currentSentence { onPosition?(chapter, s) }
    }

    // MARK: Narration

    /// Highlights the spoken sentence and turns the page when narration moves past it —
    /// but only if the reader was on the page being read (never yanks someone browsing).
    public func follow(chapter c: Int, sentence s: Int) {
        let previous = highlight
        highlight = (c, s)
        guard let layout else { return }
        let wasFollowing: Bool = {
            guard let prev = previous else { return true }
            if prev.chapter != chapter { return false }
            guard let pp = layout.page(forSentence: prev.sentence) else { return false }
            return align(pp) == page
        }()
        guard wasFollowing else { return }
        if c != chapter { switchChapter(c, sentence: s); return }
        if let p = layout.page(forSentence: s), align(p) != page { page = align(p) }
    }

    public func clearHighlight() { highlight = nil }

    public func highlightedSentence(onChapter c: Int) -> Int? { highlight?.chapter == c ? highlight?.sentence : nil }
}
