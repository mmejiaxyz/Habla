#if os(macOS)
import SwiftUI
import HablaCore

// The Mac window in the 2026-11 redesign: a sidebar (library filters, devices, voice engine),
// a cover grid under a "narrating now" card, and a book page with the cover on the accent field.
// Logic (narration, voices, devices, pairing) is the existing StudioWindowView code.

extension StudioWindowView {

    // MARK: Layout

    var redesignedBody: some View {
        HStack(spacing: 0) {
            homeSidebar.frame(width: 240)
            Rectangle().fill(Theme.hairline).frame(width: 0.5)
            VStack(spacing: 0) {
                if store.voiceEngine != .ready && (!store.books.isEmpty || store.helperOnly) { voiceEngineBanner }
                updateBanner
                Group {
                    if store.helperOnly { helperHome }
                    else if store.books.isEmpty && store.importing.isEmpty { emptyHome }
                    else if showingBook, let m = store.selected { bookPage(m) }
                    else { home }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if dropping {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Theme.accentText, style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                            .padding(16).allowsHitTesting(false)
                    }
                }
            }
        }
        .background(Theme.screen)
    }

    func cover(_ m: BookManifest) -> BookCover {
        let url = BookBundle.url(for: m.id, in: store.library)
        return BookCover(title: m.title, author: m.author, accentHex: m.accentColor,
                         image: CoverCache.image(bundle: url, revision: m.revision))
    }

    func open(_ m: BookManifest) { store.selection = m.id; showingBook = true }

