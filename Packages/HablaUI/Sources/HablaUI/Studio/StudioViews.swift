#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import CoreImage
import HablaCore

/// Habla Studio's main window.
public struct StudioWindowView: View {
    @ObservedObject var store: StudioStore
    @ObservedObject var updater: StudioUpdater
    var installScript: URL?
    var openReader: (String) -> Void
    @State var dropping = false
    @State var showImporter = false
    @State var confirmDelete: BookManifest?
    /// Redesign: the book page is open (otherwise the cover grid).
    @State var showingBook = false
    /// Redesign: sidebar "Narrating" filter.
    @State var narratingOnly = false
    @State private var showLinkMac = false

    public init(store: StudioStore, updater: StudioUpdater = StudioUpdater(), installScript: URL?, openReader: @escaping (String) -> Void) {
        self.store = store; self.updater = updater; self.installScript = installScript; self.openReader = openReader
    }

    public var body: some View {
        redesignedBody   // StudioHome.swift
        // Up/down arrows move through the library.
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL { urls.append(url) }
                    else if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                            let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
                }
                await MainActor.run { store.importFiles(urls) }
            }
            return true
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data],
                      allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { store.importFiles(urls) }
        }
        .alert("Habla", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("OK") { store.alert = nil }
        } message: { Text(store.alert ?? "") }
        .confirmationDialog("Delete “\(confirmDelete?.title ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete from all devices", role: .destructive) { if let m = confirmDelete { store.delete(m.id, everywhere: true) }; confirmDelete = nil }
        } message: { Text(store.bridgeReady ? "The book and its narration go from this Mac and every device in your account."
                                            : "The book and its narration go from this Mac.") }
    }

    func moveSelection(_ step: Int) {
        guard !store.books.isEmpty else { return }
        let i = store.books.firstIndex { $0.id == store.selection } ?? -step
        store.selection = store.books[max(0, min(store.books.count - 1, i + step))].id
    }

    // MARK: Sidebar

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("HABLA").font(Theme.label(10)).tracking(1.4).foregroundStyle(Theme.text)
                Spacer()
                Button { showImporter = true } label: { Image(systemName: "plus").font(.system(size: 15, weight: .medium)).frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accentText).help("Add EPUB books").accessibilityLabel("Add books")
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 18)

            dropZone.padding(.horizontal, 20)

            CapsLabel("Library").padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            Scroll {
                VStack(spacing: 2) {
                    ForEach(store.books, id: \.id) { m in libraryRow(m) }
                    ForEach(store.importing, id: \.self) { name in
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Adding \(name)…").font(Theme.grotesk(13)).foregroundStyle(Theme.textDim).lineLimit(1)
                        }.padding(.horizontal, 12).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.horizontal, 12)
            }

            CapsLabel("Devices").padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 4)
            devices.padding(.bottom, 16)
        }
    }

    var dropZone: some View {
        Button { showImporter = true } label: {
            VStack(spacing: 6) {
                Text("＋").font(Theme.grotesk(22)).foregroundStyle(Theme.accentText)
                Text(dropping ? "Release to add" : "Drop EPUB files here").font(Theme.grotesk(14))
                    .foregroundStyle(dropping ? Theme.accentText : Theme.textDim)
            }
            .frame(maxWidth: .infinity).frame(height: store.books.isEmpty ? 160 : 84)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(dropping ? Theme.accent.opacity(0.2) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(dropping ? Theme.accentText : Theme.text.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    func libraryRow(_ m: BookManifest) -> some View {
        let selected = m.id == store.selection
        return Button { store.selection = m.id } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.title).font(Theme.display(18)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(m.author).font(Theme.grotesk(12)).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                Spacer(minLength: 6)
                status(m)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.surface : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Read") { openReader(m.id) }
            Button("Show original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([BookImporter.originalURL(for: m.id, in: store.library)]) }
            Divider()
            Button("Delete…", role: .destructive) { confirmDelete = m }
        }
    }

    @ViewBuilder func status(_ m: BookManifest) -> some View {
        let item = store.item(m)
        if store.render?.bookID == m.id {
            ProgressRing(value: Double(item.narrated) / Double(max(1, item.narratable))).frame(width: 16, height: 16)
        } else if store.queue.contains(m.id) {
            Text(store.paused ? "Paused" : "Queued").font(Theme.grotesk(12)).foregroundStyle(Theme.textDim)
        } else if item.isFullyNarrated {
            Text(Format.duration(m.totalDuration)).font(Theme.grotesk(12)).foregroundStyle(Theme.textDim)
        } else if item.narrated > 0 {
            Text("\(item.narrated)/\(item.narratable)").font(Theme.grotesk(12)).foregroundStyle(Theme.textDim)
        } else {
            Text("Text only").font(Theme.grotesk(12)).foregroundStyle(Theme.textDim)
        }
    }

    var devices: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.bridgeReady {
                deviceRow(on: false, name: "No account yet",
                          detail: "Join your account to share your library with your iPhone and your other Macs.")
            } else {
                deviceRow(on: true, name: store.accountName ?? "Your account", detail: "This Mac · \(store.books.count) book\(store.books.count == 1 ? "" : "s")")
                if store.accountDevices.isEmpty {
                    deviceRow(on: false, name: "No other devices yet", detail: "Scan the account’s QR code with your iPhone’s Camera.")
                }
                ForEach(store.accountDevices) { d in
                    let recent = d.online || Date().timeIntervalSince(d.lastSeen) < 600
                    let what = d.kind == .helper ? "Helps narrate" : "\(d.books) book\(d.books == 1 ? "" : "s")"
                    deviceRow(on: recent, name: d.name, detail: "\(what) · synced \(Format.ago(d.lastSeen))")
                }
            }
            ForEach(store.helping) { h in
                deviceRow(on: true, name: "Narrating for \(h.name)", detail: "Their books stay hidden from you and your devices")
            }
            Button { showLinkMac = true } label: {
                Text(store.bridgeReady ? "Account…" : "Join your account…")
                    .font(Theme.grotesk(13)).foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 24).padding(.vertical, 8)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if Features.xteink {
                Hairline().padding(.horizontal, 24)
                xteinkRow
            }
        }
        .sheet(isPresented: $showLinkMac) { LinkMacSheet(store: store) { showLinkMac = false } }
    }

    var xteinkRow: some View {
        let (on, detail): (Bool, String) = {
            switch store.xteink {
            case .looking:
                return (false, store.xteinkLastSync.map { "Last sync \(Format.ago($0)) · open File Transfer to send books" }
                               ?? "On the Xteink, open File Transfer to connect")
            case .found(_, let d), .done(let d): return (true, d)
            case .working(let d): return (true, d)
            case .failed(let d): return (false, d)
            }
        }()
        return HStack(alignment: .top) {
            deviceRow(on: on, name: "Xteink", detail: detail)
            if case .working = store.xteink { ProgressView().controlSize(.small).padding(.top, 12).padding(.trailing, 20) }
            else if on || { if case .failed = store.xteink { return true }; return false }() { TextLinkButton(on ? "Send now" : "Try again", size: 12) { store.kickXteink() }
                .padding(.top, 2).padding(.trailing, 24) }
        }
    }

    func deviceRow(on: Bool, name: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(on ? Theme.accent : Theme.text.opacity(0.2)).frame(width: 7, height: 7).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Theme.grotesk(14)).foregroundStyle(Theme.text)
                Text(detail).font(Theme.grotesk(12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.vertical, 9)
    }

    // MARK: Updates

    @ViewBuilder var updateBanner: some View {
        switch updater.state {
        case .ready(let build):
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("A new version of Habla is ready").font(Theme.grotesk(15)).foregroundStyle(Theme.ink)
                    Text(updater.canInstall ? "Build \(build). Restart now, or it installs the next time you quit."
                                            : "Build \(build). Move Habla to your Applications folder to update it automatically.")
                        .font(Theme.grotesk(12)).foregroundStyle(Theme.ink.opacity(0.85))
                }
                Spacer()
                CapsuleButton(updater.canInstall ? "Restart" : "Open download page", fill: Theme.screen.opacity(0.7)) { updater.installAndRelaunch() }
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(Theme.accent.opacity(0.55))
        case .failed(let message):
            HStack {
                Text(message).font(Theme.grotesk(12)).foregroundStyle(Theme.textDim)
                Spacer()
                TextLinkButton("OK", size: 12) { updater.dismissMessage() }
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            .background(Theme.surface)
        default:
            EmptyView()
        }
    }

    // MARK: Voice engine

    var voiceEngineBanner: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                switch store.voiceEngine {
                case .installing(let step):
                    Text("Installing the voice engine…").font(Theme.grotesk(15)).foregroundStyle(Theme.ink)
                    Text(step).font(Theme.grotesk(12)).foregroundStyle(Theme.ink.opacity(0.85))
                case .failed(let msg):
                    Text("The voice engine couldn't be installed").font(Theme.grotesk(15)).foregroundStyle(Theme.ink)
                    Text(msg).font(Theme.grotesk(12)).foregroundStyle(Theme.ink.opacity(0.85)).lineLimit(2)
                        .help(store.voiceEngineLog.suffix(15).joined(separator: "\n"))
                case .checking:
                    Text("Checking the voice engine…").font(Theme.grotesk(15)).foregroundStyle(Theme.ink)
                default:
                    Text("Install the voice engine to narrate books").font(Theme.grotesk(15)).foregroundStyle(Theme.ink)
                    Text("Kokoro runs on this Mac, free and offline. One download of about 340 MB — nothing else to install.")
                        .font(Theme.grotesk(12)).foregroundStyle(Theme.ink.opacity(0.85))
                }
            }
            Spacer()
            if case .installing = store.voiceEngine { ProgressView().controlSize(.small) }
            else if let script = installScript {
                CapsuleButton(store.voiceEngine == .missing ? "Install" : "Try again", fill: Theme.screen.opacity(0.7)) { store.installVoiceEngine(script: script) }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(Theme.accent)
    }

    // MARK: Detail

    var emptyDetail: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add your first book").font(Theme.display(44)).foregroundStyle(Theme.text)
            Text("Drop DRM-free EPUB files on this window. Habla narrates them with a natural voice and shares them with your iPhone over Wi-Fi.")
                .font(Theme.grotesk(16)).foregroundStyle(Theme.textDim).frame(maxWidth: 480, alignment: .leading)
            PillButton("Choose EPUB files…") { showImporter = true }.frame(width: 260).padding(.top, 10)
        }
        .padding(64).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func detail(_ m: BookManifest) -> some View {
        let item = store.item(m)
        let rendering = store.render?.bookID == m.id ? store.render : nil
        return HStack(alignment: .top, spacing: 48) {
            VStack(alignment: .leading, spacing: 0) {
                Text(m.title).font(Theme.display(46)).foregroundStyle(Theme.text).lineSpacing(-8)
                    .lineLimit(4).minimumScaleFactor(0.6).fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(Theme.accent).frame(width: 44, height: 2).padding(.top, 22)
                Text(m.author).font(Theme.displayItalic(20)).foregroundStyle(Theme.text.opacity(0.8)).padding(.top, 16)
                Text(meta(m)).font(Theme.grotesk(13)).foregroundStyle(Theme.textDim).padding(.top, 6)
                HStack(spacing: 10) {
                    PillButton("Read") { openReader(m.id) }.frame(width: 120)
                }.padding(.top, 24)

                CapsLabel("Voice").padding(.top, 40).padding(.bottom, 4)
                if m.canNarrate {
                    Scroll {
                        VStack(spacing: 0) { ForEach(store.voices(for: m), id: \.self) { v in voiceRow(v, book: m) } }
                    }
                } else {
                    Text("There’s no \(BookLanguage.name(m.language)) voice yet. This book is ready to read here and on your iPhone.")
                        .font(Theme.grotesk(13)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            }
            .frame(width: 340)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        CapsLabel("Narration")
                        Text(item.isTextOnly ? "Ready to read" : item.isFullyNarrated ? "Ready to listen" : "\(item.narrated) of \(item.narratable) chapters")
                            .font(Theme.display(28)).foregroundStyle(Theme.text)
                        Text(narrationDetail(m, item, rendering)).font(Theme.grotesk(13)).foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                    narrationButton(m, item)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.text.opacity(0.08))
                        Capsule().fill(Theme.accent).frame(width: g.size.width * narratedFraction(m, rendering))
                    }
                }.frame(height: 4).padding(.top, 20)

                Scroll {
                    VStack(spacing: 0) {
                        ForEach(m.chapters.filter { !$0.isFrontMatter }, id: \.index) { c in chapterRow(c, rendering, queued: store.queue.contains(m.id)) }
                    }
                }.padding(.top, 18)
            }
        }
        .padding(.horizontal, 48).padding(.top, 48).padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Smooth progress: sentences narrated / sentences to narrate.
    func narratedFraction(_ m: BookManifest, _ r: StudioStore.RenderState?) -> Double {
        if let r, r.bookSentencesTotal > 0 { return Double(r.bookSentencesDone) / Double(r.bookSentencesTotal) }
        let todo = m.chapters.filter { $0.audioStatus != .skipped }
        let total = todo.reduce(0) { $0 + $1.sentenceCount }
        let done = todo.filter { $0.audioStatus == .ready }.reduce(0) { $0 + $1.sentenceCount }
        return total > 0 ? Double(done) / Double(total) : 0
    }

    func meta(_ m: BookManifest) -> String {
        let words = m.chapters.reduce(0) { $0 + $1.wordCount }
        let chapters = m.chapters.filter { !$0.isFrontMatter }.count
        let hours = Double(words) / 155 / 60   // ~155 words a minute narrated
        return "\(chapters) chapters · \(words.formatted()) words · about \(hours < 1 ? "\(Int(hours * 60)) min" : String(format: "%.0f h", hours.rounded())) narrated"
    }

    func narrationDetail(_ m: BookManifest, _ item: BookItem, _ r: StudioStore.RenderState?) -> String {
        if let r {
            let eta = r.secondsLeft.map { " · about \(Format.duration($0)) left" } ?? ""
            return "Narrating “\(r.chapterTitle)” · sentence \(r.sentence) of \(r.sentenceCount)\(eta)"
        }
        if !m.canNarrate { return "Text only · no \(BookLanguage.name(m.language)) voice yet" }
        if store.queue.contains(m.id) { return store.paused ? "Paused" : (store.voiceEngine == .ready ? "Waiting for another book" : "Waiting for the voice engine") }
        if item.isFullyNarrated { return "\(Format.duration(m.totalDuration)) · \(voiceName(store.voice(for: m)))" }
        return "Not narrated yet — you can still read it"
    }

    @ViewBuilder func narrationButton(_ m: BookManifest, _ item: BookItem) -> some View {
        let active = store.render?.bookID == m.id
        let queued = store.queue.contains(m.id)
        if !m.canNarrate {
            EmptyView()
        } else if active && !store.paused {
            pill("Pause") { store.pauseNarration() }
        } else if queued && store.paused {
            pill("Resume") { store.resumeNarration(m.id) }
        } else if queued {
            pill("Cancel", filled: false) { store.cancelNarration(m.id) }
        } else if !item.isFullyNarrated {
            pill(item.narrated > 0 ? "Continue" : "Narrate") { store.narrate(m.id) }.disabled(store.voiceEngine != .ready)
                .help(store.voiceEngine == .ready ? "Narrate this book with the selected voice" : "Install the voice engine first (banner above)")
        } else if store.canRenarrate(m) {
            pill("Re-narrate with Kokoro", filled: false) { store.renarrate(m.id) }.disabled(store.voiceEngine != .ready)
                .help("This book was narrated with Paradee. Its audio keeps playing until each chapter is redone.")
        }
    }

    func pill(_ t: String, filled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(Theme.label(14)).foregroundStyle(filled ? Theme.ink : Theme.text)
                .padding(.horizontal, 22).frame(height: 40).background(Capsule().fill(filled ? Theme.accent : Theme.surface))
        }.buttonStyle(.plain)
    }

    func voiceRow(_ v: String, book m: BookManifest) -> some View {
        let on = store.voice(for: m) == v
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { if !on { store.setVoice(v, for: m) } } label: {
                    HStack(spacing: 12) {
                        Circle().strokeBorder(on ? Theme.accentText : Theme.text.opacity(0.25), lineWidth: on ? 5 : 1).frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voiceName(v)).font(Theme.grotesk(15)).foregroundStyle(Theme.text)
                            Text(voiceNote(v)).font(Theme.grotesk(12)).foregroundStyle(Theme.textDim)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(voiceName(v)), \(voiceNote(v))")
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                TextLinkButton(store.previewing == v ? "Playing…" : "▶ Preview", size: 12) { store.preview(v) }
                    .disabled(store.voiceEngine != .ready || store.previewing != nil)
                    .help(store.voiceEngine == .ready ? "Hear this voice" : "Install the voice engine first")
                    .accessibilityLabel(store.previewing == v ? "Playing \(voiceName(v))" : "Preview \(voiceName(v))")
            }
            Hairline()
        }
    }

    func voiceName(_ v: String) -> String { Imprint.voiceName(v) }
    func voiceNote(_ v: String) -> String {
        let accent = v.hasPrefix("e") ? "Spanish" : v.hasPrefix("b") ? "British" : "American"
        let gender = v.dropFirst().first == "m" ? "male" : "female"
        return "\(accent) · \(gender)\(v == "af_heart" ? " · recommended" : "")"
    }

    func chapterRow(_ c: ChapterInfo, _ r: StudioStore.RenderState?, queued: Bool) -> some View {
        let isNow = r?.chapterIndex == c.index && c.audioStatus == .pending
        let state: (String, Color) = c.audioStatus == .ready ? ("✓ \(c.duration.map(Format.duration) ?? "")", Theme.textDim)
            : isNow ? ("Narrating · \(Int(Double(r!.sentence) / Double(max(1, r!.sentenceCount)) * 100))%", Theme.accentText)
            : (queued ? "Waiting" : "Not narrated", Theme.textDim)
        return VStack(spacing: 0) {
            HStack {
                Text(ChapterNaming.title(c)).font(Theme.grotesk(15)).foregroundStyle(c.audioStatus == .ready || isNow ? Theme.text : Theme.textDim).lineLimit(1)
                Spacer()
                Text(state.0).font(Theme.grotesk(12)).foregroundStyle(state.1)
            }
            .padding(.vertical, 11)
            Hairline()
        }
    }
}

