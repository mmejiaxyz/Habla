import SwiftUI
import AppKit
import HablaCore
import HablaUI

// habla-snapshots <fixture-library> <out-dir>
// Renders the real iPhone + Mac screens with real books (offscreen, no simulator).

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: habla-snapshots <library> <out>"); exit(1) }
let fixture = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
let fm = FileManager.default
try? fm.createDirectory(at: out, withIntermediateDirectories: true)
let phone = CGSize(width: 390, height: 844)
let languagesMode = args.count >= 4 && args[3] == "--languages"

/// iPhone 13 safe area (status bar, home indicator). ImageRenderer has none, so `device: true`
/// reserves it the way the phone does; backgrounds that ignore the safe area still fill it.
let deviceInsets = (top: CGFloat(47), bottom: CGFloat(34))
/// Reader page height inside the device safe area (matches ReaderView: chrome 74 + footer 22).
let readerPageHeight = phone.height - deviceInsets.top - deviceInsets.bottom - 74 - 22

@MainActor func render<V: View>(_ name: String, _ view: V, size: CGSize = phone, scale: CGFloat = 3, dark: Bool = false, device: Bool = false) {
    let framed = view
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: device ? deviceInsets.top : 0) }
        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: device ? deviceInsets.bottom : 0) }
    let r = ImageRenderer(content: framed.frame(width: size.width, height: size.height)
        .environment(\.staticLayout, true).environment(\.colorScheme, dark ? .dark : .light))
    r.scale = scale
    guard let cg = r.cgImage else { print("✗ \(name)"); return }
    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
    print("✓ \(name)")
}

@MainActor func makeRoot(_ name: String, books: [URL]) -> URL {
    let root = fm.temporaryDirectory.appendingPathComponent("habla-snap-\(name)-\(UUID().uuidString.prefix(6))")
    let lib = root.appendingPathComponent("Library")
    try! fm.createDirectory(at: lib, withIntermediateDirectories: true)
    for b in books { try! fm.copyItem(at: b, to: lib.appendingPathComponent(b.lastPathComponent)) }
    return root
}

