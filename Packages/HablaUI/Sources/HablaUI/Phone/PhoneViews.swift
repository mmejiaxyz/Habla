import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import CoreImage
import UniformTypeIdentifiers
import HablaCore

// MARK: - Tabs

public enum PhoneTab: Hashable { case library, search, mac }

/// Root of the iPhone app: the selected tab, plus the floating tab bar and (outside the
/// library, whose card already plays) the mini player.
public struct PhoneTabsView: View {
    @ObservedObject var store: PhoneStore
    @ObservedObject var player: NarrationPlayer
    @Binding var tab: PhoneTab
    var open: (PhoneRoute) -> Void

    public init(store: PhoneStore, player: NarrationPlayer, tab: Binding<PhoneTab>, open: @escaping (PhoneRoute) -> Void) {
        self.store = store; self.player = player; self._tab = tab; self.open = open
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            Theme.screen.ignoresSafeArea()
            Group {
                switch tab {
                case .library: PhoneLibraryView(store: store, player: player, open: open)
                case .search: PhoneSearchView(store: store, player: player, open: open)
                case .mac: PhoneMacView(store: store, close: {})
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 10) {
                if player.isLoaded && tab != .library {
                    MiniPlayer(player: player, cover: coverForPlayer) { open(.player) }
                }
                FloatingTabBar(tab: $tab)
            }
            .padding(.horizontal, 24).padding(.bottom, 2)
            .background(
                LinearGradient(colors: [Theme.screen.opacity(0), Theme.screen.opacity(0.95), Theme.screen],
                               startPoint: .top, endPoint: .bottom)
                    .padding(.top, -40).ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
            )
        }
    }

    var coverForPlayer: Image? {
        guard let id = player.bookID, let b = store.books.first(where: { $0.id == id }) else { return nil }
        return CoverCache.image(bundle: store.bundle(id).url, revision: b.revision)
    }
}

/// Library · Search · Mac, floating above the content.
public struct FloatingTabBar: View {
    @Binding var tab: PhoneTab
    public init(tab: Binding<PhoneTab>) { self._tab = tab }

    public var body: some View {
        HStack(spacing: 2) {
            item(.library, "Library", "books.vertical")
            item(.search, "Search", "magnifyingglass")
            item(.mac, "Account", "person.crop.circle")
        }
        .padding(5)
        .background(Capsule().fill(.ultraThinMaterial))
        .background(Capsule().fill(Theme.paper.opacity(0.75)))
        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
    }

