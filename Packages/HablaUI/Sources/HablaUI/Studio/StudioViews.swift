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
    @State private var dropping = false
    @State private var showImporter = false
    @State private var confirmDelete: BookManifest?
    @State private var confirmForget: PairedDevice?

    public init(store: StudioStore, updater: StudioUpdater = StudioUpdater(), installScript: URL?, openReader: @escaping (String) -> Void) {
        self.store = store; self.updater = updater; self.installScript = installScript; self.openReader = openReader
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 320)
            Rectangle().fill(Theme.hairline).frame(width: 0.5)
            VStack(spacing: 0) {
                if store.kokoro != .ready { kokoroBanner }
                updateBanner
                if let m = store.selected { detail(m) } else { emptyDetail }
            }
        }
        .background(Theme.screen)
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
            Button("Delete book and narration", role: .destructive) { if let m = confirmDelete { store.delete(m.id) }; confirmDelete = nil }
        } message: { Text(Features.xteink ? "Copies already on your iPhone or Xteink stay there." : "A copy already on your iPhone stays there.") }
    }

    // MARK: Sidebar

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("HABLA").font(Theme.label(10)).tracking(1.4).foregroundStyle(Theme.text)
                Spacer()
                Button { showImporter = true } label: { Image(systemName: "plus").font(.system(size: 14, weight: .medium)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.accentText).help("Add EPUB books")
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 18)

            dropZone.padding(.horizontal, 20)

            CapsLabel("Library").padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 6)
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
        return HStack(spacing: 12) {
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
        .onTapGesture { store.selection = m.id }
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
            if store.devices.isEmpty {
                deviceRow(on: false, name: "No iPhone yet",
                          detail: !store.onWiFi ? "This Mac isn't on Wi-Fi" : "Pair your iPhone to share books and your place.")
            }
            ForEach(store.devices) { d in
                let recent = d.lastSeen.map { Date().timeIntervalSince($0) < 600 } ?? false
                deviceRow(on: recent, name: d.name, detail: d.lastSeen.map { "Synced \(Format.ago($0))" } ?? "Paired")
                    .contextMenu { Button("Forget “\(d.name)”…", role: .destructive) { confirmForget = d } }
            }
            Button { store.startPairing() } label: {
                Text(store.devices.isEmpty ? "Pair iPhone…" : "Pair another device…")
                    .font(Theme.grotesk(13)).foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 24).padding(.vertical, 8)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if Features.xteink {
                Hairline().padding(.horizontal, 24)
                xteinkRow
            }
        }
        .sheet(isPresented: Binding(get: { store.pairingCode != nil }, set: { if !$0 { store.stopPairing() } })) {
            if let p = store.pairingCode { PairingSheet(pairing: p, macName: store.serverName, encrypted: store.encrypted) { store.stopPairing() } }
        }
        .confirmationDialog("Forget “\(confirmForget?.name ?? "")”?", isPresented: Binding(get: { confirmForget != nil }, set: { if !$0 { confirmForget = nil } })) {
            Button("Forget", role: .destructive) { if let d = confirmForget { store.forget(d) }; confirmForget = nil }
        } message: { Text("It won't be able to sync with this Mac until you pair it again. Its downloaded books stay on it.") }
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
            else if on || { if case .failed = store.xteink { return true }; return false }() { Button(on ? "Send now" : "Try again") { store.kickXteink() }.buttonStyle(.plain).font(Theme.grotesk(12))
                .foregroundStyle(Theme.accentText).padding(.top, 12).padding(.trailing, 24) }
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
                        .font(Theme.grotesk(12)).foregroundStyle(Theme.ink.opacity(0.65))
                }
                Spacer()
                Button(updater.canInstall ? "Restart" : "Download") { updater.installAndRelaunch() }
                    .buttonStyle(.plain).font(Theme.label(13)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 16).frame(height: 32).background(Capsule().fill(Theme.screen.opacity(0.7)))
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(Theme.accent.opacity(0.55))
        case .failed(let message):
            HStack {
                Text(message).font(Theme.grotesk(12)).foregroundStyle(Theme.textDim)
                Spacer()
                Button("OK") { updater.dismissMessage() }.buttonStyle(.plain).font(Theme.grotesk(12)).foregroundStyle(Theme.accentText)
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            .background(Theme.surface)
        default:
            EmptyView()
        }
    }

    // MARK: Kokoro

    var kokoroBanner: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                switch store.kokoro {
                case .installing(let step):
                    Text("Installing the voice engine…").font(Theme.grotesk(15)).foregroundStyle(Theme.ink)
                    Text(step).font(Theme.grotesk(12)).foregroundStyle(Theme.ink.opacity(0.65))
                case .failed(let msg):
                    Text("The voice engine couldn't be installed").font(Theme.grotesk(15)).foregroundStyle(Theme.ink)
                    Text(msg).font(Theme.grotesk(12)).foregroundStyle(Theme.ink.opacity(0.65)).lineLimit(2)
                        .help(store.kokoroLog.suffix(15).joined(separator: "\n"))
                case .checking:
                    Text("Checking the voice engine…").font(Theme.grotesk(15)).foregroundStyle(Theme.ink)
                default:
                    Text("Install the voice engine to narrate books").font(Theme.grotesk(15)).foregroundStyle(Theme.ink)
                    Text("Kokoro runs on this Mac, free and offline. One download of about 350 MB — nothing else to install.")
                        .font(Theme.grotesk(12)).foregroundStyle(Theme.ink.opacity(0.65))
                }
            }
            Spacer()
            if case .installing = store.kokoro { ProgressView().controlSize(.small) }
            else if let script = installScript {
                Button(store.kokoro == .missing ? "Install" : "Try again") { store.installKokoro(script: script) }
                    .buttonStyle(.plain).font(Theme.label(13)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 16).frame(height: 32).background(Capsule().fill(Theme.screen.opacity(0.7)))
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
                Scroll {
                    VStack(spacing: 0) { ForEach(store.voices, id: \.self) { v in voiceRow(v, book: m) } }
                }
            }
            .frame(width: 340)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        CapsLabel("Narration")
                        Text(item.isFullyNarrated ? "Ready to listen" : "\(item.narrated) of \(item.narratable) chapters")
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
        if store.queue.contains(m.id) { return store.paused ? "Paused" : (store.kokoro == .ready ? "Waiting for another book" : "Waiting for the voice engine") }
        if item.isFullyNarrated { return "\(Format.duration(m.totalDuration)) · \(voiceName(store.voice(for: m)))" }
        return "Not narrated yet — you can still read it"
    }

    @ViewBuilder func narrationButton(_ m: BookManifest, _ item: BookItem) -> some View {
        let active = store.render?.bookID == m.id
        let queued = store.queue.contains(m.id)
        if active && !store.paused {
            pill("Pause") { store.pauseNarration() }
        } else if queued && store.paused {
            pill("Resume") { store.resumeNarration() }
        } else if queued {
            pill("Cancel", filled: false) { store.cancelNarration(m.id) }
        } else if !item.isFullyNarrated {
            pill(item.narrated > 0 ? "Continue" : "Narrate") { store.narrate(m.id) }.disabled(store.kokoro != .ready)
                .help(store.kokoro == .ready ? "Narrate this book with the selected voice" : "Install the voice engine first (banner above)")
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
                Circle().strokeBorder(on ? Theme.accentText : Theme.text.opacity(0.25), lineWidth: on ? 5 : 1).frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(voiceName(v)).font(Theme.grotesk(15)).foregroundStyle(Theme.text)
                    Text(voiceNote(v)).font(Theme.grotesk(12)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                Button(store.previewing == v ? "Playing…" : "▶ Preview") { store.preview(v) }
                    .buttonStyle(.plain).font(Theme.grotesk(12)).foregroundStyle(Theme.accentText)
                    .disabled(store.kokoro != .ready || store.previewing != nil)
                    .help(store.kokoro == .ready ? "Hear this voice" : "Install the voice engine first")
            }
            .padding(.vertical, 10)
            Hairline()
        }
        .contentShape(Rectangle())
        .onTapGesture { if !on { store.setVoice(v, for: m) } }
    }

    func voiceName(_ v: String) -> String { (v.split(separator: "_").last.map(String.init) ?? v).capitalized }
    func voiceNote(_ v: String) -> String {
        let accent = v.hasPrefix("b") ? "British" : "American"
        let gender = v.dropFirst().first == "m" ? "male" : "female"
        return "\(accent) · \(gender)\(v == "af_heart" ? " · recommended" : "")"
    }

    func chapterRow(_ c: ChapterInfo, _ r: StudioStore.RenderState?, queued: Bool) -> some View {
        let isNow = r?.chapterIndex == c.index && c.audioStatus == .pending
        let state: (String, Color) = c.audioStatus == .ready ? ("✓ \(c.duration.map(Format.duration) ?? "")", Theme.textDim)
            : isNow ? ("Narrating · \(Int(Double(r!.sentence) / Double(max(1, r!.sentenceCount)) * 100))%", Theme.accentText)
            : (queued ? "Waiting" : "Not narrated", Theme.textDim.opacity(0.7))
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

    public init(store: StudioStore, bookID: String, player: NarrationPlayer, dismiss: @escaping () -> Void) {
        let bundle = BookBundle(url: BookBundle.url(for: bookID, in: store.library))
        let m = (try? bundle.manifest()) ?? .missing(id: bookID)
        let p = store.progress.position(for: bookID)
        let model = ReaderModel(bundle: bundle, manifest: m,
                                chapter: p?.chapter ?? m.chapters.first { !$0.isFrontMatter }?.index ?? 0,
                                sentence: p?.sentence, style: StudioReaderWindow.loadStyle(), columns: 2)
        model.onPosition = { [weak store, weak player] c, s in
            if player?.bookID == bookID, player?.isPlaying == true { return }
            guard FileManager.default.fileExists(atPath: bundle.fileURL(BookBundle.manifestFile).path) else { return }   // deleted
            store?.progress.merge(ReadingPosition(bookID: bookID, chapter: c, sentence: s, mode: .reading, deviceID: "mac",
                                                  fraction: m.fraction(chapter: c, sentence: s)))
        }
        _model = StateObject(wrappedValue: model)
        self.player = player
        self.dismiss = dismiss
    }

    public var body: some View {
        ReaderView(model: model, player: player, onClose: dismiss, onStyle: { StudioReaderWindow.saveStyle($0) })
            .frame(minWidth: 900, minHeight: 600)
            .navigationTitle(model.manifest.title)
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

/// "Pair your iPhone": a QR code for the iPhone camera, and the same code to type.
public struct PairingSheet: View {
    let pairing: StudioStore.PairingCode
    let macName: String
    let encrypted: Bool
    let done: () -> Void

    public init(pairing: StudioStore.PairingCode, macName: String, encrypted: Bool, done: @escaping () -> Void) {
        self.pairing = pairing; self.macName = macName; self.encrypted = encrypted; self.done = done
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pair your iPhone").font(Theme.display(34)).foregroundStyle(Theme.text)
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "On the iPhone, open the Camera and point it at this code. Tap the Habla link.")
                    step(2, "Or open Habla → MAC, choose “\(macName)” and type:")
                }
                Text(pairing.code).font(.system(size: 30, weight: .semibold, design: .monospaced)).tracking(2)
                    .foregroundStyle(Theme.text).textSelection(.enabled).padding(.leading, 26)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(pairing.expires.timeIntervalSince(ctx.date)))
                    Text(left > 0 ? "Works once, for \(left / 60):\(String(format: "%02d", left % 60))" : "This code expired")
                        .font(Theme.grotesk(12)).foregroundStyle(Theme.textDim).monospacedDigit()
                }.padding(.leading, 26)
                Text(encrypted ? "Only paired devices can see your books. Everything between them and this Mac is encrypted."
                               : "Only paired devices can see your books.")
                    .font(Theme.grotesk(12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                Spacer(minLength: 0)
                PillButton("Done", filled: false, action: done).frame(width: 140)
            }
            .frame(width: 330, alignment: .leading)
            QRCode(text: pairing.invite.absoluteString)
                .frame(width: 220, height: 220)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white))
        }
        .padding(36)
        .frame(width: 680, height: 420)
        .background(Theme.screen)
    }

    func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(Theme.label(12)).foregroundStyle(Theme.accentText).frame(width: 16)
            Text(text).font(Theme.grotesk(14)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
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