    /// Help narrate only: what this Mac is doing for the other devices, without any book.
    var helperHome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Helping narrate").font(Theme.display(40)).foregroundStyle(Theme.text)
            Text("This Mac narrates books for your other devices. It doesn't show them, doesn't sync your places or marks, and deletes each book once your devices have it.")
                .font(Theme.grotesk(14)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            Group {
                if let r = store.render {
                    let pct = r.bookSentencesTotal > 0 ? Int(100 * Double(r.bookSentencesDone) / Double(r.bookSentencesTotal)) : 0
                    Text("Narrating a book · \(pct)%" + (r.secondsLeft.map { " · about \(Int(($0 / 60).rounded(.up))) min left" } ?? ""))
                } else if store.helperJobs > 0 {
                    Text("Waiting for your devices to collect \(store.helperJobs) book\(store.helperJobs == 1 ? "" : "s")")
                } else {
                    Text(store.bridgeReady ? "Idle: ready for the next book" : "Not linked yet: use “Join another Mac’s library…”")
                }
            }
            .font(Theme.grotesk(15)).foregroundStyle(Theme.text)
            if store.queue.count > 1 { Text("\(store.queue.count - 1) more waiting").font(Theme.grotesk(13)).foregroundStyle(Theme.textDim) }
            Button("Stop helping") { store.helperOnly = false }.padding(.top, 8)
        }
        .padding(48).frame(maxWidth: 620, maxHeight: .infinity, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Sidebar

    var homeSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Habla").font(Theme.display(30)).foregroundStyle(Theme.text)
                .padding(.horizontal, 10).padding(.top, 30).padding(.bottom, 16)
            if !store.helperOnly {
                navItem("Library", "books.vertical", count: store.books.count, on: !narratingOnly) { narratingOnly = false; showingBook = false }
                navItem("Narrating", "headphones", count: narratingIDs.count, on: narratingOnly) { narratingOnly = true; showingBook = false }
            }

            CapsLabel("Devices").padding(.horizontal, 10).padding(.top, 26).padding(.bottom, 2)
            devices.padding(.horizontal, -14)

            Spacer(minLength: 12)
            engineCard
        }
        .padding(.horizontal, 14).padding(.bottom, 16)
        .background(Theme.surface)
    }

    func navItem(_ title: String, _ symbol: String, count: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 18)
                Text(title).font(Theme.grotesk(14))
                Spacer()
                Text("\(count)").font(Theme.grotesk(12)).foregroundStyle(Theme.text.opacity(0.5))
            }
            .foregroundStyle(Theme.ink.opacity(on ? 1 : 0.8))
            .padding(.horizontal, 10).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Theme.accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    var engineCard: some View {
        let (line, detail): (String, String) = {
            switch store.voiceEngine {
            case .ready: return ("Kokoro · ready", narratingIDs.isEmpty ? "Idle" : "Narrating \(narratingIDs.count) book\(narratingIDs.count == 1 ? "" : "s")")
            case .checking: return ("Checking…", "")
            case .missing: return ("Not installed", "Books stay readable without it")
            case .installing(let step): return ("Installing…", step)
            case .failed: return ("Couldn’t install", "See the banner to try again")
            }
        }()
        return VStack(alignment: .leading, spacing: 3) {
            Text("Voice engine").font(Theme.label(9)).tracking(1.1).textCase(.uppercase).foregroundStyle(Theme.textDim)
            Text(line).font(Theme.grotesk(14)).foregroundStyle(Theme.text)
            if !detail.isEmpty { Text(detail).font(Theme.grotesk(12)).foregroundStyle(Theme.textDim).lineLimit(2) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.screen))
    }

    var narratingIDs: [String] {
        var ids = store.queue
        if let r = store.render, !ids.contains(r.bookID) { ids.insert(r.bookID, at: 0) }
        return ids
    }

    // MARK: Home

    var shelf: [BookManifest] {
        narratingOnly ? store.books.filter { narratingIDs.contains($0.id) } : store.books
    }

    var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(narratingOnly ? "Narrating" : "Library").font(Theme.display(46)).foregroundStyle(Theme.text)
                    Spacer()
                    RoundIconButton("plus", label: "Add books") { showImporter = true }
                        .help("Add EPUB books")
                }
                .padding(.bottom, 22)

                if let hero = heroBook { narratingCard(hero).padding(.bottom, 40) }
                if !narratingOnly, !store.renarratable.isEmpty { renarrateBanner.padding(.bottom, 28) }

                SectionRule(narratingOnly ? "In the queue" : "All books", count: shelf.count)
                    .padding(.bottom, 18)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 32)], alignment: .leading, spacing: 30) {
                    ForEach(shelf, id: \.id) { m in tile(m) }
                    ForEach(store.importing, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 10) {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.surface).aspectRatio(2.0 / 3.0, contentMode: .fit)
                                .overlay(ProgressView().controlSize(.small))
                            Text("Adding \(name)…").font(Theme.grotesk(12)).foregroundStyle(Theme.textDim).lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 40)
        }
    }

    /// Books narrated with Paradee before Kokoro came back: one click redoes them all.
    var renarrateBanner: some View {
        let n = store.renarratable.count
        return HStack(spacing: 14) {
            Text("\(n) book\(n == 1 ? " was" : "s were") narrated with Paradee. Their audio stays until you re-narrate.")
                .font(Theme.grotesk(13)).foregroundStyle(Theme.textDim)
            Spacer()
            Button("Re-narrate all with Kokoro") { store.renarrateAll() }.disabled(store.voiceEngine != .ready)
        }
    }

    /// The book being narrated (or paused in the queue).
    var heroBook: BookManifest? {
        if let r = store.render { return store.books.first { $0.id == r.bookID } }
        if let id = store.queue.first { return store.books.first { $0.id == id } }
        return nil
    }

    func narratingCard(_ m: BookManifest) -> some View {
        let item = store.item(m)
        let r = store.render?.bookID == m.id ? store.render : nil
        let label = r.map { "Narrating now · \($0.chapterTitle)" } ?? (store.paused ? "Narration paused" : "Up next")
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(Theme.label(10)).tracking(1.2).textCase(.uppercase).foregroundStyle(Theme.ink.opacity(0.75)).lineLimit(1)
                Text(m.title).font(Theme.display(46)).foregroundStyle(Theme.ink).lineLimit(2).minimumScaleFactor(0.6)
                    .padding(.top, 10)
                Text(m.author).font(Theme.displayItalic(17)).foregroundStyle(Theme.ink.opacity(0.7)).padding(.top, 4)
                Spacer(minLength: 20)
                HStack(alignment: .bottom, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        ProgressLine(narratedFraction(m, r))
                        Text("\(item.narrated) of \(item.narratable) chapters  ·  " + narrationDetail(m, item, r))
                            .font(Theme.grotesk(12)).foregroundStyle(Theme.ink.opacity(0.8)).lineLimit(1)
                    }
                    .frame(maxWidth: 520)
                    narrationButton(m, item)
                }
                .padding(.trailing, 170)
            }
            .padding(30)
            .frame(maxWidth: .infinity, minHeight: 236, alignment: .topLeading)

            FramedCover(cover(m), width: 120, mat: 6, tilt: -3).padding(.top, 22).padding(.trailing, 34)
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.accent))
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .onTapGesture { open(m) }
    }

    func tile(_ m: BookManifest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { open(m) } label: {
                cover(m).shadow(color: .black.opacity(0.18), radius: 12, y: 8)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.accentText, lineWidth: m.id == store.selection && showingBook ? 3 : 0))
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("\(m.title), \(m.author)")
            HStack(spacing: 8) {
                status(m)
                Spacer(minLength: 0)
                Menu { bookMenu(m) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        .frame(width: 28, height: 22).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More for \(m.title)")
            }
        }
        .contextMenu { bookMenu(m) }
    }

    @ViewBuilder func bookMenu(_ m: BookManifest) -> some View {
        Button("Read") { openReader(m.id) }
        Button("Book details") { open(m) }
        if m.canNarrate && !store.item(m).isFullyNarrated && !store.queue.contains(m.id) && store.render?.bookID != m.id {
            Button("Narrate") { store.narrate(m.id) }.disabled(store.voiceEngine != .ready)
        }
        if store.canRenarrate(m) {
            Button("Re-narrate with Kokoro") { store.renarrate(m.id) }.disabled(store.voiceEngine != .ready)
        }
        Button("Show original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([BookImporter.originalURL(for: m.id, in: store.library)]) }
        Divider()
        Button("Delete…", role: .destructive) { confirmDelete = m }
    }

    // MARK: Empty

    var emptyHome: some View {
        ZStack {
            Theme.accent
            VStack(spacing: 20) {
                Text("Habla").font(Theme.displayItalic(18)).foregroundStyle(Theme.ink.opacity(0.7))
                Text(dropping ? "Release to add." : "Drop EPUBs\nhere.").font(Theme.display(72)).textCase(.uppercase)
                    .foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                Text("Drop DRM-free EPUB files on this window. Habla narrates them with a natural voice and shares them with your iPhone over Wi-Fi.")
                    .font(Theme.grotesk(15)).foregroundStyle(Theme.ink.opacity(0.75)).multilineTextAlignment(.center).frame(maxWidth: 460)
                ActionPill("Choose EPUB files…", symbol: "plus") { showImporter = true }.frame(width: 240)
                if store.voiceEngine != .ready { installCard.padding(.top, 30) }
            }
            .padding(60)
        }
    }

    var installCard: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                switch store.voiceEngine {
                case .installing(let step):
                    Text("Installing the voice engine…").font(.ui(15, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(step).font(Theme.grotesk(12)).foregroundStyle(Theme.ink.opacity(0.6)).lineLimit(1)
                case .failed(let msg):
                    Text("The voice engine couldn't be installed").font(.ui(15, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(msg).font(Theme.grotesk(12)).foregroundStyle(Theme.ink.opacity(0.6)).lineLimit(2)
                default:
                    Text("Install the voice engine").font(.ui(15, weight: .medium)).foregroundStyle(Theme.ink)
                    Text("Kokoro runs on this Mac, free and offline. One download of about 340 MB.")
                        .font(Theme.grotesk(12)).foregroundStyle(Theme.ink.opacity(0.6))
                }
            }
            Spacer(minLength: 0)
            if case .installing = store.voiceEngine { ProgressView().controlSize(.small) }
            else if let script = installScript, store.voiceEngine != .checking {
                ActionPill(store.voiceEngine == .missing ? "Install" : "Try again", style: .accent, height: 44) { store.installVoiceEngine(script: script) }
                    .frame(width: 120)
            }
        }
        .padding(.leading, 22).padding(.trailing, 14).padding(.vertical, 16)
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.paper))
    }

    // MARK: Book page

    func bookPage(_ m: BookManifest) -> some View {
        let item = store.item(m)
        let rendering = store.render?.bookID == m.id ? store.render : nil
        return HStack(spacing: 0) {
            ZStack {
                Theme.accent
                FramedCover(cover(m), width: 208, mat: 8)
            }
            .frame(width: 360)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Button { showingBook = false } label: {
                        HStack(spacing: 4) { Image(systemName: "chevron.left"); Text(narratingOnly ? "Narrating" : "Library") }
                            .font(Theme.grotesk(12)).foregroundStyle(Theme.text.opacity(0.6)).frame(minHeight: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).keyboardShortcut("[", modifiers: .command)
                    .padding(.bottom, 24)

                    Text(m.author).font(Theme.label(10)).tracking(1.2).textCase(.uppercase).foregroundStyle(Theme.text.opacity(0.6))
                    Text(m.title.uppercased()).font(Theme.display(46)).foregroundStyle(Theme.text).lineSpacing(-6)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                    Text(meta(m)).font(Theme.grotesk(12)).foregroundStyle(Theme.text.opacity(0.6)).padding(.top, 12)

                    HStack(spacing: 10) {
                        ActionPill("Read", symbol: "book", height: 44) { openReader(m.id) }.frame(width: 130)
                        narrationButton(m, item)
                        Menu { bookMenu(m) } label: { RoundIcon("ellipsis") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    .padding(.top, 24)

                    HStack(alignment: .top, spacing: 40) {
                        VStack(alignment: .leading, spacing: 0) {
                            CapsLabel("Narration")
                            Text(item.isTextOnly ? "Ready to read" : item.isFullyNarrated ? "Ready to listen" : "\(item.narrated) of \(item.narratable) chapters")
                                .font(Theme.display(24)).foregroundStyle(Theme.text).padding(.top, 4)
                            Text(narrationDetail(m, item, rendering)).font(Theme.grotesk(12)).foregroundStyle(Theme.textDim).padding(.top, 2)
                            ProgressLine(narratedFraction(m, rendering), color: Theme.accentText, track: Theme.text.opacity(0.1))
                                .padding(.top, 16).padding(.bottom, 8)
                            ForEach(m.chapters.filter { !$0.isFrontMatter }, id: \.index) { c in
                                chapterRow(c, rendering, queued: store.queue.contains(m.id))
                            }
                        }
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 0) {
                            CapsLabel("Voice").padding(.bottom, 4)
                            if m.canNarrate {
                                ForEach(store.voices(for: m), id: \.self) { v in voiceRow(v, book: m) }
                                Text("Changing the voice re-narrates the chapters that aren’t done yet.")
                                    .font(Theme.grotesk(12)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                            } else {
                                Text("There’s no \(BookLanguage.name(m.language)) voice yet. This book is ready to read here and on your iPhone.")
                                    .font(Theme.grotesk(13)).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                            }
                        }
                        .frame(width: 260)
                    }
                    .padding(.top, 38)
                }
                .padding(.horizontal, 48).padding(.top, 30).padding(.bottom, 40)
            }
        }
    }
}
#endif