    func item(_ t: PhoneTab, _ title: String, _ symbol: String) -> some View {
        let on = tab == t
        return Button { tab = t } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 18, weight: .regular))
                Text(title).font(.ui(10, weight: .medium))
            }
            .foregroundStyle(Theme.ink.opacity(on ? 1 : 0.6))
            .frame(width: 100, height: 54)
            .background(Capsule().fill(on ? Theme.accent : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Library (home)

public struct PhoneLibraryView: View {
    @ObservedObject var store: PhoneStore
    @ObservedObject var player: NarrationPlayer
    var open: (PhoneRoute) -> Void
    @State private var picking = false
    @State private var confirmRemove: BookItem?
    @State private var confirmDeleteAll: BookItem?
    @AppStorage("habla.library.sort") private var sort = LibrarySort.recent.rawValue
    @AppStorage("habla.library.list") private var listView = false
    @AppStorage("habla.library.hideTextOnly") private var hideTextOnly = false

    public init(store: PhoneStore, player: NarrationPlayer, open: @escaping (PhoneRoute) -> Void) {
        self.store = store; self.player = player; self.open = open
    }

    var local: [BookItem] { store.books.filter { if case .remote = $0.availability { return false }; return true } }
    var remote: [BookItem] { store.books.filter { if case .remote = $0.availability { return true }; return false } }
    /// What's playing, else the book you were last in, else the first one.
    var hero: BookItem? {
        if let id = player.bookID, let b = local.first(where: { $0.id == id }) { return b }
        return store.current ?? local.first
    }
    var shelf: [BookItem] {
        let books = local.filter { !(hideTextOnly && $0.isTextOnly) }
        return LibrarySort(rawValue: sort)?.apply(books) ?? books
    }

    public var body: some View {
        Group {
            if store.books.isEmpty && store.importing == 0 { emptyState }
            else { library }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data],
                      allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { store.importBooks(urls) }
        }
        .confirmationDialog("Remove from this iPhone?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            titleVisibility: .visible, presenting: confirmRemove) { b in
            Button("Remove download", role: .destructive) { if player.bookID == b.id { player.unload() }; store.delete(b.id) }
        } message: { _ in Text(!store.hasAccount
            ? "Your place and underlines are kept. To get it back, add the EPUB again."
            : "Your place and underlines are kept. You can download it again from your Mac.") }
        .confirmationDialog("Delete from all your devices?", isPresented: Binding(get: { confirmDeleteAll != nil }, set: { if !$0 { confirmDeleteAll = nil } }),
                            titleVisibility: .visible, presenting: confirmDeleteAll) { b in
            Button("Delete everywhere", role: .destructive) { if player.bookID == b.id { player.unload() }; store.deleteEverywhere(b.id) }
        } message: { _ in Text("The book and its narration go from this iPhone and every device in your account.") }
    }

    var library: some View {
        Scroll {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, Theme.margin - 4).padding(.top, 12)

                if let hero { heroCard(hero).padding(.horizontal, 16).padding(.top, 18) }

                SectionRule("All books", count: shelf.count) { sortMenu }
                    .padding(.horizontal, Theme.margin - 4).padding(.top, 36).padding(.bottom, 16)

                if listView {
                    VStack(spacing: 0) { ForEach(shelf) { b in listRow(b) } }.padding(.horizontal, Theme.margin - 4)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 28) {
                        ForEach(shelf) { b in tile(b) }
                    }
                    .padding(.horizontal, Theme.margin - 4)
                }

                if store.importing > 0 {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Adding \(store.importing == 1 ? "a book" : "\(store.importing) books")…").font(Theme.grotesk(14)).foregroundStyle(Theme.textDim)
                    }.padding(.horizontal, Theme.margin).padding(.top, 20)
                }

                if !remote.isEmpty {
                    SectionRule("On your Mac", count: remote.count)
                        .padding(.horizontal, Theme.margin - 4).padding(.top, 40).padding(.bottom, 16)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 28) {
                        ForEach(remote) { b in tile(b) }
                    }
                    .padding(.horizontal, Theme.margin - 4)
                }

                connectionLine.padding(.horizontal, Theme.margin).padding(.top, 30)
                if let u = store.appUpdate { updateLine(u).padding(.horizontal, Theme.margin).padding(.top, 14) }
                Color.clear.frame(height: 130)
            }
        }
        .refreshable { await store.sync() }
    }

    var header: some View {
        HStack(spacing: 10) {
            Text("Library").font(Theme.display(46)).foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Menu {
                Button { picking = true } label: { Label("Import EPUB from Files", systemImage: "doc") }
                Button { open(.mac) } label: { Label(store.hasAccount ? "Your account" : "Join your account", systemImage: "qrcode") }
            } label: { RoundIcon("plus") }
            .accessibilityLabel("Add books")
            Menu {
                Section("Sort by") {
                    ForEach(LibrarySort.allCases, id: \.self) { s in
                        Button { sort = s.rawValue } label: { if sort == s.rawValue { Label(s.title, systemImage: "checkmark") } else { Text(s.title) } }
                    }
                }
                Section("View") {
                    Button { listView = false } label: { Label("Grid", systemImage: listView ? "square.grid.2x2" : "checkmark") }
                    Button { listView = true } label: { Label("List", systemImage: listView ? "checkmark" : "list.bullet") }
                    Toggle("Hide text-only books", isOn: $hideTextOnly)
                }
            } label: { RoundIcon("ellipsis") }
            .accessibilityLabel("Sort and view")
        }
    }

    var sortMenu: some View {
        Menu {
            ForEach(LibrarySort.allCases, id: \.self) { s in
                Button { sort = s.rawValue } label: { if sort == s.rawValue { Label(s.title, systemImage: "checkmark") } else { Text(s.title) } }
            }
        } label: {
            HStack(spacing: 4) {
                Text(LibrarySort(rawValue: sort)?.title ?? "Recent").font(Theme.grotesk(12))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Theme.text.opacity(0.65))
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Sort books")
    }

    // MARK: Card

    func cover(_ b: BookItem) -> BookCover {
        let img = b.availability == .local ? CoverCache.image(bundle: store.bundle(b.id).url, revision: b.revision) : nil
        return BookCover(title: b.title, author: b.author, accentHex: store.manifestAccent(b.id), image: img)
    }

    func heroCard(_ b: BookItem) -> some View {
        let playing = player.isPlaying && player.bookID == b.id
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                Text(b.isStarted ? "Continue · \(b.currentChapter?.title ?? "")" : "New in your library")
                    .font(Theme.label(10)).tracking(1.2).textCase(.uppercase)
                    .foregroundStyle(Theme.ink.opacity(0.75)).lineLimit(1)
                    .padding(.trailing, 120)
                Text(b.title).font(Theme.display(34)).foregroundStyle(Theme.ink)
                    .lineSpacing(-6).lineLimit(3).minimumScaleFactor(0.6)
                    .padding(.top, 14).padding(.trailing, 112)
                Text(b.author).font(Theme.displayItalic(17)).foregroundStyle(Theme.ink.opacity(0.7)).lineLimit(1)
                    .padding(.top, 6).padding(.trailing, 112)
                Spacer(minLength: 22)
                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        ProgressLine(b.progress)
                        Text(heroStatus(b)).font(Theme.grotesk(12)).foregroundStyle(Theme.ink.opacity(0.8)).lineLimit(2)
                    }
                    if b.hasAudio && b.availability == .local {
                        Button { resume(b) } label: {
                            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 20))
                                .foregroundStyle(Theme.paper).offset(x: playing ? 0 : 2)
                                .frame(width: 56, height: 56).background(Circle().fill(Theme.ink))
                        }
                        .buttonStyle(PressStyle())
                        .accessibilityLabel(playing ? "Pause" : (b.isStarted ? "Resume listening" : "Start listening"))
                    } else if b.availability == .local {
                        ActionPill("Read", symbol: "book", height: 44) { open(.reader(b.id)) }.frame(width: 110)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 268, alignment: .topLeading)

            FramedCover(cover(b), width: 92, mat: 5, tilt: -3)
                .padding(.top, 22).padding(.trailing, 22)
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.accent))
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onTapGesture { open(.book(b.id)) }
        .contextMenu { bookActions(b) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(b.title), \(b.author). \(heroStatus(b).replacingOccurrences(of: "/", with: " of "))")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the book")
        .accessibilityAction { open(.book(b.id)) }
        .accessibilityActions {
            if b.hasAudio && b.availability == .local { Button(playing ? "Pause" : (b.isStarted ? "Resume listening" : "Start listening")) { resume(b) } }
            Button("Read") { open(.reader(b.id)) }
        }
    }

    func heroStatus(_ b: BookItem) -> String {
        if let f = store.phoneNarration[b.id] { return "Narrating on this iPhone · \(Int((f * 100).rounded()))%" }
        if store.isWaitingForMac(b.id) { return b.isTextOnly ? "Readable now · sending to your Mac" : "Readable now · narration starts when your Mac is on" }
        var parts = [!b.isStarted ? "Not started" : b.progress < 0.01 ? "Just started" : "\(Int((b.progress * 100).rounded()))%"]
        if b.isTextOnly { parts.append("text only") }
        else if !b.isFullyNarrated { parts.append("narrating \(b.narrated)/\(b.narratable)") }
        else if let m = b.minutesLeft { parts.append("\(Format.duration(Double(m) * 60)) left") }
        return parts.joined(separator: "  ·  ")
    }

    func resume(_ b: BookItem) {
        let newer = store.resumePoint(for: b.id, player: player)
        if player.bookID == b.id && (player.isPlaying || newer == nil) { player.toggle(); return }
        guard let m = store.manifest(b.id) else { return }
        let p = newer ?? b.position
        player.load(bundle: store.bundle(b.id), manifest: m, chapter: p?.chapter ?? b.resumeChapter, sentence: p?.sentence,
                    time: p?.mode == .listening ? p?.audioTime : nil, autoplay: true)
        open(.player)
    }

    // MARK: Tiles

    func tile(_ b: BookItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { open(.book(b.id)) } label: {
                cover(b)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
                    .overlay(alignment: .bottomTrailing) {
                        if case .downloading(let f) = b.availability {
                            ProgressRing(value: f, color: Theme.paper).frame(width: 26, height: 26).padding(10)
                        }
                    }
            }
            .buttonStyle(PressStyle())
            .contextMenu { bookActions(b) }
            .accessibilityLabel("\(b.title), \(b.author)")
            .accessibilityValue(tileStatus(b))

            HStack(spacing: 8) {
                Text(tileStatus(b)).font(Theme.grotesk(12)).foregroundStyle(Theme.text.opacity(0.65)).lineLimit(1)
                Spacer(minLength: 0)
                if case .remote(let bytes) = b.availability {
                    Button { Task { try? await store.download(b.id) } } label: {
                        Text("Get · \(Format.bytes(bytes))").font(.ui(12, weight: .medium)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 10).frame(height: 28).background(Capsule().fill(Theme.accent))
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Download \(b.title)")
                } else {
                    if b.hasAudio { Image(systemName: "headphones").font(.system(size: 12)).foregroundStyle(Theme.accentText).accessibilityHidden(true) }
                    Menu { bookActions(b) } label: {
                        Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                            .frame(width: 36, height: 44).contentShape(Rectangle())
                    }
                    .accessibilityLabel("More for \(b.title)")
                }
            }
            .frame(height: 24)
        }
    }

    func tileStatus(_ b: BookItem) -> String {
        if let f = store.phoneNarration[b.id] { return "Narrating \(Int((f * 100).rounded()))%" }
        if store.isWaitingForMac(b.id) { return "Waiting for your Mac" }
        switch b.availability {
        case .remote: return b.isTextOnly ? "Text only" : b.isFullyNarrated ? "Narrated" : "Narrating \(b.narrated)/\(b.narratable)"
        case .downloading(let f): return "Downloading \(Int(f * 100))%"
        case .local:
            if b.isStarted { return "\(Int((b.progress * 100).rounded()))%" }
            return b.isTextOnly ? "Text only" : "New"
        }
    }

    func listRow(_ b: BookItem) -> some View {
        Button { open(.book(b.id)) } label: {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    cover(b).frame(width: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(b.title).font(Theme.display(19)).foregroundStyle(Theme.text).lineLimit(2)
                        Text(b.author).font(Theme.displayItalic(15)).foregroundStyle(Theme.text.opacity(0.7)).lineLimit(1)
                        Text(tileStatus(b)).font(Theme.grotesk(12)).foregroundStyle(Theme.textDim)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 14)
                Hairline()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { bookActions(b) }
    }

    /// Same actions from the tile's •••, a long press, and the card.
    @ViewBuilder func bookActions(_ b: BookItem) -> some View {
        if b.availability == .local {
            if b.hasAudio {
                Button { resume(b) } label: { Label(b.isStarted ? "Continue listening" : "Listen", systemImage: "headphones") }
            }
            Button { open(.reader(b.id)) } label: { Label("Read", systemImage: "book") }
        }
        Button { open(.book(b.id)) } label: { Label("Book details", systemImage: "info.circle") }
        if b.availability == .local {
            if b.isStarted {
                Button { startOver(b) } label: { Label("Start from the beginning", systemImage: "arrow.counterclockwise") }
            }
            if store.canNarrateOnPhone(b.id) && store.phoneNarration[b.id] == nil {
                Button { store.narrateOnPhone(b.id) } label: { Label("Narrate on this iPhone", systemImage: "waveform") }
            }
            Button(role: .destructive) { confirmRemove = b } label: { Label("Remove download", systemImage: "arrow.down.circle") }
            Button(role: .destructive) { confirmDeleteAll = b } label: { Label("Delete everywhere", systemImage: "trash") }
        }
    }

    func startOver(_ b: BookItem) {
        let first = b.chapters.first { !$0.isFrontMatter }?.index ?? 0
        if player.bookID == b.id { player.unload() }
        store.savePosition(book: b.id, chapter: first, sentence: 0, audioTime: nil, mode: .reading)
    }

    // MARK: Empty

    var emptyState: some View {
        ZStack {
            Theme.accent.ignoresSafeArea()
            VStack(spacing: 18) {
                Text("Habla").font(Theme.displayItalic(17)).foregroundStyle(Theme.ink.opacity(0.7))
                Text("Your shelf\nis empty.".uppercased()).font(Theme.display(40)).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                Text("Add a DRM-free EPUB. You can read it right away; your Mac narrates it and the audio arrives over Wi-Fi.")
                    .font(Theme.grotesk(15)).foregroundStyle(Theme.ink.opacity(0.75)).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    ActionPill("Add a book", symbol: "plus") { picking = true }.frame(width: 230)
                    if !store.hasAccount {
                        ActionPill("Join your account", symbol: "qrcode", style: .outline) { open(.mac) }.frame(width: 230)
                    }
                }
                .padding(.top, 18)
                HStack(spacing: 8) {
                    Circle().fill(Theme.ink.opacity(0.5)).frame(width: 6, height: 6)
                    Text(store.connectionSummary).font(Theme.grotesk(12)).foregroundStyle(Theme.ink.opacity(0.6)).lineLimit(1)
                }
                .padding(.top, 22)
            }
            .padding(.horizontal, 32).padding(.bottom, 60)
        }
    }

    @Environment(\.openURL) private var openURL

    func updateLine(_ u: AppUpdate) -> some View {
        Button {
            openURL(PhoneStore.altStoreURL) { opened in if !opened { openURL(AppUpdate.releasesPage) } }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(Theme.accentText).frame(width: 7, height: 7)
                Text("A new version of Habla is available").font(Theme.grotesk(13)).foregroundStyle(Theme.textDim)
                Text("Update in AltStore").font(Theme.grotesk(13)).foregroundStyle(Theme.accentText)
            }.lineLimit(1)
        }.buttonStyle(.plain)
        .accessibilityLabel("A new version of Habla is available. Update in AltStore.")
    }

    var connectionLine: some View {
        Button { open(.mac) } label: {
            HStack(spacing: 8) {
                Circle().fill(store.isConnected ? Theme.accent : Theme.textDim.opacity(0.5)).frame(width: 7, height: 7)
                Text(store.connectionSummary).font(Theme.grotesk(13)).foregroundStyle(Theme.textDim).lineLimit(1)
                if store.syncing { ProgressView().controlSize(.mini) }
            }
        }.buttonStyle(.plain)
    }
}

