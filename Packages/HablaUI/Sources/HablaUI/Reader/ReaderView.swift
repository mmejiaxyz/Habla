import SwiftUI
import HablaCore

/// Draws one TextKit page.
struct PageCanvas: View {
    let layout: PageLayout
    let page: Int
    let highlight: Int?
    let highlightColor: Color
    var selection: NSRange? = nil
    var underlines: [NSRange] = []
    var underlineColor: Color = Theme.accentText

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, _ in
            ctx.withCGContext { cg in
                layout.draw(page: page, in: cg, origin: .zero,
                            highlight: highlight.map { ($0, PlatformColor(highlightColor).cgColor) },
                            selection: selection.map { ($0, PlatformColor(highlightColor).cgColor) },
                            underlines: underlines, underlineColor: PlatformColor(underlineColor).cgColor)
            }
        }
        .frame(width: layout.pageSize.width, height: layout.pageSize.height)
        .accessibilityElement()
        .accessibilityLabel(Text((layout.chapter.text.string as NSString).substring(with: layout.characterRange(ofPage: page))))
    }
}

/// The reading screen (Apple Books style). iPhone: one page, tap/swipe to turn, tap the
/// middle for controls. Mac: a two-page spread with a toolbar and arrow keys.
public struct ReaderView: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var player: NarrationPlayer
    var onClose: () -> Void
    var onStyle: (ReaderStyle) -> Void
    var onOpenPlayer: () -> Void

    @State private var chrome: Bool
    @State private var showThemes = false
    @State private var showContents = false
    @State private var showFind = false
    @State private var findQuery = ""
    @State private var findHits: [FindHit] = []
    @State private var findIndex: Int?
    @State private var findSearching = false
    @State private var findTask: Task<Void, Never>?
    @State private var forward = true
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var lastTurn = Date.distantPast
    @State private var selection: WordSelection?
    @State private var touch: TouchState?
    @State private var holdTask: Task<Void, Never>?
    @State private var pendingTap: Task<Void, Never>?
    #if os(macOS)
    @State private var lastClick: (time: Date, at: CGPoint)?
    #endif

    struct TouchState { var start: CGPoint; var began: Date; var moved = false; var held = false }
    @State private var sentenceScope = false
    @State private var dictionaryTerm: String?
    @State private var translateText: String?
    @State private var definition: String?

    struct WordSelection: Equatable {
        var page: Int
        var word: NSRange
        var sentence: NSRange?
    }

    public init(model: ReaderModel, player: NarrationPlayer, chrome: Bool = false,
                onClose: @escaping () -> Void, onStyle: @escaping (ReaderStyle) -> Void = { _ in },
                onOpenPlayer: @escaping () -> Void = {}, previewWordAt: CGPoint? = nil, previewFind: String? = nil) {
        self.model = model; self.player = player
        self.onClose = onClose; self.onStyle = onStyle; self.onOpenPlayer = onOpenPlayer
        _chrome = State(initialValue: chrome)
        // Snapshots: show a search result as if picked from the list.
        if let q = previewFind {
            let hits = BookFind.search(q, in: model.bundle, manifest: model.manifest)
            if hits.count > 2 {
                model.show(hits[2], query: q)
                _findQuery = State(initialValue: q); _findHits = State(initialValue: hits); _findIndex = State(initialValue: 2)
            }
        }
        // Snapshots: open the word card on the word at this point of the page.
        if let pt = previewWordAt, let w = model.layout?.wordRange(at: pt, onPage: model.page) {
            _selection = State(initialValue: WordSelection(page: model.page, word: w, sentence: model.sentenceRange(around: w.location)))
        }
    }

    var theme: ReaderTheme { model.style.theme }
    var isSpread: Bool { model.columns > 1 }
    var narratingHere: Bool { player.bookID == model.manifest.id }
    var bookHasAudio: Bool { model.manifest.chapters.contains { $0.audioStatus == .ready } }

    public var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()
            GeometryReader { geo in
                pages(in: geo.size)
            }
            .padding(insets)
            if chrome || isSpread { controls }
            if !chrome && !isSpread && narratingHere && player.isPlaying { quietPauseButton }
            if let toast { toastView(toast) }
            if let sel = selection { wordCard(sel) }
            else if findIndex != nil, !findHits.isEmpty { findBar }
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .modifier(TranslateSheet(text: $translateText))
        #if canImport(UIKit)
        .sheet(isPresented: Binding(get: { dictionaryTerm != nil }, set: { if !$0 { dictionaryTerm = nil } })) {
            DictionaryPage(term: dictionaryTerm ?? "").ignoresSafeArea()
        }
        #endif
        .onChange(of: model.chapter) { _, _ in selection = nil }
        .onChange(of: model.page) { _, _ in selection = nil }
        .sheet(isPresented: $showThemes) { themesSheet }
        .sheet(isPresented: $showContents) { contentsSheet }
        .sheet(isPresented: $showFind) { findSheet }
        .onChange(of: player.sentence) { _, _ in syncWithNarration() }
        .onChange(of: player.chapter) { _, _ in syncWithNarration() }
        .onAppear { syncWithNarration() }
        #if os(macOS)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { turn(true); return .handled }
        .onKeyPress(.leftArrow) { turn(false); return .handled }
        .onKeyPress(.space) { turn(true); return .handled }
        .onKeyPress(keys: ["f"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            showFind = true; return .handled
        }
        #endif
    }

    var insets: EdgeInsets {
        isSpread ? EdgeInsets(top: 64, leading: 56, bottom: 44, trailing: 56)
                 : EdgeInsets(top: 34, leading: 26, bottom: 40, trailing: 26)
    }

    // MARK: Pages

    @ViewBuilder func pages(in size: CGSize) -> some View {
        let gap: CGFloat = isSpread ? 96 : 0
        let pageSize = CGSize(width: (size.width - gap * CGFloat(model.columns - 1)) / CGFloat(model.columns), height: size.height - 22)
        ZStack(alignment: .top) {
            Color.clear.onAppear { model.setPageSize(pageSize) }
                .onChange(of: pageSize) { _, s in model.setPageSize(s) }
            if let layout = model.layout {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(0..<model.columns, id: \.self) { c in
                        let p = model.page + c
                        if p < layout.pageCount {
                            PageCanvas(layout: layout, page: p,
                                       highlight: model.highlightedSentence(onChapter: model.chapter),
                                       highlightColor: theme.highlight,
                                       selection: selection?.page == p ? selectedRange
                                           : (model.found?.chapter == model.chapter ? model.found?.range : nil),
                                       underlines: model.underlineRanges(),
                                       underlineColor: theme.isDark ? Theme.accent : Theme.accentText)
                        } else {
                            Color.clear.frame(width: layout.pageSize.width, height: layout.pageSize.height)
                        }
                    }
                }
                .id("\(model.chapter)-\(model.page)-\(model.style.fontSize)-\(model.style.theme.rawValue)")
                .overlay { Color.clear.id(underlineVersion) }
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                footer(width: size.width).offset(y: size.height - 16)
                    .opacity(findIndex != nil && !findHits.isEmpty ? 0 : 1)
            } else if let err = model.loadError {
                Text(err).font(.system(size: 15)).foregroundStyle(theme.secondary).padding(.top, 120)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        // One handler decides what a touch was: tap, press-and-hold, or swipe (they used to
        // fire together: holding a word also turned the page).
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in touchChanged(v, in: size) }
            .onEnded { v in touchEnded(v, in: size) })
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Next page") { turn(true) }
        .accessibilityAction(named: "Previous page") { turn(false) }
        .accessibilityAction(named: chrome ? "Hide controls" : "Show controls") { chrome.toggle() }
        .accessibilityAction(.escape) { onClose() }
        .accessibilityScrollAction { edge in turn(edge == .trailing || edge == .bottom) }
    }

    // MARK: Touch

    static let holdDelay: TimeInterval = 0.4
    static let slop: CGFloat = 10           // movement still counted as "not moving"

    func touchChanged(_ v: DragGesture.Value, in size: CGSize) {
        if touch == nil {
            touch = TouchState(start: v.startLocation, began: Date())
            let start = v.startLocation
            holdTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.holdDelay * 1_000_000_000))
                guard !Task.isCancelled, var t = touch, !t.moved else { return }
                t.held = true
                touch = t
                pendingTap?.cancel()
                select(at: start, in: size)
            }
        }
        if var t = touch, !t.moved, hypot(v.translation.width, v.translation.height) > Self.slop {
            t.moved = true
            touch = t
            holdTask?.cancel()
        }
    }

    func touchEnded(_ v: DragGesture.Value, in size: CGSize) {
        holdTask?.cancel()
        let t = touch
        touch = nil
        guard let t, !t.held else { return }           // the hold already opened the word card
        if t.moved {
            guard selection == nil else { return }
            if v.translation.width < -40 { turn(true) } else if v.translation.width > 40 { turn(false) }
            return
        }
        #if os(macOS)
        // A double-click on a word opens the card; wait a moment before treating a click as a tap.
        if let last = lastClick, Date().timeIntervalSince(last.time) < NSEvent.doubleClickInterval,
           hypot(last.at.x - v.location.x, last.at.y - v.location.y) < 8 {
            pendingTap?.cancel(); lastClick = nil
            select(at: v.location, in: size)
            return
        }
        lastClick = (Date(), v.location)
        let at = v.location
        pendingTap?.cancel()
        pendingTap = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(NSEvent.doubleClickInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            tap(at: at, in: size)
        }
        #else
        tap(at: v.location, in: size)
        #endif
    }

    func tap(at point: CGPoint, in size: CGSize) {
        if selection != nil { withAnimation(.easeOut(duration: 0.15)) { selection = nil }; return }
        if model.found != nil && findIndex == nil { model.found = nil }
        let x = point.x / max(1, size.width)
        if isSpread { turn(x > 0.5); return }
        if x > 0.72 { turn(true) } else if x < 0.28 { turn(false) }
        else { withAnimation(.easeOut(duration: 0.18)) { chrome.toggle() } }
    }

    func footer(width: CGFloat) -> some View {
        HStack {
            if isSpread {
                Text("\(model.chapterTitle)").lineLimit(1)
                Spacer()
                Text("\(Int((model.bookFraction * 100).rounded()))%")
            } else {
                Spacer()
                Text(chrome ? "Page \(model.page + 1) of \(model.pageCount) · \(Int((model.bookFraction * 100).rounded()))%"
                            : "\(Int((model.bookFraction * 100).rounded()))%")
                Spacer()
            }
        }
        .font(.system(size: 11)).monospacedDigit()
        .foregroundStyle(theme.secondary)
        .frame(width: width)
    }

    func turn(_ next: Bool) {
        // Ignore taps that land while the previous page is still sliding.
        guard Date().timeIntervalSince(lastTurn) > 0.12 else { return }
        lastTurn = Date()
        forward = next
        guard next ? model.canGoForward : model.canGoBack else { return }
        withAnimation(.easeOut(duration: 0.22)) { next ? model.next() : model.previous() }
    }

    // MARK: Words: underline, dictionary, translate

    var selectedRange: NSRange? {
        guard let sel = selection else { return nil }
        return sentenceScope ? (sel.sentence ?? sel.word) : sel.word
    }
    var selectedText: String {
        guard let r = selectedRange, let l = model.layout else { return "" }
        return (l.chapter.text.string as NSString).substring(with: r)
    }
    /// Changes when underlines change, so the page redraws.
    var underlineVersion: Int { model.underlineRanges().count }

    func select(at point: CGPoint, in size: CGSize) {
        guard let layout = model.layout else { return }
        let gap: CGFloat = isSpread ? 96 : 0
        let pageWidth = layout.pageSize.width
        let column = isSpread ? min(model.columns - 1, max(0, Int(point.x / (pageWidth + gap)))) : 0
        let local = CGPoint(x: point.x - CGFloat(column) * (pageWidth + gap), y: point.y)
        let page = model.page + column
        guard page < layout.pageCount, let word = layout.wordRange(at: local, onPage: page) else { return }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        sentenceScope = false
        definition = nil
        withAnimation(.easeOut(duration: 0.15)) {
            selection = WordSelection(page: page, word: word, sentence: model.sentenceRange(around: word.location))
        }
        #if os(macOS)
        definition = Lookup.definition(selectedText)
        #endif
    }

    func wordCard(_ sel: WordSelection) -> some View {
        let existing = selectedRange.flatMap { model.underline(covering: $0) }
        return VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(selectedText)
                        .font(.system(size: sentenceScope ? 17 : 26, design: .serif))
                        .foregroundStyle(theme.text)
                        .lineLimit(sentenceScope ? 4 : 1).minimumScaleFactor(0.6)
                    Spacer(minLength: 8)
                    if sel.sentence != nil {
                        HStack(spacing: 2) {
                            scopeButton("Word", sentence: false)
                            scopeButton("Sentence", sentence: true)
                        }
                        .padding(3)
                        .background(Capsule().fill(theme.control))
                        .onChange(of: sentenceScope) { _, _ in
                            #if os(macOS)
                            definition = sentenceScope ? nil : Lookup.definition(selectedText)
                            #endif
                        }
                    }
                }
                #if os(macOS)
                if !sentenceScope, let d = definition {
                    ScrollView { Text(d).font(.system(size: 13)).foregroundStyle(theme.text.opacity(0.8)).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 140)
                }
                #endif
                HStack(spacing: 10) {
                    cardButton(existing == nil ? "Underline" : "Remove", symbol: existing == nil ? "underline" : "eraser") {
                        if let existing { model.removeUnderline(existing) } else if let r = selectedRange { model.addUnderline(r) }
                        withAnimation(.easeOut(duration: 0.15)) { selection = nil }
                    }
                    #if canImport(UIKit)
                    if !sentenceScope {
                        cardButton("Dictionary", symbol: "character.book.closed") { dictionaryTerm = selectedText }
                    }
                    #endif
                    if TranslateSheet.isAvailable {
                        cardButton("Translate", symbol: "translate") { translateText = selectedText }
                    }
                    cardButton("Copy", symbol: "doc.on.doc") {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = selectedText
                        #else
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selectedText, forType: .string)
                        #endif
                        withAnimation { selection = nil }
                        show("Copied")
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 520)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(theme.background))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(theme.text.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(theme.isDark ? 0.5 : 0.14), radius: 24, y: 6)
            .padding(.horizontal, 14).padding(.bottom, 18)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    func scopeButton(_ title: String, sentence: Bool) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { sentenceScope = sentence } } label: {
            Text(title).font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.text.opacity(sentenceScope == sentence ? 1 : 0.55))
                .padding(.horizontal, 12).frame(height: 30)
                .background(Capsule().fill(sentenceScope == sentence ? theme.background : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(sentenceScope == sentence ? .isSelected : [])
    }

    func cardButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(theme.text)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: Narration

    func syncWithNarration() {
        guard narratingHere, player.isLoaded else { model.clearHighlight(); return }
        model.follow(chapter: player.chapter, sentence: player.sentence)
    }

    /// Listen from this page (or pause if it's already narrating here).
    func listen() {
        if narratingHere && player.isPlaying { player.pause(); return }
        let sentence = model.currentSentence ?? 0
        if narratingHere, player.chapter == model.chapter,
           let h = model.highlightedSentence(onChapter: model.chapter),
           let p = model.layout?.page(forSentence: h), p / model.columns == model.page / model.columns {
            player.play()   // still on the page being read: just resume
        } else {
            player.load(bundle: model.bundle, manifest: model.manifest, chapter: model.chapter, sentence: sentence, autoplay: true)
        }
        if let m = player.message { show(m); player.clearMessage() }
    }

    func show(_ text: String) {
        toastTask?.cancel()
        withAnimation { toast = text }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run { withAnimation { toast = nil } }
        }
    }

    // MARK: Controls

    var controls: some View {
        VStack {
            HStack(spacing: 12) {
                roundButton(isSpread ? "‹" : "×", label: "Close", action: onClose)
                Spacer()
                Text(isSpread ? model.manifest.title : model.chapterTitle)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(theme.text.opacity(0.75))
                Spacer()
                if narratingHere && !isSpread {
                    roundButton("♪", label: "Open the player (speed, sleep timer)") { onOpenPlayer() }
                }
                symbolButton("magnifyingglass", label: "Find in book") { showFind = true }
                roundButton("☰", label: "Contents") { showContents = true }
                if isSpread {
                    roundButton("Aa", label: "Themes and size", serif: true) { showThemes = true }
                    if bookHasAudio { listenButton }
                }
            }
            .padding(.horizontal, 16).padding(.top, isSpread ? 12 : 6).padding(.bottom, 8)
            .background(theme.background.opacity(isSpread ? 0 : 1).ignoresSafeArea(edges: .top))
            Spacer()
            if !isSpread {
                HStack(spacing: 10) {
                    if bookHasAudio { listenButton }
                    Spacer(minLength: 0)
                    Text("Page \(model.page + 1) of \(model.pageCount) · \(Int((model.bookFraction * 100).rounded()))%")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(theme.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    roundButton("Aa", label: "Themes and size", serif: true) { showThemes = true }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
                .background(theme.background.ignoresSafeArea(edges: .bottom))
            }
        }
        .transition(.opacity)
    }

    var listenButton: some View {
        Button(action: listen) {
            HStack(spacing: 8) {
                Image(systemName: narratingHere && player.isPlaying ? "pause.fill" : "headphones")
                    .font(.system(size: 14, weight: .semibold))
                Text(narratingHere && player.isPlaying ? "Pause" : "Listen").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 16).frame(height: 44)
            .background(Capsule().fill(Theme.accent))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(narratingHere && player.isPlaying ? "Pause narration" : "Listen from this page")
    }

    var quietPauseButton: some View {
        VStack {
            Spacer()
            HStack {
                Button { player.pause() } label: {
                    Image(systemName: "pause.fill").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.text.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(theme.control))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pause narration")
                Spacer()
            }
            .padding(.leading, 16).padding(.bottom, 2)
        }
    }

    func roundButton(_ s: String, label: String, serif: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(serif ? .system(size: 16, design: .serif) : .system(size: 17, weight: .medium))
                .foregroundStyle(theme.text)
                .frame(width: 44, height: 44)
                .background(Circle().fill(theme.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    func toastView(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(.system(size: 14, weight: .medium)).multilineTextAlignment(.center)
                .foregroundStyle(theme.isDark ? Color.black : Color.white)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(Capsule().fill(theme.isDark ? Color.white : Color.black).opacity(0.85))
                .padding(.bottom, 90).padding(.horizontal, 24)
        }
        .transition(.opacity)
    }

    func symbolButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.text)
                .frame(width: 44, height: 44)
                .background(Circle().fill(theme.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Find

    func runFind(_ q: String) {
        findTask?.cancel()
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { findHits = []; findSearching = false; return }
        findSearching = true
        let bundle = model.bundle, manifest = model.manifest
        findTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)          // wait for typing to pause
            guard !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) { BookFind.search(query, in: bundle, manifest: manifest) }.value
            guard !Task.isCancelled else { return }
            findHits = hits
            findSearching = false
        }
    }

    func openHit(_ i: Int) {
        guard findHits.indices.contains(i) else { return }
        findIndex = i
        let hit = findHits[i]
        forward = hit.chapter > model.chapter || (hit.chapter == model.chapter)
        withAnimation(.easeOut(duration: 0.2)) { model.show(hit, query: findQuery) }
    }

    func endFind() {
        findIndex = nil
        model.found = nil
    }

    var findSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in book", text: $findQuery)
                        .textFieldStyle(.plain).font(.system(size: 17))
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit { if !findHits.isEmpty { showFind = false; openHit(0) } }
                    if !findQuery.isEmpty {
                        Button { findQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, 14).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.gray.opacity(0.14)))
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)

                if findSearching {
                    ProgressView().padding(.top, 30)
                    Spacer()
                } else if findQuery.trimmingCharacters(in: .whitespaces).count >= 2 && findHits.isEmpty {
                    Text("No results for “\(findQuery)”").foregroundStyle(.secondary).padding(.top, 30)
                    Spacer()
                } else {
                    List {
                        if !findHits.isEmpty {
                            Text(findHits.count >= 500 ? "500+ results" : "\(findHits.count) result\(findHits.count == 1 ? "" : "s")")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(Array(groupedHits.enumerated()), id: \.offset) { _, group in
                            Section(group.title) {
                                ForEach(group.items, id: \.offset) { i, hit in
                                    Button { showFind = false; openHit(i) } label: {
                                        (Text(hit.before) + Text(hit.match).bold().foregroundColor(Theme.accentText) + Text(hit.after))
                                            .font(.system(size: 15, design: .serif)).foregroundStyle(Color.primary)
                                            .lineLimit(3)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Find")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showFind = false } } }
        }
        .onChange(of: findQuery) { _, q in runFind(q) }
        .frame(minWidth: isSpread ? 460 : nil, minHeight: isSpread ? 560 : nil)
        .presentationDetents([.large])
    }

    var groupedHits: [(title: String, items: [(offset: Int, element: FindHit)])] {
        var out: [(title: String, items: [(offset: Int, element: FindHit)])] = []
        for (i, h) in findHits.enumerated() {
            if out.last?.title == h.chapterTitle { out[out.count - 1].items.append((i, h)) }
            else { out.append((h.chapterTitle, [(i, h)])) }
        }
        return out
    }

    /// "‹  3 of 12  ›" while stepping through results.
    var findBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 4) {
                Button { openHit(max(0, (findIndex ?? 0) - 1)) } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 40)
                }.disabled((findIndex ?? 0) == 0).accessibilityLabel("Previous result")
                Button { showFind = true } label: {
                    Text("“\(findQuery)” · \((findIndex ?? 0) + 1) of \(findHits.count)")
                        .font(.system(size: 14, weight: .medium)).lineLimit(1).monospacedDigit()
                        .padding(.horizontal, 6)
                }.accessibilityLabel("Result \((findIndex ?? 0) + 1) of \(findHits.count). Show all results")
                Button { openHit(min(findHits.count - 1, (findIndex ?? 0) + 1)) } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 40)
                }.disabled((findIndex ?? 0) >= findHits.count - 1).accessibilityLabel("Next result")
                Button { withAnimation { endFind() } } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 40, height: 40)
                }.accessibilityLabel("End find")
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.text)
            .padding(.horizontal, 6)
            .background(Capsule().fill(theme.background))
            .background(Capsule().fill(theme.control))
            .overlay(Capsule().strokeBorder(theme.text.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .padding(.bottom, chrome ? 70 : 6)   // takes the footer's place (hidden while finding)
        }
        .transition(.opacity)
    }

    // MARK: Sheets

    var themesSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Themes & Settings").font(.system(size: 20, weight: .bold))
                Spacer()
                Button { showThemes = false } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 30, height: 30).background(Circle().fill(Color.gray.opacity(0.18)))
                }.buttonStyle(.plain).accessibilityLabel("Close")
            }
            HStack(spacing: 0) {
                Button { applyStyle(model.style.smaller()) } label: {
                    Text("A").font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.plain).disabled(model.style.fontSize <= ReaderStyle.sizes.first!)
                .accessibilityLabel("Smaller text")
                Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 0.5, height: 22)
                Button { applyStyle(model.style.larger()) } label: {
                    Text("A").font(.system(size: 23, weight: .medium)).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.plain).disabled(model.style.fontSize >= ReaderStyle.sizes.last!)
                .accessibilityLabel("Larger text")
            }
            .background(Capsule().fill(Color.gray.opacity(0.14)))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(ReaderTheme.allCases, id: \.self) { t in
                    Button { var s = model.style; s.theme = t; applyStyle(s) } label: {
                        VStack(spacing: 4) {
                            Text("Aa").font(.system(size: 30, weight: t == .bold ? .bold : .regular, design: .serif)).foregroundStyle(t.text)
                            Text(t.name).font(.system(size: 12, weight: .medium)).foregroundStyle(t.text.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity).frame(height: 88)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.background))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(t == theme ? Theme.accentText : Color.gray.opacity(0.25), lineWidth: t == theme ? 2.5 : 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(t.name) theme")
                }
            }
        }
        .padding(22)
        .presentationDetents([.height(340), .large])
        .frame(minWidth: isSpread ? 380 : nil)
    }

    func applyStyle(_ s: ReaderStyle) {
        model.style = s
        onStyle(s)
    }

    var contentsSheet: some View {
        NavigationStack {
            List(model.manifest.chapters, id: \.index) { c in
                Button {
                    showContents = false
                    forward = c.index > model.chapter
                    model.go(chapter: c.index, sentence: nil)
                } label: {
                    HStack {
                        Text(ChapterNaming.title(c)).foregroundStyle(c.isFrontMatter ? Color.secondary : Color.primary)
                            .fontWeight(c.index == model.chapter ? .semibold : .regular)
                        Spacer()
                        if c.index == model.chapter { Image(systemName: "bookmark.fill").foregroundStyle(Theme.accentText) }
                    }
                }
            }
            .navigationTitle("Contents")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showContents = false } } }
        }
        .frame(minWidth: isSpread ? 420 : nil, minHeight: isSpread ? 520 : nil)
    }
}
