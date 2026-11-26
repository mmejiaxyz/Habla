import SwiftUI
import HablaCore

public enum PhoneRoute: Hashable { case book(String), player, reader(String), mac }

/// One full-screen layer at a time: the player or the reader (switching between them
/// replaces the layer instead of stacking two presentations).
enum PhoneCover: Identifiable {
    case player
    case reader(ReaderModel)
    var id: String {
        switch self {
        case .player: return "player"
        case .reader(let m): return "reader-\(ObjectIdentifier(m).hashValue)"
        }
    }
}

/// The iPhone app: three tabs (Library, Search, Mac) → book → player ⇄ reader.
/// Positions from listening and reading go to the same store (and on to the Mac).
public struct PhoneRoot: View {
    @StateObject private var store: PhoneStore
    @StateObject private var player = NarrationPlayer()
    @State private var path: [PhoneRoute] = []
    @State private var tab: PhoneTab = .library
    @State private var cover: PhoneCover?
    @State private var repairAttempts: [String: Date] = [:]
    @Environment(\.scenePhase) private var phase

    public init(store: PhoneStore? = nil) {
        _store = StateObject(wrappedValue: store ?? PhoneStore())
    }

    public var body: some View {
        NavigationStack(path: $path) {
            PhoneTabsView(store: store, player: player, tab: $tab, open: open)
                .toolbar(.hidden)
                .navigationDestination(for: PhoneRoute.self) { route in
                    Group {
                        switch route {
                        case .book(let id): PhoneBookView(store: store, player: player, id: id, open: open, close: pop)
                        default: EmptyView()
                        }
                    }
                    .toolbar(.hidden)
                }
        }
        .preferredColorScheme(.light)
        #if os(iOS)
        .fullScreenCover(item: $cover, onDismiss: { saveReaderIfNeeded(); store.bookClosed() }) { c in
            switch c {
            case .player: playerScreen
            case .reader(let model): readerScreen(model)
            }
        }
        #endif
        .onAppear {
            player.onPosition = { [weak store] book, chapter, sentence, time in
                store?.savePosition(book: book, chapter: chapter, sentence: sentence, audioTime: time, mode: .listening)
            }
            player.onDamaged = { [weak store, weak player] id in
                // One repair attempt per chapter every 10 minutes: a chapter that can't be fixed
                // right now (no Mac) must not retry in a loop.
                guard let store, let player else { return }
                let key = "\(id)-\(player.chapter)"
                if let last = repairAttempts[key], Date().timeIntervalSince(last) < 600 {
                    player.message = "This chapter's audio is damaged. Open Habla on your Mac, then try again."
                    return
                }
                repairAttempts[key] = Date()
                Task {
                    let fixed = await store.repair(id)
                    if fixed, let m = store.manifest(id) {
                        player.load(bundle: store.bundle(id), manifest: m, chapter: player.chapter, sentence: player.sentence, autoplay: false)
                        player.message = "Repaired. Press play to continue."
                    } else {
                        player.message = "This chapter's audio is damaged. Open Habla on your Mac to repair it; you can keep reading meanwhile."
                    }
                }
            }
            store.start()
            store.startLiveUpdates()
        }
        // EPUBs opened with Habla from Files, Mail, Safari or the share sheet.
        .onOpenURL { url in
            if url.isFileURL { store.importBooks([url]) }
            // The QR code in Habla Studio, scanned with the Camera.
            else { path = []; tab = .mac; store.handleLink(url) }
        }
        .onChange(of: phase) { _, p in
            switch p {
            case .active:
                store.setForeground(true)
                store.start()                           // restart discovery after sleep / network change
                store.startLiveUpdates()
            case .inactive, .background:
                store.stopLiveUpdates()
                player.flush()
                saveReaderIfNeeded()
                Task { await store.sync() }
                if p == .background { store.setForeground(false); store.bookClosed() }
            @unknown default: break
            }
        }
        .onChange(of: store.books) { _, books in
            if let id = player.bookID, books.contains(where: { $0.id == id }), let m = store.manifest(id) { player.refresh(manifest: m) }
        }
        .alert("Habla", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }

    var playerScreen: some View {
        PhonePlayerView(player: player, cover: playerCover, close: { cover = nil }, read: {
            guard let id = player.bookID, let model = makeReader(id, chapter: player.chapter, sentence: player.sentence) else { return }
            cover = .reader(model)
        })
    }

    var playerCover: Image? {
        guard let id = player.bookID, let b = store.books.first(where: { $0.id == id }) else { return nil }
        return CoverCache.image(bundle: store.bundle(id).url, revision: b.revision)
    }

    func readerScreen(_ model: ReaderModel) -> some View {
        ReaderView(model: model, player: player,
                   onClose: { saveReaderIfNeeded(); cover = nil },
                   onStyle: { store.readerStyle = $0 },
                   onOpenPlayer: { saveReaderIfNeeded(); cover = .player })
    }

    func open(_ route: PhoneRoute) {
        switch route {
        case .player: cover = .player
        case .reader(let id):
            let p = store.progress.position(for: id)
            if let model = makeReader(id, chapter: p?.chapter, sentence: p?.sentence) { cover = .reader(model) }
        case .mac: path = []; tab = .mac
        default: path.append(route)
        }
    }

    func pop() { _ = path.popLast() }

    func makeReader(_ id: String, chapter: Int?, sentence: Int?) -> ReaderModel? {
        guard let m = store.manifest(id) else { return nil }
        let start = chapter ?? m.chapters.first { !$0.isFrontMatter }?.index ?? 0
        let model = ReaderModel(bundle: store.bundle(id), manifest: m, chapter: start, sentence: sentence, style: store.readerStyle)
        model.onPosition = { [weak store, weak player] c, s in
            // While narration drives the pages, the player saves the position itself.
            if player?.bookID == id, player?.isPlaying == true { return }
            store?.savePosition(book: id, chapter: c, sentence: s, audioTime: nil, mode: .reading)
        }
        return model
    }

    /// The reader's place wins when you were reading (not when narration was turning the pages).
    func saveReaderIfNeeded() {
        guard case .reader(let r)? = cover, let s = r.currentSentence else { return }
        if player.bookID == r.manifest.id && player.isPlaying { return }
        store.savePosition(book: r.manifest.id, chapter: r.chapter, sentence: s, audioTime: nil, mode: .reading)
    }
}