/// Library order (kept per device).
enum LibrarySort: String, CaseIterable {
    case recent, title, author, progress
    var title: String {
        switch self {
        case .recent: return "Recent"
        case .title: return "Title"
        case .author: return "Author"
        case .progress: return "Progress"
        }
    }
    func apply(_ books: [BookItem]) -> [BookItem] {
        switch self {
        case .recent:
            return books.enumerated().sorted { a, b in
                let da = a.element.position?.updatedAt, db = b.element.position?.updatedAt
                switch (da, db) {
                case let (x?, y?): return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.offset < b.offset
                }
            }.map(\.element)
        case .title: return books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author: return books.sorted { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        case .progress: return books.sorted { $0.progress > $1.progress }
        }
    }
}

extension PhoneStore {
    public var isConnected: Bool { if case .connected = connection { return lastSync != nil }; return false }
    public var connectionSummary: String {
        guard hasAccount else { return "No account yet · scan your account’s QR code on your Mac" }
        switch connection {
        case .connected(let name, _): return lastSync == nil ? "Connecting to \(name)…" : "\(name) · synced \(Format.ago(lastSync))"
        case .searching:
            if let s = bridgeSynced { return "Synced through the cloud \(Format.ago(s)) · no Mac on this Wi-Fi" }
            return "Looking for your Macs on this Wi-Fi…"
        case .unreachable: return "Mac not reachable · your books still work offline"
        }
    }