/// Reader window for the Mac: Apple Books-style two-page spread.
public struct StudioReaderWindow: View {
    @StateObject private var model: ReaderModel
    @ObservedObject var player: NarrationPlayer
    var dismiss: () -> Void
    let store: StudioStore
    @Environment(\.dismiss) private var closeWindow

    public init(store: StudioStore, bookID: String, player: NarrationPlayer, dismiss: @escaping () -> Void) {
        self.store = store
        let bundle = BookBundle(url: BookBundle.url(for: bookID, in: store.library))
        let m = (try? bundle.manifest()) ?? .missing(id: bookID)
        let p = store.progress.position(for: bookID)
        let model = ReaderModel(bundle: bundle, manifest: m,
                                chapter: p?.chapter ?? m.chapters.first { !$0.isFrontMatter }?.index ?? 0,
                                sentence: p?.sentence, style: StudioReaderWindow.loadStyle(), columns: 2)
        model.onPosition = { [weak store, weak player] c, s in
            if player?.bookID == bookID, player?.isPlaying == true { return }
            guard FileManager.default.fileExists(atPath: bundle.fileURL(BookBundle.manifestFile).path) else { return }   // deleted
            store?.progress.record(ReadingPosition(bookID: bookID, chapter: c, sentence: s, mode: .reading, deviceID: "mac",
                                                  fraction: m.fraction(chapter: c, sentence: s)))
        }
        _model = StateObject(wrappedValue: model)
        self.player = player
        self.dismiss = dismiss
    }