/// `--languages`: one reader page, book page and library for every book in the library.
@MainActor func runLanguages() {
    let bundles = try! fm.contentsOfDirectory(at: fixture, includingPropertiesForKeys: nil).filter { $0.pathExtension == "habla" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let root = makeRoot("langs", books: bundles)
    let store = PhoneStore(root: root)
    store.previewState(remote: [], connection: .connected(name: "Habla on MacBook Pro", url: URL(string: "http://192.168.1.20:8787")!),
                       lastSync: Date(), paired: .init(libraryID: "a", name: "Habla on MacBook Pro", fingerprint: ""))
    render("lang-library", PhoneLibraryView(store: store, player: NarrationPlayer(), open: { _ in }))
    for b in bundles {
        let m = try! BookBundle(url: b).manifest()
        let model = ReaderModel(bundle: BookBundle(url: b), manifest: m, chapter: m.chapters.first { !$0.isFrontMatter }!.index,
                                sentence: nil, style: ReaderStyle())
        model.setPageSize(CGSize(width: phone.width - 52, height: phone.height - 74 - 22))
        render("lang-\(m.language)-reader", ReaderView(model: model, player: NarrationPlayer(), onClose: {}))
        render("lang-\(m.language)-book", PhoneBookView(store: store, player: NarrationPlayer(), id: m.id, open: { _ in }, close: {}))
    }
}

@MainActor func run() {
    let bundles = try! fm.contentsOfDirectory(at: fixture, includingPropertiesForKeys: nil).filter { $0.pathExtension == "habla" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let manifests = bundles.map { try! BookBundle(url: $0).manifest() }
    let withAudio = zip(bundles, manifests).first { $0.1.chapters.contains { $0.audioStatus == .ready } }
    let main = withAudio ?? (bundles[0], manifests[0])
    let audioChapter = main.1.chapters.first { $0.audioStatus == .ready }?.index ?? main.1.chapters.first { !$0.isFrontMatter }!.index

    // ---- iPhone ----
    let root = makeRoot("phone", books: Array(bundles.prefix(4)))
    let store = PhoneStore(root: root)
    store.savePosition(book: main.1.id, chapter: audioChapter, sentence: 14, audioTime: 60, mode: .listening)
    if bundles.count > 1 { store.savePosition(book: manifests[bundles.firstIndex(of: main.0) == 0 ? 1 : 0].id, chapter: 3, sentence: 10, audioTime: nil, mode: .reading) }
    var remote = manifests.dropFirst(4).map { LibraryEntry(manifest: $0) }
    if remote.isEmpty, var e = manifests.last.map(LibraryEntry.init(manifest:)) { e.id = "remote-sample"; e.title = "Persuasion"; e.author = "Jane Austen"; remote = [e] }
    store.previewState(remote: remote, connection: .connected(name: "Habla on MacBook Pro", url: URL(string: "http://192.168.1.20:8787")!),
                       lastSync: Date().addingTimeInterval(-120),
                       paired: .init(libraryID: "a", name: "Habla on MacBook Pro", fingerprint: String(repeating: "ab", count: 32)))
    let player = NarrationPlayer()
    let mb = BookBundle(url: BookBundle.url(for: main.1.id, in: store.library))
    player.load(bundle: mb, manifest: main.1, chapter: audioChapter, sentence: 14, autoplay: false)

    render("p1-library", PhoneLibraryView(store: store, player: player, open: { _ in }))
    render("p2-book", PhoneBookView(store: store, player: player, id: main.1.id, open: { _ in }, close: {}))
    render("p3-player", PhonePlayerView(player: player, close: {}, read: {}))
    render("p4-mac", PhoneMacView(store: store, close: {}))
    let unpaired = PhoneStore(root: makeRoot("unpaired", books: []))
    unpaired.previewState(remote: [], connection: .searching, lastSync: nil,
                          nearby: [.init(name: "Habla on Studio iMac", url: URL(string: "https://192.168.1.31:8787")!, libraryID: "b"),
                                   .init(name: "Habla on Manuel’s MacBook Pro", url: URL(string: "https://192.168.1.20:8787")!, libraryID: "a")])
    render("p11-pair", PhoneMacView(store: unpaired, close: {}))

    let empty = PhoneStore(root: makeRoot("empty", books: []))
    empty.previewState(remote: [], connection: .searching, lastSync: nil)
    render("p5-library-empty", PhoneLibraryView(store: empty, player: NarrationPlayer(), open: { _ in }))

    // Reader pages: compute the page size the way ReaderView does on a phone.
    func reader(_ name: String, _ theme: ReaderTheme, chrome: Bool, chapter: Int, sentence: Int?, highlight: Bool, size: CGFloat = 19) {
        let model = ReaderModel(bundle: mb, manifest: main.1, chapter: chapter, sentence: sentence, style: ReaderStyle(theme: theme, fontSize: size))
        model.setPageSize(CGSize(width: phone.width - 52, height: readerPageHeight))
        if highlight, let s = sentence { model.follow(chapter: chapter, sentence: s) }
        render(name, ReaderView(model: model, player: highlight ? player : NarrationPlayer(), chrome: chrome, onClose: {}), device: true)
    }
    reader("p6-reader-original", .original, chrome: false, chapter: audioChapter, sentence: nil, highlight: false)
    reader("p7-reader-listening", .original, chrome: false, chapter: audioChapter, sentence: 14, highlight: true)
    reader("p8-reader-calm-controls", .calm, chrome: true, chapter: audioChapter, sentence: 14, highlight: true)
    reader("p9-reader-focus-large", .focus, chrome: false, chapter: audioChapter + 1, sentence: nil, highlight: false, size: 24)
    do {
        let model = ReaderModel(bundle: mb, manifest: main.1, chapter: audioChapter, sentence: nil, style: ReaderStyle())
        model.setPageSize(CGSize(width: phone.width - 52, height: readerPageHeight))
        if let l = model.layout {
            for u in model.annotations.underlines(book: main.1.id) { model.removeUnderline(u) }
            var hits: [NSRange] = []
            for y in stride(from: 120.0, to: 420, by: 23) { if let w = l.wordRange(at: CGPoint(x: 150, y: y), onPage: model.page) { hits.append(w) } }
            if let r = hits.first, let s = model.sentenceRange(around: r.location) { model.addUnderline(s) }
        }
        let fm2 = ReaderModel(bundle: mb, manifest: main.1, chapter: audioChapter, sentence: nil, style: ReaderStyle())
        fm2.setPageSize(CGSize(width: phone.width - 52, height: readerPageHeight))
        render("p12-reader-find", ReaderView(model: fm2, player: NarrationPlayer(), onClose: {}, previewFind: "Netherfield"), device: true)
        render("p10-reader-word", ReaderView(model: model, player: NarrationPlayer(), onClose: {}, previewWordAt: CGPoint(x: 200, y: 300)), device: true)
    }

    // ---- Mac ----
    let mac = CGSize(width: 1240, height: 800)
    let studioRoot = makeRoot("studio", books: bundles)
    let studio = StudioStore(support: studioRoot)
    studio.selection = main.1.id
    let other = manifests.first { $0.id != main.1.id }
    studio.previewState(render: other.map { StudioStore.RenderState(bookID: $0.id, chapterTitle: $0.chapters[min(3, $0.chapters.count - 1)].title, sentence: 41, sentenceCount: 120, chaptersDone: 2, chaptersTotal: 20, secondsLeft: 3900) },
                        queue: other.map { [$0.id] } ?? [], phoneLastSeen: Date().addingTimeInterval(-90),
                        xteink: .done("4 books on Xteink X4 · up to date"), server: "192.168.1.20:8787")
    render("m1-studio", StudioWindowView(store: studio, installScript: URL(fileURLWithPath: "/tmp/install.sh"), openReader: { _ in }), size: mac, scale: 2)
    if let o = other { studio.selection = o.id }
    render("m2-studio-narrating", StudioWindowView(store: studio, installScript: nil, openReader: { _ in }), size: mac, scale: 2)
    let emptyStudio = StudioStore(support: makeRoot("studio-empty", books: []))
    emptyStudio.previewState(render: nil, queue: [], phoneLastSeen: nil, xteink: .looking, server: "192.168.1.20:8787")
    let invite = PairingInvite(libraryID: "3e85", name: "Habla on Manuel’s MacBook Pro", address: "192.168.1.20:8787",
                               fingerprint: String(repeating: "ab", count: 32), code: "7KQ2M-XW4HD")
    render("m5-pairing", PairingSheet(pairing: .init(code: invite.code, expires: Date().addingTimeInterval(583), invite: invite.url),
                                      macName: "Habla on Manuel’s MacBook Pro", encrypted: true, done: {}), size: CGSize(width: 680, height: 420), scale: 2)
    render("m3-studio-empty", StudioWindowView(store: emptyStudio, installScript: URL(fileURLWithPath: "/tmp/install.sh"), openReader: { _ in }), size: mac, scale: 2)

    let spread = ReaderModel(bundle: mb, manifest: main.1, chapter: audioChapter, sentence: 14, style: ReaderStyle(), columns: 2)
    spread.setPageSize(CGSize(width: (mac.width - 112 - 96) / 2, height: mac.height - 108 - 22))
    spread.follow(chapter: audioChapter, sentence: 14)
    render("m4-mac-reader", ReaderView(model: spread, player: player, onClose: {}), size: mac, scale: 2)
}

MainActor.assumeIsolated { languagesMode ? runLanguages() : run() }