    /// The book's cover colour (for typographic covers), from the local manifest when there is one.
    @MainActor func manifestAccent(_ id: String) -> String? {
        guard let b = books.first(where: { $0.id == id }), b.availability == .local else { return nil }
        return CoverCache.accent(bundle: bundle(id).url, revision: b.revision)
    }
}

/// Bottom bar while something is loaded in the player.
public struct MiniPlayer: View {
    @ObservedObject var player: NarrationPlayer
    var cover: Image?
    var open: () -> Void
    public init(player: NarrationPlayer, cover: Image? = nil, open: @escaping () -> Void) { self.player = player; self.cover = cover; self.open = open }
    public var body: some View {
        HStack(spacing: 12) {
            BookCover(title: player.bookTitle, author: player.author, image: cover).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.chapterTitle.isEmpty ? player.bookTitle : player.chapterTitle)
                    .font(.ui(15, weight: .medium)).foregroundStyle(Theme.paper).lineLimit(1)
                Text(player.bookTitle).font(Theme.grotesk(12)).foregroundStyle(Theme.paper.opacity(0.6)).lineLimit(1)
            }
            Spacer()
            if player.duration > 0 {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 17))
                        .foregroundStyle(Theme.ink).frame(width: 44, height: 44).background(Circle().fill(Theme.accent))
                }.buttonStyle(PressStyle()).accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            }
        }
        .padding(.leading, 8).padding(.trailing, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.ink)
            .shadow(color: .black.opacity(0.15), radius: 14, y: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now playing: \(player.chapterTitle), \(player.manifest?.title ?? "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the player")
        .accessibilityAction { open() }
        .accessibilityActions {
            if player.duration > 0 { Button(player.isPlaying ? "Pause" : "Play") { player.toggle() } }
        }
    }
}

// MARK: - Book

public struct PhoneBookView: View {
    @ObservedObject var store: PhoneStore
    @ObservedObject var player: NarrationPlayer
    let id: String
    var open: (PhoneRoute) -> Void
    var close: () -> Void
    @State private var confirmRemove = false
    @State private var confirmDeleteAll = false

    public init(store: PhoneStore, player: NarrationPlayer, id: String, open: @escaping (PhoneRoute) -> Void, close: @escaping () -> Void) {
        self.store = store; self.player = player; self.id = id; self.open = open; self.close = close
    }

    var book: BookItem? { store.books.first { $0.id == id } }

