import SwiftUI
import UniformTypeIdentifiers
import HablaCore

// MARK: - Library (home)

public struct PhoneLibraryView: View {
    @ObservedObject var store: PhoneStore
    @ObservedObject var player: NarrationPlayer
    var open: (PhoneRoute) -> Void
    @State private var picking = false

    public init(store: PhoneStore, player: NarrationPlayer, open: @escaping (PhoneRoute) -> Void) {
        self.store = store; self.player = player; self.open = open
    }

    var local: [BookItem] { store.books.filter { if case .remote = $0.availability { return false }; return true } }
    var remote: [BookItem] { store.books.filter { if case .remote = $0.availability { return true }; return false } }
    var hero: BookItem? { store.current ?? local.first }

    public var body: some View {
        AccentFrame(accent: Theme.accent) {
            VStack(spacing: 0) {
                TopBar("Habla", leading: "+", trailing: "MAC", onLeading: { picking = true }, onTrailing: { open(.mac) })
                Scroll {
                    VStack(alignment: .leading, spacing: 0) {
                        StaggeredCaps([.init("\(Greeting.now()) ——"),
                                       .init(hero?.isStarted == true ? "keep listening" : "start a book", indent: 44)], size: 24)
                            .padding(.horizontal, Theme.margin).padding(.top, 20)

                        if let hero { heroCard(hero).padding(.horizontal, Theme.margin - 8).padding(.top, 28) }
                        else { emptyState.padding(.horizontal, Theme.margin).padding(.top, 36) }

                        let others = local.filter { $0.id != hero?.id }
                        if !others.isEmpty {
                            CapsLabel("Library").padding(.horizontal, Theme.margin).padding(.top, Theme.section + 8).padding(.bottom, 4)
                            VStack(spacing: 0) {
                                ForEach(others) { b in
                                    Button { open(.book(b.id)) } label: { row(b) }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal, Theme.margin)
                        }
                        if store.importing > 0 {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Adding \(store.importing == 1 ? "a book" : "\(store.importing) books")…").font(Theme.grotesk(14)).foregroundStyle(Theme.textDim)
                            }.padding(.horizontal, Theme.margin).padding(.top, 20)
                        }
                        if !remote.isEmpty {
                            CapsLabel("On your Mac").padding(.horizontal, Theme.margin).padding(.top, Theme.section).padding(.bottom, 4)
                            VStack(spacing: 0) { ForEach(remote) { b in remoteRow(b) } }.padding(.horizontal, Theme.margin)
                        }
                        connectionLine.padding(.horizontal, Theme.margin).padding(.top, 28)
                        if let u = store.appUpdate { updateLine(u).padding(.horizontal, Theme.margin).padding(.top, 14) }
                        Color.clear.frame(height: 110)
                    }
                }
                .refreshable { await store.sync() }
            }
            .overlay(alignment: .bottom) { if player.isLoaded { MiniPlayer(player: player) { open(.player) }.padding(12) } }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data],
                      allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { store.importBooks(urls) }
        }
    }

    func heroCard(_ b: BookItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(b.isStarted ? (b.currentChapter?.title ?? "") : "New in your library")
                .font(Theme.grotesk(13)).foregroundStyle(Theme.ink.opacity(0.85)).lineLimit(1)
            Text(b.title).font(Theme.display(42)).foregroundStyle(Theme.ink)
                .lineSpacing(-6).lineLimit(3).minimumScaleFactor(0.55).padding(.top, 14)
            Text(b.author).font(Theme.displayItalic(19)).foregroundStyle(Theme.ink.opacity(0.7)).lineLimit(1).padding(.top, 6)
            Spacer(minLength: 20)
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.ink.opacity(0.15))
                            Capsule().fill(Theme.ink.opacity(0.75)).frame(width: max(3, g.size.width * b.progress))
                        }
                    }.frame(height: 3)
                    Text(heroStatus(b)).font(Theme.grotesk(12)).foregroundStyle(Theme.ink.opacity(0.85)).lineLimit(1)
                }
                if b.hasAudio && b.availability == .local {
                    DashedCircleButton(player.isPlaying && player.bookID == b.id ? "❙❙" : "▶", size: 54, color: Theme.ink) { resume(b) }
                        .accessibilityLabel(player.isPlaying && player.bookID == b.id ? "Pause" : (b.isStarted ? "Resume listening" : "Start listening"))
                }
            }
        }
        .padding(24)
        .frame(minHeight: 290, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.accent))
        .contentShape(RoundedRectangle(cornerRadius: 26))
        .onTapGesture { open(.book(b.id)) }
        // VoiceOver: one button that opens the book; listening is an action on it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(b.title), \(b.author). \(heroStatus(b).replacingOccurrences(of: "/", with: " of "))")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the book")
        .accessibilityAction { open(.book(b.id)) }
        .accessibilityActions {
            if b.hasAudio && b.availability == .local {
                Button(player.isPlaying && player.bookID == b.id ? "Pause" : (b.isStarted ? "Resume listening" : "Start listening")) { resume(b) }
            }
            Button("Read") { open(.reader(b.id)) }
        }
    }

    func heroStatus(_ b: BookItem) -> String {
        if store.isWaitingForMac(b.id) { return b.isTextOnly ? "Readable now · sending to your Mac" : "Readable now · narration starts when your Mac is on" }
        var parts = [!b.isStarted ? "Not started" : b.progress < 0.01 ? "Just started" : "\(Int((b.progress * 100).rounded()))%"]
        if b.isTextOnly { parts.append("text only") }
        else if !b.isFullyNarrated { parts.append("narrating \(b.narrated)/\(b.narratable)") }
        else if let m = b.minutesLeft { parts.append("\(Format.duration(Double(m) * 60)) left") }
        return parts.joined(separator: " · ")
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

    func row(_ b: BookItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Circle().fill(Theme.accent).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 4) {
                    Text(b.title).font(Theme.display(22)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(store.isWaitingForMac(b.id) ? "\(b.author) · waiting for your Mac" : b.author)
                        .font(Theme.grotesk(13)).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                Spacer(minLength: 8)
                switch b.availability {
                case .downloading(let f): ProgressRing(value: f).frame(width: 18, height: 18)
                default:
                    Text(b.isStarted ? "\(Int((b.progress * 100).rounded()))%" : "New")
                        .font(Theme.grotesk(14)).foregroundStyle(b.isStarted ? Theme.accentText : Theme.textDim)
                }
            }
            .padding(.vertical, 18)
            Hairline()
        }
        .contentShape(Rectangle())
    }

    func remoteRow(_ b: BookItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Circle().strokeBorder(Theme.accentText, lineWidth: 1).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 4) {
                    Text(b.title).font(Theme.display(22)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(b.isFullyNarrated ? b.author : b.isTextOnly ? "\(b.author) · text only" : "\(b.author) · narrating \(b.narrated)/\(b.narratable)")
                        .accessibilityLabel(b.isFullyNarrated ? b.author : b.isTextOnly ? "\(b.author), text only" : "\(b.author), \(b.narrated) of \(b.narratable) chapters narrated")
                        .font(Theme.grotesk(13)).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                Spacer(minLength: 8)
                switch b.availability {
                case .downloading(let f): ProgressRing(value: f).frame(width: 18, height: 18)
                case .remote(let bytes):
                    Button { Task { try? await store.download(b.id) } } label: {
                        Text("Get · \(Format.bytes(bytes))").font(Theme.label(13)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 12).frame(height: 32).background(Capsule().fill(Theme.accent))
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Download \(b.title)")
                default: EmptyView()
                }
            }
            .padding(.vertical, 16)
            Hairline()
        }
    }

    var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your shelf is empty").font(Theme.display(30)).foregroundStyle(Theme.text)
            Text("Add a DRM-free EPUB here or in Habla on your Mac. You can read it right away; your Mac narrates it and the audio arrives over Wi-Fi.")
                .font(Theme.grotesk(15)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            PillButton("Add a book") { picking = true }.frame(width: 200).padding(.top, 8)
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

extension PhoneStore {
    public var isConnected: Bool { if case .connected = connection { return lastSync != nil }; return false }
    public var connectionSummary: String {
        guard let mac = paired else { return "Not paired · tap MAC (top right) to pair with your Mac" }
        switch connection {
        case .connected(let name, _): return lastSync == nil ? "Connecting to \(name)…" : "\(name) · synced \(Format.ago(lastSync))"
        case .searching: return "Looking for \(mac.name.replacingOccurrences(of: "Habla on ", with: ""))…"
        case .unreachable: return "Mac not reachable · your books still work offline"
        }
    }
}

/// Bottom bar while something is loaded in the player.
public struct MiniPlayer: View {
    @ObservedObject var player: NarrationPlayer
    var open: () -> Void
    public init(player: NarrationPlayer, open: @escaping () -> Void) { self.player = player; self.open = open }
    public var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.chapterTitle.isEmpty ? player.bookTitle : player.chapterTitle)
                    .font(Theme.grotesk(14)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(player.bookTitle).font(Theme.grotesk(12)).foregroundStyle(Theme.ink.opacity(0.85)).lineLimit(1)
            }
            Spacer()
            if player.duration > 0 {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 17))
                    .foregroundStyle(Theme.ink).frame(width: 44, height: 44)
            }.buttonStyle(.plain).accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            }
        }
        .padding(.leading, 18).padding(.trailing, 6)
        .frame(height: 60)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.accent)
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4))
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

    public init(store: PhoneStore, player: NarrationPlayer, id: String, open: @escaping (PhoneRoute) -> Void, close: @escaping () -> Void) {
        self.store = store; self.player = player; self.id = id; self.open = open; self.close = close
    }

    var book: BookItem? { store.books.first { $0.id == id } }

    public var body: some View {
        AccentFrame(accent: Theme.accent) {
            VStack(spacing: 0) {
                TopBar("", leading: "‹", trailing: "", onLeading: close)
                if let b = book {
                    Scroll { content(b) }
                } else {
                    Spacer()
                }
            }
        }
        .onChange(of: book == nil) { _, gone in if gone { close() } }
        .confirmationDialog("Remove from this iPhone?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove download", role: .destructive) { if player.bookID == id { player.unload() }; store.delete(id); close() }
        } message: { Text(store.paired == nil
            ? "Your place and underlines are kept. To get it back, add the EPUB again."
            : "Your place and underlines are kept. You can download it again from your Mac.") }
    }

    func content(_ b: BookItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(b.title).font(Theme.display(50)).foregroundStyle(Theme.text).lineSpacing(-8)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Theme.accent).frame(width: 44, height: 2).padding(.top, 22)
            Text(b.author).font(Theme.displayItalic(21)).foregroundStyle(Theme.text.opacity(0.8)).padding(.top, 18)
            Text(meta(b) + (store.updating.contains(b.id) ? " · updating…" : "")).font(Theme.grotesk(13)).foregroundStyle(Theme.textDim).padding(.top, 6)

            actions(b).padding(.top, Theme.section)

            if b.chapters.contains(where: { !$0.isFrontMatter }) {
                CapsLabel("Chapters").padding(.top, Theme.section + 8).padding(.bottom, 2)
                ForEach(b.chapters.filter { !$0.isFrontMatter }) { c in
                    Button { openChapter(b, c) } label: { chapterRow(b, c) }.buttonStyle(.plain)
                }
            }
            if b.availability == .local {
                TextLinkButton("Remove download", color: Theme.textDim) { confirmRemove = true }.padding(.top, 18)
            }
        }
        .padding(.horizontal, Theme.margin).padding(.top, 36).padding(.bottom, 60)
    }

    func meta(_ b: BookItem) -> String {
        var parts: [String] = []
        let chapters = b.chapters.filter { !$0.isFrontMatter }.count
        if chapters > 0 { parts.append("\(chapters) chapters") }
        if b.duration > 0 { parts.append(Format.duration(b.duration)) }
        if b.isTextOnly { parts.append("text only") }
        else if !b.isFullyNarrated { parts.append("narrating \(b.narrated) of \(b.narratable)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder func actions(_ b: BookItem) -> some View {
        switch b.availability {
        case .remote(let bytes):
            PillButton("Download · \(Format.bytes(bytes))") { Task { try? await store.download(b.id) } }
        case .downloading(let f):
            HStack(spacing: 12) { ProgressRing(value: f).frame(width: 22, height: 22); Text("Downloading… \(Int(f * 100))%").font(Theme.grotesk(15)) }
                .frame(height: 52)
        case .local:
            HStack(spacing: 12) {
                if b.hasAudio {
                    PillButton(b.isStarted ? "Continue listening" : "Listen") { listen(b, chapter: nil) }
                }
                PillButton("Read", filled: !b.hasAudio) { open(.reader(b.id)) }.frame(maxWidth: b.hasAudio ? 110 : .infinity)
            }
        }
    }

    func chapterRow(_ b: BookItem, _ c: ChapterItem) -> some View {
        let current = b.isStarted && c.index == b.resumeChapter
        let done = b.isStarted && c.index < b.resumeChapter
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(c.title).font(Theme.grotesk(16))
                    .foregroundStyle(current ? Theme.accentText : (done ? Theme.textDim : Theme.text)).lineLimit(1)
                Spacer()
                Text(done ? "✓" : c.minutes.map { "\($0) min" } ?? "").accessibilityLabel(done ? "Finished" : c.minutes.map { "\($0) minutes" } ?? "")
                    .font(Theme.grotesk(13)).foregroundStyle(current ? Theme.accentText : Theme.textDim)
            }
            .padding(.vertical, 17)
            Hairline()
        }
        .contentShape(Rectangle())
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
    var close: () -> Void
    var read: () -> Void
    @State private var scrub: Double?

    public init(player: NarrationPlayer, close: @escaping () -> Void, read: @escaping () -> Void) {
        self.player = player; self.close = close; self.read = read
    }

    public var body: some View {
        AccentFrame(accent: Theme.accent) {
            VStack(spacing: 0) {
                TopBar("", leading: "⌄", trailing: "", onLeading: close)
                VStack(spacing: 0) {
                    Text(player.bookTitle).font(Theme.display(44)).foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center).lineSpacing(-6).lineLimit(3).minimumScaleFactor(0.6)
                    Rectangle().fill(Theme.accent).frame(width: 44, height: 2).padding(.top, 30)
                    Text(player.author).font(Theme.displayItalic(18)).foregroundStyle(Theme.text.opacity(0.7)).padding(.top, 10)
                    Text(player.chapterTitle).font(Theme.display(25)).foregroundStyle(Theme.accentText)
                        .multilineTextAlignment(.center).lineLimit(2).padding(.top, 34)
                    if let m = player.message {
                        Text(m).font(Theme.grotesk(14)).foregroundStyle(Theme.textDim).multilineTextAlignment(.center).padding(.top, 18)
                    }
                }
                .padding(.horizontal, Theme.margin + 6).padding(.top, 44)

                Spacer(minLength: 16)

                if player.duration == 0 {
                    // Nothing narrated to play yet: no empty transport, just the way forward.
                    PillButton("Read instead", action: read).padding(.horizontal, Theme.margin).padding(.bottom, 40)
                } else {
                    transportControls
                }
            }
        }
    }

    @ViewBuilder var transportControls: some View {
                scrubber.padding(.horizontal, Theme.margin)
                HStack {
                    Text(Format.clock(scrub.map { $0 * player.duration } ?? player.time))
                    Spacer()
                    Text("−" + Format.clock(player.duration - (scrub.map { $0 * player.duration } ?? player.time)))
                }
                .font(Theme.grotesk(12)).monospacedDigit().foregroundStyle(Theme.textDim)
                .padding(.horizontal, Theme.margin).padding(.top, 8)

                HStack {
                    transport("gobackward.15", "Back 15 seconds") { player.skip(-15) }
                    Spacer()
                    Button { player.toggle() } label: {
                        ZStack {
                            Circle().fill(Theme.accent)
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 28))
                                .foregroundStyle(Theme.ink).offset(x: player.isPlaying ? 0 : 2)
                        }.frame(width: 78, height: 78)
                    }.buttonStyle(.plain).accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    Spacer()
                    transport("goforward.30", "Forward 30 seconds") { player.skip(30) }
                }
                .padding(.horizontal, 48).padding(.top, 22)

                HStack {
                    Button { player.cycleRate() } label: {
                        Text(rateLabel).font(Theme.grotesk(15)).frame(minWidth: 56, minHeight: 44, alignment: .leading)
                    }.accessibilityLabel("Playback speed \(rateLabel)")
                    Spacer()
                    Menu {
                        Button("Off") { player.setSleepTimer(minutes: nil) }
                        Button("End of chapter") { player.setSleepTimer(minutes: -1) }
                        ForEach([10, 20, 30, 45, 60], id: \.self) { m in Button("\(m) minutes") { player.setSleepTimer(minutes: m) } }
                    } label: {
                        Text(sleepLabel).font(Theme.grotesk(15)).frame(minHeight: 44)
                    }
                    Spacer()
                    Button(action: read) { Text("Read along").font(Theme.grotesk(15)).frame(minHeight: 44) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
                .padding(.horizontal, Theme.margin + 4).padding(.top, 22).padding(.bottom, 24)
    }

    var rateLabel: String {
        let r = player.rate
        return r == r.rounded() ? "\(Int(r))×" : String(format: "%g×", r)
    }

    var sleepLabel: String {
        switch player.sleepTimer {
        case nil: return "Sleep"
        case -1: return "Sleep · chapter end"
        case let m?: return "Sleep · \(m) min"
        }
    }

    func transport(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 26)).foregroundStyle(Theme.text).frame(width: 52, height: 52) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }

    var scrubber: some View {
        GeometryReader { g in
            let f = scrub ?? (player.duration > 0 ? player.time / player.duration : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.text.opacity(0.12)).frame(height: 4)
                Capsule().fill(Theme.accent).frame(width: max(4, g.size.width * f), height: 4)
                Circle().fill(Theme.accentText).frame(width: scrub == nil ? 12 : 18, height: scrub == nil ? 12 : 18)
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
}

// MARK: - Mac connection

public struct PhoneMacView: View {
    @ObservedObject var store: PhoneStore
    var close: () -> Void
    @State private var address = ""
    @State private var storageLine = ""
    @State private var chosen: ServiceBrowser.Service?
    @State private var code = ""
    @State private var confirmUnpair = false
    @FocusState private var codeFocused: Bool

    public init(store: PhoneStore, close: @escaping () -> Void) { self.store = store; self.close = close }

    public var body: some View {
        AccentFrame(accent: Theme.accent) {
            VStack(spacing: 0) {
                TopBar("", leading: "‹", trailing: "", onLeading: close)
                Scroll {
                    VStack(alignment: .leading, spacing: 0) {
                        StaggeredCaps([.init("Habla ——"), .init("on your Mac", indent: 60)], size: 24)
                        if let mac = store.paired { pairedSection(mac) } else { pairingSection }
                        if let e = store.error {
                            Text(e).font(Theme.grotesk(13)).foregroundStyle(Theme.accentText)
                                .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                        }
                        CapsLabel("On this iPhone").padding(.top, Theme.section)
                        Text(storageLine).font(Theme.grotesk(14)).foregroundStyle(Theme.textDim).padding(.top, 10)

                        CapsLabel("About Habla").padding(.top, Theme.section)
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Imprint.about(models: store.narrationModels), id: \.self) { line in
                                Text(line).font(Theme.grotesk(13)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                            }
                        }.padding(.top, 10).accessibilityElement(children: .combine)
                    }
                    .padding(.horizontal, Theme.margin).padding(.top, 20).padding(.bottom, 40)
                }
            }
        }
        .onAppear { storageLine = computeStorage() }
        .confirmationDialog("Unpair “\(store.paired?.name ?? "")”?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { store.unpair() }
        } message: { Text("Downloaded books stay on this iPhone. To sync again, pair from the Mac.") }
    }

    func pairedSection(_ mac: PhoneStore.PairedMac) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(mac.name).font(Theme.display(28)).foregroundStyle(Theme.text).padding(.top, 22)
            HStack(spacing: 8) {
                Circle().fill(store.isConnected ? Theme.accent : Theme.textDim.opacity(0.5)).frame(width: 7, height: 7)
                Text(store.connectionSummary).font(Theme.grotesk(14)).foregroundStyle(Theme.textDim)
            }.padding(.top, 10)
            if !mac.fingerprint.isEmpty {
                Label("Paired · encrypted", systemImage: "lock.fill").font(Theme.grotesk(13)).foregroundStyle(Theme.textDim).padding(.top, 6)
            }
            PillButton(store.syncing ? "Syncing…" : "Sync now") { Task { await store.sync() } }
                .disabled(store.syncing).padding(.top, Theme.section)
            TextLinkButton("Unpair this Mac") { confirmUnpair = true }.padding(.top, 8)
            CapsLabel("How it works").padding(.top, Theme.section + 8)
            Text("Keep Habla running on your Mac and both on the same Wi-Fi. New books, narrated chapters and your place sync by themselves while Habla is open. Other computers on the network can’t see your books.")
                .font(Theme.grotesk(15)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
        }
    }

    var pairingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pair with your Mac").font(Theme.display(28)).foregroundStyle(Theme.text).padding(.top, 22)
            Text("In Habla on your Mac, choose Pair iPhone. Scan the code it shows with the Camera, or pick your Mac below and type the code.")
                .font(Theme.grotesk(15)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true).padding(.top, 10)

            CapsLabel("Macs on this Wi-Fi").padding(.top, Theme.section)
            if store.nearby.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking…").font(Theme.grotesk(14)).foregroundStyle(Theme.textDim)
                }.padding(.top, 12)
            }
            VStack(spacing: 0) {
                ForEach(store.nearby, id: \.self) { svc in
                    Button { withAnimation { chosen = svc; code = ""; codeFocused = true } } label: {
                        RuledRow(svc.name.replacingOccurrences(of: "Habla on ", with: ""), highlighted: chosen == svc, accent: Theme.accentText) {
                            Image(systemName: chosen == svc ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
                                .font(.system(size: 18))
                                .foregroundStyle(chosen == svc ? Theme.accentText : Theme.textDim.opacity(0.5))
                        }
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityAddTraits(chosen == svc ? .isSelected : [])
                }
            }.padding(.top, 4)

            if let svc = chosen {
                CapsLabel("Code shown on \(svc.name.replacingOccurrences(of: "Habla on ", with: ""))").padding(.top, Theme.section)
                HStack(spacing: 10) {
                    TextField("XXXXX-XXXXX", text: $code)
                        .focused($codeFocused)
                        .textFieldStyle(.plain).font(.system(size: 20, weight: .medium, design: .monospaced))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .padding(.horizontal, 16).frame(height: 52)
                        .background(Capsule().fill(Theme.surface))
                        .onSubmit { pair(svc) }
                    Button { pair(svc) } label: {
                        Group { if store.pairingBusy { ProgressView() } else { Text("Pair") } }
                            .font(Theme.label(15)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 22).frame(height: 52).background(Capsule().fill(Theme.accent))
                    }
                    .buttonStyle(.plain).disabled(Pairing.normalize(code).count < 10 || store.pairingBusy)
                }.padding(.top, 12)
            }

            CapsLabel("Can't see your Mac?").padding(.top, Theme.section)
            Text("Type the address shown in Habla on your Mac (for example 192.168.1.20:8787).")
                .font(Theme.grotesk(14)).foregroundStyle(Theme.textDim).padding(.top, 10)
            HStack(spacing: 10) {
                TextField("192.168.1.20:8787", text: $address)
                    .textFieldStyle(.plain).font(Theme.grotesk(16))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL).textInputAutocapitalization(.never)
                    #endif
                    .padding(.horizontal, 16).frame(height: 48)
                    .background(Capsule().fill(Theme.surface))
                CapsuleButton("Find", height: 48) {
                    Task { if let svc = await store.lookUp(address: address) { withAnimation { chosen = svc; codeFocused = true } } }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(.top, 12)
        }
    }

    func pair(_ svc: ServiceBrowser.Service) {
        Task { await store.pair(at: svc.url, code: code) }
    }

    func computeStorage() -> String {
        let local = store.books.filter { $0.availability == .local }
        let bytes = (FileManager.default.enumerator(at: store.library, includingPropertiesForKeys: [.fileSizeKey])?
            .compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0, +)) ?? 0
        return "\(local.count) book\(local.count == 1 ? "" : "s") · \(Format.bytes(bytes))"
    }
}
