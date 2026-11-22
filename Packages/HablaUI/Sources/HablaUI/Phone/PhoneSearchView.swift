import SwiftUI
import HablaCore

/// Search tab: titles, authors and chapter titles across the library (this iPhone and the Mac).
public struct PhoneSearchView: View {
    @ObservedObject var store: PhoneStore
    @ObservedObject var player: NarrationPlayer
    var open: (PhoneRoute) -> Void
    @State private var query = ""
    @State private var scope: Scope = .all
    @FocusState private var focused: Bool

    enum Scope: String, CaseIterable { case all = "All", narrated = "Narrated", textOnly = "Text only", onMac = "On your Mac" }

    public init(store: PhoneStore, player: NarrationPlayer, open: @escaping (PhoneRoute) -> Void) {
        self.store = store; self.player = player; self.open = open
    }

    var q: String { query.trimmingCharacters(in: .whitespaces) }

    var books: [BookItem] {
        store.books.filter { b in
            switch scope {
            case .all: return true
            case .narrated: return b.hasAudio
            case .textOnly: return b.isTextOnly
            case .onMac: if case .remote = b.availability { return true }; return false
            }
        }
        .filter { b in q.isEmpty || b.title.localizedCaseInsensitiveContains(q) || b.author.localizedCaseInsensitiveContains(q) }
    }

    struct ChapterHit: Identifiable { let book: BookItem; let chapter: ChapterItem; var id: String { "\(book.id)#\(chapter.index)" } }

    var chapterHits: [ChapterHit] {
        guard q.count >= 2 else { return [] }
        return books.flatMap { b in
            b.chapters.filter { !$0.isFrontMatter && $0.title.localizedCaseInsensitiveContains(q) }.map { ChapterHit(book: b, chapter: $0) }
        }
    }

    public var body: some View {
        Scroll {
            VStack(alignment: .leading, spacing: 0) {
                Text("Search").font(Theme.display(46)).foregroundStyle(Theme.text).accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Theme.margin - 4).padding(.top, 12)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(Theme.text.opacity(0.6))
                    TextField("Titles, authors, chapters", text: $query)
                        .textFieldStyle(.plain).font(Theme.grotesk(16)).focused($focused)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.text.opacity(0.4))
                                .frame(width: 32, height: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 16).frame(height: 48)
                .background(Capsule().fill(Theme.surface))
                .padding(.horizontal, 16).padding(.top, 14)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Scope.allCases, id: \.self) { s in
                            Button { scope = s } label: {
                                Text(s.rawValue).font(Theme.grotesk(12)).foregroundStyle(scope == s ? Theme.paper : Theme.text)
                                    .padding(.horizontal, 14).frame(height: 32)
                                    .background(Capsule().fill(scope == s ? Theme.ink : .clear))
                                    .overlay(Capsule().strokeBorder(Theme.text.opacity(scope == s ? 0 : 0.2), lineWidth: 1))
                                    .frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(scope == s ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, Theme.margin - 4)
                }
                .padding(.top, 6)

                SectionRule("Books", count: books.count).padding(.horizontal, Theme.margin - 4).padding(.top, 24).padding(.bottom, 2)
                if books.isEmpty {
                    Text(q.isEmpty ? "No books here yet." : "Nothing matches “\(q)”.").font(Theme.grotesk(14)).foregroundStyle(Theme.textDim)
                        .padding(.horizontal, Theme.margin).padding(.top, 16)
                }
                VStack(spacing: 0) {
                    ForEach(books) { b in result(b) }
                }
                .padding(.horizontal, Theme.margin - 4)

                if !chapterHits.isEmpty {
                    SectionRule("Chapters", count: chapterHits.count).padding(.horizontal, Theme.margin - 4).padding(.top, 30).padding(.bottom, 2)
                    VStack(spacing: 0) {
                        ForEach(chapterHits) { h in chapterResult(h.book, h.chapter) }
                    }
                    .padding(.horizontal, Theme.margin - 4)
                }
                Color.clear.frame(height: 200)
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    func result(_ b: BookItem) -> some View {
        Button { open(.book(b.id)) } label: {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    BookCover(title: b.title, author: b.author, accentHex: store.manifestAccent(b.id),
                              image: b.availability == .local ? CoverCache.image(bundle: store.bundle(b.id).url, revision: b.revision) : nil)
                        .frame(width: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(b.title).font(Theme.display(19)).foregroundStyle(Theme.text).lineLimit(2).multilineTextAlignment(.leading)
                        Text(b.author).font(Theme.displayItalic(15)).foregroundStyle(Theme.text.opacity(0.7)).lineLimit(1)
                        Text(status(b)).font(Theme.grotesk(12)).foregroundStyle(Theme.textDim).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 14)
                Hairline()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func chapterResult(_ b: BookItem, _ c: ChapterItem) -> some View {
        Button { open(.book(b.id)) } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title).font(Theme.grotesk(15)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(b.title).font(Theme.grotesk(12)).foregroundStyle(Theme.textDim).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 14)).foregroundStyle(Theme.text.opacity(0.5))
                }
                .padding(.vertical, 14)
                Hairline()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func status(_ b: BookItem) -> String {
        var parts: [String] = []
        switch b.availability {
        case .remote: parts.append("On your Mac")
        case .downloading(let f): parts.append("Downloading \(Int(f * 100))%")
        case .local: parts.append(b.isStarted ? "\(Int((b.progress * 100).rounded()))%" : "New")
        }
        parts.append(b.isTextOnly ? "text only" : b.isFullyNarrated ? "narrated" : "narrating \(b.narrated)/\(b.narratable)")
        return parts.joined(separator: "  ·  ")
    }
}