    public var body: some View {
        ZStack(alignment: .top) {
            Theme.screen.ignoresSafeArea()
            if let b = book {
                Scroll { content(b) }
            }
        }
        .onChange(of: book == nil) { _, gone in if gone { close() } }
        .confirmationDialog("Remove from this iPhone?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove download", role: .destructive) { if player.bookID == id { player.unload() }; store.delete(id); close() }
        } message: { Text(!store.hasAccount
            ? "Your place and underlines are kept. To get it back, add the EPUB again."
            : "Your place and underlines are kept. You can download it again from your Mac.") }
        .confirmationDialog("Delete from all your devices?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete everywhere", role: .destructive) { if player.bookID == id { player.unload() }; store.deleteEverywhere(id); close() }
        } message: { Text("The book and its narration go from this iPhone and every device in your account.") }
    }

    func content(_ b: BookItem) -> some View {
        VStack(spacing: 0) {
            // Cover field
            VStack(spacing: 0) {
                HStack {
                    RoundIconButton("chevron.left", label: "Back", fill: Theme.paper.opacity(0.55), action: close)
                    Spacer()
                    Text("Library").font(Theme.label(10)).tracking(1.2).textCase(.uppercase).foregroundStyle(Theme.ink.opacity(0.7))
                    Spacer()
                    if b.availability == .local {
                        Menu {
                            if b.isStarted {
                                Button { startOver(b) } label: { Label("Start from the beginning", systemImage: "arrow.counterclockwise") }
                            }
                            if store.canNarrateOnPhone(b.id) && store.phoneNarration[b.id] == nil {
                                Button { store.narrateOnPhone(b.id) } label: { Label("Narrate on this iPhone", systemImage: "waveform") }
                            }
                            Button(role: .destructive) { confirmRemove = true } label: { Label("Remove download", systemImage: "arrow.down.circle") }
                            Button(role: .destructive) { confirmDeleteAll = true } label: { Label("Delete everywhere", systemImage: "trash") }
                        } label: { RoundIcon("ellipsis", fill: Theme.paper.opacity(0.55)) }
                        .accessibilityLabel("More")
                    } else {
                        Color.clear.frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 6)

                BookCover(title: b.title, author: b.author, accentHex: store.manifestAccent(b.id),
                          image: b.availability == .local ? CoverCache.image(bundle: store.bundle(b.id).url, revision: b.revision) : nil)
                    .frame(width: 176)
                    .shadow(color: .black.opacity(0.28), radius: 26, y: 18)
                    .padding(.top, 22).padding(.bottom, 34)
            }
            .frame(maxWidth: .infinity)
            // The band ends with the cover field (the title sits on paper, however long it is);
            // it only reaches upward, behind the status bar and when the page is pulled down.
            .background(Theme.accent.padding(.top, -1000))

            // Title
            VStack(spacing: 10) {
                Text(b.author).font(Theme.label(10)).tracking(1.2).textCase(.uppercase).foregroundStyle(Theme.text.opacity(0.6))
                Text(b.title.uppercased()).font(Theme.display(34)).foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center).lineSpacing(-4).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(meta(b) + (store.updating.contains(b.id) ? "  ·  updating…" : ""))
                    .font(Theme.grotesk(12)).foregroundStyle(Theme.text.opacity(0.6)).multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.margin).padding(.top, 30)

            VStack(alignment: .leading, spacing: 0) {
                if b.isStarted && b.availability == .local {
                    VStack(spacing: 8) {
                        ProgressLine(b.progress, track: Theme.text.opacity(0.12))
                        HStack {
                            Text("\(b.currentChapter?.title ?? "")  ·  \(Int((b.progress * 100).rounded()))%")
                            Spacer()
                            if let m = b.minutesLeft, b.hasAudio { Text("\(Format.duration(Double(m) * 60)) left") }
                        }
                        .font(Theme.grotesk(12)).foregroundStyle(Theme.text.opacity(0.7)).lineLimit(1)
                    }
                    .padding(.top, 24)
                }

                actions(b).padding(.top, 22)

                if b.chapters.contains(where: { !$0.isFrontMatter }) {
                    let chapters = b.chapters.filter { !$0.isFrontMatter }
                    SectionRule("Chapters", count: chapters.count).padding(.top, 40).padding(.bottom, 2)
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { i, c in
                        Button { openChapter(b, c) } label: { chapterRow(b, c, number: i + 1) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, Theme.margin).padding(.bottom, 60)
        }
    }

    func meta(_ b: BookItem) -> String {
        var parts: [String] = []
        let chapters = b.chapters.filter { !$0.isFrontMatter }.count
        if chapters > 0 { parts.append("\(chapters) chapters") }
        if b.duration > 0 { parts.append(Format.duration(b.duration)) }
        if b.isTextOnly { parts.append("text only") }
        else if b.isFullyNarrated { parts.append("narrated") }
        else { parts.append("narrating \(b.narrated) of \(b.narratable)") }
        return parts.joined(separator: "  ·  ")
    }

    @ViewBuilder func actions(_ b: BookItem) -> some View {
        switch b.availability {
        case .remote(let bytes):
            ActionPill("Download · \(Format.bytes(bytes))", symbol: "arrow.down") { Task { try? await store.download(b.id) } }
        case .downloading(let f):
            HStack(spacing: 12) { ProgressRing(value: f).frame(width: 22, height: 22); Text("Downloading… \(Int(f * 100))%").font(Theme.grotesk(15)) }
                .frame(height: 50)
        case .local:
            HStack(spacing: 10) {
                if b.hasAudio {
                    ActionPill(b.isStarted ? "Continue listening" : "Listen", symbol: "headphones") { listen(b, chapter: nil) }
                    ActionPill("Read", symbol: "book", style: .outline) { open(.reader(b.id)) }.frame(width: 112)
                } else {
                    ActionPill(b.isStarted ? "Continue reading" : "Read", symbol: "book") { open(.reader(b.id)) }
                }
            }
        }
    }

    func chapterRow(_ b: BookItem, _ c: ChapterItem, number: Int) -> some View {
        let current = b.isStarted && c.index == b.resumeChapter
        let playing = current && player.bookID == b.id && player.isPlaying
        let done = b.isStarted && c.index < b.resumeChapter
        let tint = current ? Theme.accentText : Theme.text
        return VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(String(format: "%02d", number)).font(Theme.label(10)).tracking(1.2)
                    .foregroundStyle(current ? Theme.accentText : Theme.text.opacity(0.5))
                    .frame(width: 20, alignment: .leading).accessibilityHidden(true)
                Text(c.title).font(Theme.grotesk(15)).foregroundStyle(done ? Theme.textDim : tint).lineLimit(1)
                Spacer()
                Text(playing ? "Playing" : done ? "✓" : c.minutes.map { "\($0) min" } ?? "")
                    .accessibilityLabel(playing ? "Playing" : done ? "Finished" : c.minutes.map { "\($0) minutes" } ?? "")
                    .font(Theme.grotesk(12)).foregroundStyle(current ? Theme.accentText : Theme.textDim)
            }
            .padding(.vertical, 17)
            Hairline()
        }
        .contentShape(Rectangle())
    }

    func startOver(_ b: BookItem) {
        let first = b.chapters.first { !$0.isFrontMatter }?.index ?? 0
        if player.bookID == b.id { player.unload() }
        store.savePosition(book: b.id, chapter: first, sentence: 0, audioTime: nil, mode: .reading)
    }

    func openChapter(_ b: BookItem, _ c: ChapterItem) {
        guard b.availability == .local else { return }
        if c.hasAudio { listen(b, chapter: c.index) }
        else { store.savePosition(book: b.id, chapter: c.index, sentence: 0, audioTime: nil, mode: .reading); open(.reader(b.id)) }
    }

    func listen(_ b: BookItem, chapter: Int?) {
        guard let m = store.manifest(b.id) else { return }
        // Tapping the chapter that's already loaded: keep the place, just show the player.
        if let c = chapter, player.bookID == b.id, player.chapter == c { if !player.isPlaying { player.play() }; open(.player); return }
        // Tapping the saved chapter: resume where you were in it.
        if let c = chapter, let p = b.position, p.chapter == c {
            player.load(bundle: store.bundle(b.id), manifest: m, chapter: c, sentence: p.sentence,
                        time: p.mode == .listening ? p.audioTime : nil, autoplay: true)
            open(.player); return
        }
        let newer = store.resumePoint(for: b.id, player: player)
        let p = newer ?? b.position
        if chapter == nil, player.bookID == b.id, newer == nil { player.play(); open(.player); return }
        player.load(bundle: store.bundle(b.id), manifest: m, chapter: chapter ?? p?.chapter ?? b.resumeChapter,
                    sentence: chapter == nil ? p?.sentence : nil,
                    time: chapter == nil && p?.mode == .listening ? p?.audioTime : nil, autoplay: true)
        open(.player)
    }
}