    public var body: some View {
        // Close (and Escape) close this reader window.
        ReaderView(model: model, player: player, onClose: { dismiss(); closeWindow() }, onStyle: { StudioReaderWindow.saveStyle($0) })
            .frame(minWidth: 900, minHeight: 600)
            .navigationTitle(model.manifest.title)
            .onDisappear { store.bookClosed() }                 // the place and marks go out now
    }

    static func loadStyle() -> ReaderStyle {
        let t = ReaderTheme(rawValue: UserDefaults.standard.string(forKey: "habla.mac.theme") ?? "") ?? .original
        let s = UserDefaults.standard.double(forKey: "habla.mac.size")
        return ReaderStyle(theme: t, fontSize: s > 0 ? CGFloat(s) : 19)
    }

    static func saveStyle(_ s: ReaderStyle) {
        UserDefaults.standard.set(s.theme.rawValue, forKey: "habla.mac.theme")
        UserDefaults.standard.set(Double(s.fontSize), forKey: "habla.mac.size")
    }
}

/// Links a second Mac to this library's cloud bridge: both then narrate, sync places and
/// marks, and new books go to whichever running Mac finishes them first. Also where this Mac
/// helps someone else's library (invite them, then paste their link code), and where a Mac
/// without a library starts one from an invite.
struct LinkMacSheet: View {
    @ObservedObject var store: StudioStore
    var onDone: () -> Void
    @State private var pasted = ""
    @State private var failed: String?
    @State private var copied = false
    @State private var working = false
    @State private var invite: String?
    @State private var inviteCopied = false
    @State private var helpName = ""
    @State private var helpCode = ""
    @State private var helpFailed: String?
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(store.bridgeReady ? "Account" : "Join your account").font(Theme.grotesk(17)).fontWeight(.semibold)
                if let link = store.accountLink {
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Account name", text: $name).textFieldStyle(.roundedBorder)
                                .onSubmit { store.renameAccount(name) }
                            Button("Rename") { store.renameAccount(name) }
                                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == store.accountName)
                            note("Every device in this account has the whole library: books, narration, your place and underlines. Deleting a book deletes it everywhere.")
                            note("iPhone: scan this code with the Camera and tap the Habla link. Another Mac: copy the code and paste it there. It works like a password: only use it on your own devices.")
                            Button(copied ? "Copied" : "Copy account code") { copy(link.absoluteString); copied = true }
                        }
                        QRCode(text: link.absoluteString)
                            .frame(width: 150, height: 150).padding(10)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
                    }
                    Divider()
                    helpSomeone
                    Divider()
                }
                note(store.bridgeReady ? "Or move this Mac into another account by pasting its code:"
                                       : "Paste your account’s code (copied on another Mac or iPhone), or an invite code someone sent you to start your own account:")
                TextField(store.bridgeReady ? "habla://account…" : "habla://account… or habla-invite:…", text: $pasted).textFieldStyle(.roundedBorder)
                Toggle("Help narrate only", isOn: $store.helperOnly)
                Text("This Mac narrates books for your devices without showing them, syncing your places or marks, or keeping them afterwards.")
                    .font(Theme.grotesk(12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                if let failed { Text(failed).font(Theme.grotesk(12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Spacer()
                    Button("Close", action: onDone)
                    Button(working ? "Joining…" : "Join") { join() }
                        .keyboardShortcut(.defaultAction).disabled(pasted.isEmpty || working)
                }
            }
            .padding(22)
        }
        .frame(width: 520).frame(minHeight: 360, idealHeight: store.bridgeReady ? 720 : 360)
        .onAppear { name = store.accountName ?? "" }
    }

    /// Someone with their own Mac and iPhone: invite them, then narrate for them.
    var helpSomeone: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Help someone else").font(Theme.grotesk(15)).fontWeight(.semibold)
            note("1. Send an invite code to someone with their own Mac. They paste it in “Join your account…” to start their own account. It works once, for 7 days.")
            if let invite {
                Button(inviteCopied ? "Copied" : "Copy invite code") { copy(invite); inviteCopied = true }
            } else {
                Button(working ? "Creating…" : "Create invite code") { makeInvite() }.disabled(working)
            }
            note("2. Paste the account code their Mac shows under “Account…”. This Mac then narrates their books in the background: you never see them, and they never reach your iPhone or your other Macs.")
            HStack {
                TextField("Their name", text: $helpName).textFieldStyle(.roundedBorder).frame(width: 120)
                TextField("habla://account…", text: $helpCode).textFieldStyle(.roundedBorder)
                Button("Help") { help() }.disabled(helpCode.isEmpty)
            }
            if let helpFailed { Text(helpFailed).font(Theme.grotesk(12)).foregroundStyle(.red) }
            ForEach(store.helping) { h in
                HStack {
                    let jobs = store.helpingJobs[h.id] ?? 0
                    Text("Narrating for \(h.name)" + (jobs > 0 ? " · \(jobs) book\(jobs == 1 ? "" : "s")" : ""))
                        .font(Theme.grotesk(13))
                    Spacer()
                    Button("Stop helping") { store.stopHelping(h) }
                }
            }
        }
    }

    func note(_ s: String) -> some View {
        Text(s).font(Theme.grotesk(13)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
    }

    func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

    func join() {
        failed = nil
        if BridgeCode.parseInvite(pasted) != nil {
            guard !store.bridgeReady else { failed = "This Mac already has a library. Invite codes are for a Mac that has none."; return }
            working = true
            Task {
                do { try await store.startLibrary(invite: pasted); working = false; pasted = "" }
                catch { working = false; failed = "That invite didn’t work: it may be used, expired, or the bridge is unreachable. Ask for a new one." }
            }
            return
        }
        if store.joinBridge(code: pasted) { onDone() } else { failed = "That isn’t a Habla account or invite code." }
    }

    func makeInvite() {
        working = true
        Task {
            do { invite = try await store.makeInvite() } catch { helpFailed = "Couldn’t create an invite: \(error)" }
            working = false
        }
    }

    func help() {
        helpFailed = nil
        do {
            try store.startHelping(name: helpName, code: helpCode)
            helpName = ""; helpCode = ""
        } catch StudioStore.HelpError.ownLibrary {
            helpFailed = "That’s this Mac’s own library."
        } catch StudioStore.HelpError.already {
            helpFailed = "This Mac already helps that library."
        } catch {
            helpFailed = "That isn’t a Habla account code."
        }
    }
}

/// A crisp QR code (Core Image, scaled without smoothing).
struct QRCode: View {
    let text: String
    var body: some View {
        if let image = Self.make(text) {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().aspectRatio(1, contentMode: .fit)
                .accessibilityLabel("Pairing code")
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
#endif