// MARK: - Player

public struct PhonePlayerView: View {
    @ObservedObject var player: NarrationPlayer
    var cover: Image?
    var close: () -> Void
    var read: () -> Void
    @State private var scrub: Double?
    @State private var bubble: Bubble?
    @State private var showChapters = false

    enum Bubble { case speed, sleep }

    public init(player: NarrationPlayer, cover: Image? = nil, close: @escaping () -> Void, read: @escaping () -> Void) {
        self.player = player; self.cover = cover; self.close = close; self.read = read
    }

    public var body: some View {
        ZStack {
            Theme.accent.ignoresSafeArea()
            VStack(spacing: 0) {
                nav
                Spacer(minLength: 12)
                FramedCover(BookCover(title: player.bookTitle, author: player.author, accentHex: player.manifest?.accentColor, image: cover),
                            width: 208, mat: 8)
                VStack(spacing: 4) {
                    Text(player.chapterTitle).font(Theme.display(32)).foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                    Text(player.author).font(Theme.displayItalic(17)).foregroundStyle(Theme.ink.opacity(0.7)).lineLimit(1)
                    if let m = player.message {
                        Text(m).font(Theme.grotesk(13)).foregroundStyle(Theme.ink.opacity(0.7))
                            .multilineTextAlignment(.center).padding(.top, 10)
                    }
                }
                .padding(.horizontal, Theme.margin).padding(.top, 30)
                Spacer(minLength: 16)

                if player.duration == 0 {
                    // Nothing narrated to play yet: no empty transport, just the way forward.
                    ActionPill("Read instead", symbol: "book") { read() }.padding(.horizontal, Theme.margin).padding(.bottom, 40)
                } else {
                    transportControls
                }
            }

            if bubble != nil {
                Color.black.opacity(0.12).ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { bubble = nil } }
                    .zIndex(1)
                VStack { Spacer(); optionsRow.padding(.bottom, 24) }.zIndex(2)
            }
        }
        .sheet(isPresented: $showChapters) { chaptersSheet }
    }

    var nav: some View {
        HStack {
            RoundIconButton("chevron.down", label: "Close", fill: Theme.paper.opacity(0.5), action: close)
            Spacer()
            VStack(spacing: 2) {
                Text("Now listening").font(Theme.label(10)).tracking(1.2).textCase(.uppercase).foregroundStyle(Theme.ink.opacity(0.6))
                Text(player.bookTitle).font(Theme.grotesk(12)).foregroundStyle(Theme.ink).lineLimit(1)
            }
            Spacer()
            Menu {
                Button { showChapters = true } label: { Label("Chapters", systemImage: "list.bullet") }
                Button { player.previousChapter() } label: { Label("Previous chapter", systemImage: "backward.end") }
                Button { player.nextChapter() } label: { Label("Next chapter", systemImage: "forward.end") }
                Button { read() } label: { Label("Read along", systemImage: "book") }
            } label: { RoundIcon("ellipsis", fill: Theme.paper.opacity(0.5)) }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 16).padding(.top, 6)
    }

    @ViewBuilder var transportControls: some View {
        scrubber.padding(.horizontal, Theme.margin + 4)
        HStack {
            Text(Format.clock(scrub.map { $0 * player.duration } ?? player.time))
            Spacer()
            if let m = player.manifest {
                let chapters = m.chapters.filter { !$0.isFrontMatter }
                if let i = chapters.firstIndex(where: { $0.index == player.chapter }) { Text("Chapter \(i + 1) of \(chapters.count)") }
            }
            Spacer()
            Text("−" + Format.clock(player.duration - (scrub.map { $0 * player.duration } ?? player.time)))
        }
        .font(Theme.grotesk(12)).monospacedDigit().foregroundStyle(Theme.ink.opacity(0.7))
        .padding(.horizontal, Theme.margin + 4).padding(.top, 6)

        HStack(spacing: 44) {
            transport("gobackward.15", "Back 15 seconds") { player.skip(-15) }
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 28))
                    .foregroundStyle(Theme.paper).offset(x: player.isPlaying ? 0 : 2)
                    .frame(width: 78, height: 78).background(Circle().fill(Theme.ink))
            }.buttonStyle(PressStyle()).accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            transport("goforward.30", "Forward 30 seconds") { player.skip(30) }
        }
        .padding(.top, 22)

        optionsRow.padding(.horizontal, Theme.margin + 4).padding(.top, 26).padding(.bottom, 24)
            .opacity(bubble == nil ? 1 : 0)
    }

    /// Speed · Sleep · Read along. Speed and sleep open a small bubble right above their chip.
    var optionsRow: some View {
        HStack {
            Button { withAnimation(.easeOut(duration: 0.15)) { bubble = bubble == .speed ? nil : .speed } } label: {
                Chip(rateLabel, selected: bubble == .speed)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Playback speed \(rateLabel)")
            .overlay(alignment: .bottom) {
                if bubble == .speed {
                    BubblePicker(NarrationPlayer.rates.map { ($0, Self.rateText($0)) }, selected: player.rate) { r in
                        player.rate = r; withAnimation(.easeOut(duration: 0.15)) { bubble = nil }
                    }
                    .fixedSize()
                    .offset(y: -52)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                }
            }
            Spacer()
            Button { withAnimation(.easeOut(duration: 0.15)) { bubble = bubble == .sleep ? nil : .sleep } } label: {
                Chip(sleepLabel, symbol: "moon", selected: bubble == .sleep)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sleep timer, \(sleepLabel)")
            .overlay(alignment: .bottom) {
                if bubble == .sleep {
                    BubblePicker(Self.sleepOptions, selected: player.sleepTimer ?? 0, width: 128) { m in
                        player.setSleepTimer(minutes: m == 0 ? nil : m); withAnimation(.easeOut(duration: 0.15)) { bubble = nil }
                    }
                    .fixedSize()
                    .offset(y: -52)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                }
            }
            Spacer()
            Button(action: read) { Chip("Read along", symbol: "book") }.buttonStyle(.plain)
        }
    }

    static let sleepOptions: [(Int, String)] = [(60, "60 min"), (45, "45 min"), (30, "30 min"), (20, "20 min"), (10, "10 min"), (-1, "Chapter end"), (0, "Off")]
    static func rateText(_ r: Double) -> String { r == r.rounded() ? String(format: "%.1f×", r) : String(format: "%g×", r) }
    var rateLabel: String { Self.rateText(player.rate) }

    var sleepLabel: String {
        switch player.sleepTimer {
        case nil: return "Sleep"
        case -1: return "Chapter end"
        case let m?: return "\(m) min"
        }
    }

    func transport(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 26)).foregroundStyle(Theme.ink).frame(width: 52, height: 52) }
            .buttonStyle(PressStyle()).accessibilityLabel(label)
    }

    var scrubber: some View {
        GeometryReader { g in
            let f = scrub ?? (player.duration > 0 ? player.time / player.duration : 0)
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.ink.opacity(0.22)).frame(height: 2)
                Rectangle().fill(Theme.ink).frame(width: max(2, g.size.width * f), height: 2)
                Circle().fill(Theme.ink).frame(width: scrub == nil ? 12 : 18, height: scrub == nil ? 12 : 18)
                    .offset(x: g.size.width * f - (scrub == nil ? 6 : 9))
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in scrub = min(1, max(0, v.location.x / g.size.width)) }
                .onEnded { _ in if let s = scrub { player.seek(fraction: s) }; scrub = nil })
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel("Position in chapter")
        .accessibilityValue("\(Format.clock(player.time)) of \(Format.clock(player.duration))")
        .accessibilityHint("Swipe up to go forward 30 seconds, down to go back 15")
        .accessibilityAdjustableAction { dir in player.skip(dir == .increment ? 30 : -15) }
    }

    var chaptersSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chapters").font(Theme.display(32)).foregroundStyle(Theme.text)
                    Text(player.bookTitle).font(Theme.grotesk(12)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                RoundIconButton("chevron.down", label: "Close") { showChapters = false }
            }
            .padding(.horizontal, Theme.margin).padding(.top, 22).padding(.bottom, 10)
            Scroll {
                VStack(spacing: 0) {
                    let chapters = player.manifest?.chapters.filter { !$0.isFrontMatter } ?? []
                    ForEach(Array(chapters.enumerated()), id: \.element.index) { i, c in
                        let current = c.index == player.chapter
                        let ready = c.audioStatus == .ready
                        Button { if ready { player.jump(chapter: c.index, sentence: 0); showChapters = false } } label: {
                            VStack(spacing: 0) {
                                HStack(spacing: 16) {
                                    Text(String(format: "%02d", i + 1)).font(Theme.label(10)).tracking(1.2)
                                        .foregroundStyle(current ? Theme.accentText : Theme.text.opacity(0.5)).frame(width: 20, alignment: .leading)
                                    Text(ChapterNaming.title(c)).font(Theme.grotesk(15)).foregroundStyle(current ? Theme.accentText : ready ? Theme.text : Theme.textDim).lineLimit(1)
                                    Spacer()
                                    Text(current ? "Playing" : ready ? (c.duration.map { "\(max(1, Int(($0 / 60).rounded()))) min" } ?? "") : "Not narrated yet")
                                        .font(Theme.grotesk(12)).foregroundStyle(current ? Theme.accentText : Theme.textDim)
                                }
                                .padding(.vertical, 16)
                                Hairline()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!ready)
                    }
                }
                .padding(.horizontal, Theme.margin).padding(.bottom, 30)
            }
        }
        .background(Theme.screen.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(28)
    }
}

// MARK: - Account (tab)

/// The account: its name, its QR code (to add another device), the devices' sync state.
/// Without one: how to join (scan the QR code on your Mac with the Camera, or paste its code).
public struct PhoneMacView: View {
    @ObservedObject var store: PhoneStore
    var close: () -> Void
    @State private var storageLine = ""
    @State private var code = ""
    @State private var confirmLeave = false
    @State private var showQR = false
    @State private var copiedCode = false

    public init(store: PhoneStore, close: @escaping () -> Void) { self.store = store; self.close = close }

    public var body: some View {
        Scroll {
            VStack(alignment: .leading, spacing: 0) {
                Text("Account").font(Theme.display(46)).foregroundStyle(Theme.text).accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Theme.margin - 4).padding(.top, 12)

                Group {
                    if store.hasAccount { accountCard } else { joinCard }
                }
                .padding(.horizontal, 16).padding(.top, 18)

                if let e = store.error {
                    Text(e).font(Theme.grotesk(13)).foregroundStyle(Theme.accentText)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, Theme.margin).padding(.top, 12)
                }

                VStack(spacing: 14) {
                    Text("One library.\nEvery device.".uppercased()).font(Theme.display(26)).foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                    Text("Every book, your place and your underlines are on all the devices in your account. At home they sync over Wi-Fi; away, through an encrypted bridge that can’t read them.")
                        .font(Theme.grotesk(12)).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.margin).padding(.top, 44)

                VStack(alignment: .leading, spacing: 0) {
                    SectionRule("On this iPhone").padding(.bottom, 4)
                    infoRow("Downloaded", storageLine)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Imprint.about(models: store.narrationModels), id: \.self) { line in
                            Text(line).font(Theme.grotesk(13)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 16).accessibilityElement(children: .combine)
                    Hairline()
                    if store.hasAccount {
                        Button { confirmLeave = true } label: {
                            HStack { Text("Leave this account").font(Theme.grotesk(15)).foregroundStyle(Theme.accentText); Spacer() }
                                .padding(.vertical, 16).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Hairline()
                    }
                }
                .padding(.horizontal, Theme.margin).padding(.top, 30)

                Color.clear.frame(height: 130)
            }
        }
        .onAppear { storageLine = computeStorage() }
        .confirmationDialog("Leave “\(store.accountName ?? "this account")”?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { store.leaveAccount() }
        } message: { Text("Downloaded books stay on this iPhone, but nothing syncs until you scan the account’s QR code again.") }
        .sheet(isPresented: $showQR, onDismiss: { copiedCode = false }) {
            VStack(spacing: 18) {
                Text(store.accountName ?? "Your account").font(Theme.display(30)).foregroundStyle(Theme.text)
                if let link = store.accountLink {
                    AccountQR(text: link.absoluteString).frame(width: 240, height: 240).padding(16)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white))
                }
                Text("Another iPhone: scan this with its Camera. A Mac: copy the code (or AirDrop it) and paste it in Habla → Join your account. Anyone with this code gets your library: only use it on your own devices.")
                    .font(Theme.grotesk(13)).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let link = store.accountLink {
                    HStack(spacing: 10) {
                        ActionPill(copiedCode ? "Copied" : "Copy code", symbol: "doc.on.doc", style: .ink, height: 46) {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = link.absoluteString
                            #endif
                            copiedCode = true
                        }
                        ShareLink(item: link.absoluteString) {
                            Label("Share", systemImage: "square.and.arrow.up").font(Theme.grotesk(15)).foregroundStyle(Theme.text)
                                .padding(.horizontal, 20).frame(height: 46)
                                .background(Capsule().stroke(Theme.text.opacity(0.4)))
                        }
                    }
                }
            }
            .padding(28)
            .presentationDetents([.medium, .large])
        }
    }

    func infoRow(_ title: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(Theme.grotesk(15)).foregroundStyle(Theme.text); Spacer(); Text(value).font(Theme.grotesk(12)).foregroundStyle(Theme.textDim) }
                .padding(.vertical, 16)
            Hairline()
        }
    }

    var accountCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(store.isConnected ? Color(hex: "#6BA878") : Theme.textDim.opacity(0.5)).frame(width: 8, height: 8)
                Text(store.connectionSummary).font(Theme.grotesk(12)).foregroundStyle(Theme.text.opacity(0.7)).lineLimit(2)
            }
            Text(store.accountName ?? "Your account").font(Theme.display(32)).foregroundStyle(Theme.text)
                .lineLimit(2).minimumScaleFactor(0.7)
            Label("Encrypted on every device", systemImage: "lock.fill").font(Theme.grotesk(12)).foregroundStyle(Theme.textDim)
            HStack(spacing: 10) {
                ActionPill(store.syncing ? "Syncing…" : "Sync now", style: .ink, height: 46) {
                    Task { await store.sync(); await store.syncAccount() }
                }
                .disabled(store.syncing)
                ActionPill("Show QR code", symbol: "qrcode", style: .outline, height: 46) { showQR = true }
            }
            .padding(.top, 10)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface))
    }

    var joinCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Join your account").font(Theme.display(32)).foregroundStyle(Theme.text)
            Text("In Habla on your Mac, open Account. Scan its QR code with the Camera and tap the Habla link. Or copy its code and paste it here.")
                .font(Theme.grotesk(14)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            HStack(spacing: 10) {
                TextField("habla://account…", text: $code)
                    .textFieldStyle(.plain).font(Theme.grotesk(15))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .padding(.horizontal, 16).frame(height: 46)
                    .background(Capsule().fill(Theme.paper))
                    .onSubmit { if store.joinAccount(code) { code = "" } }
                CapsuleButton("Join", height: 46) { if store.joinAccount(code) { code = "" } }
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(.top, 18)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.surface))
    }

    func computeStorage() -> String {
        let local = store.books.filter { $0.availability == .local }
        let bytes = (FileManager.default.enumerator(at: store.library, includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +)) ?? 0
        return "\(local.count) book\(local.count == 1 ? "" : "s")  ·  \(Format.bytes(bytes))"
    }
}

/// A crisp QR code (Core Image, scaled without smoothing).
public struct AccountQR: View {
    let text: String
    public init(text: String) { self.text = text }
    public var body: some View {
        if let image = Self.make(text) {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().aspectRatio(1, contentMode: .fit)
                .accessibilityLabel("Account QR code")
        } else {
            Color.clear
        }
    }

    static func make(_ text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}
