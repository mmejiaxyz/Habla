import Foundation
import AVFoundation
import MediaPlayer
import HablaCore

/// Plays a book's narrated chapters (one .m4a per chapter) and reports the current
/// sentence from the timing files. Continues into the next narrated chapter, keeps the
/// lock screen / Control Center / media keys in sync, and pauses for interruptions.
@MainActor
public final class NarrationPlayer: ObservableObject {
    public static let rates: [Double] = [0.8, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0]

    @Published public private(set) var bookID: String?
    @Published public private(set) var bookTitle = ""
    @Published public private(set) var author = ""
    @Published public private(set) var chapter = 0
    @Published public private(set) var chapterTitle = ""
    @Published public private(set) var sentence = 0
    @Published public private(set) var time: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var isPlaying = false
    @Published public internal(set) var message: String?
    @Published public var rate: Double = UserDefaults.standard.object(forKey: "habla.rate") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(rate, forKey: "habla.rate"); if isPlaying { player?.rate = Float(rate) }; updateNowPlaying() }
    }
    /// Minutes left on the sleep timer, or -1 for "end of chapter".
    @Published public private(set) var sleepTimer: Int?

    /// Called when a chapter's audio can't be decoded (damaged download): the app re-fetches it.
    public var onDamaged: ((String) -> Void)?
    private var statusObservation: NSKeyValueObservation?

    /// (bookID, chapter, sentence, audioTime) — called on pause, chapter change and every few seconds.
    public var onPosition: ((String, Int, Int, TimeInterval) -> Void)?

    private var bundle: BookBundle?
    private(set) var manifest: BookManifest?
    private var timing: ChapterTiming?
    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var lastSaved = Date.distantPast
    private var sleepTask: Task<Void, Never>?
    /// The audible break between chapters: the next chapter starts after this silence.
    /// Played here rather than rendered into the audio, so books narrated before it get it too.
    public static var chapterBreak: TimeInterval = 1.5
    private var breakTask: Task<Void, Never>?
    private var remoteConfigured = false

    public init() {}

    public var isLoaded: Bool { bookID != nil }

    // MARK: Loading

    /// Opens a book at (chapter, sentence). If that chapter has no audio yet, the next narrated one.
    public func load(bundle: BookBundle, manifest: BookManifest, chapter c: Int, sentence s: Int?, time t: TimeInterval? = nil, autoplay: Bool) {
        let previousBook = bookID
        if previousBook != nil && previousBook != manifest.id { save(force: true) }
        self.bundle = bundle; self.manifest = manifest
        bookID = manifest.id; bookTitle = manifest.title; author = manifest.author
        if previousBook != manifest.id { sleepTimer = nil; sleepTask?.cancel() }
        guard let start = manifest.chapters.first(where: { $0.index >= c && $0.audioStatus == .ready }) else {
            stopEngine()
            timing = nil; time = 0; duration = 0; sentence = s ?? 0
            message = manifest.chapters.contains { $0.audioStatus == .ready }
                ? "This chapter isn't narrated yet." : "This book is still being narrated on your Mac."
            chapter = c; chapterTitle = ChapterNaming.title(of: c, in: manifest)
            return
        }
        let sameChapter = start.index == c
        let requestedPending = manifest.chapters.first { $0.index == c }?.audioStatus == .pending
        message = sameChapter || !requestedPending ? nil
            : "“\(ChapterNaming.title(of: c, in: manifest))” isn't narrated yet — playing “\(ChapterNaming.title(start))”."
        openChapter(start, sentence: sameChapter ? s : nil, time: sameChapter ? t : nil)
        if autoplay { play() }
    }

    /// Picks up new chapters after a sync without interrupting playback.
    public func refresh(manifest m: BookManifest) {
        guard m.id == bookID else { return }
        manifest = m
    }

    private func openChapter(_ info: ChapterInfo, sentence s: Int?, time t: TimeInterval?) {
        guard let bundle, let audio = info.audioFile else { return }
        stopEngine()
        configureSession()
        timing = try? bundle.timing(info)
        chapter = info.index
        chapterTitle = ChapterNaming.title(info)
        duration = timing?.duration ?? info.duration ?? 0

        let item = AVPlayerItem(url: bundle.fileURL(audio))
        item.audioTimePitchAlgorithm = .timeDomain   // clean speech at 0.8×–2×
        statusObservation = item.observe(\.status) { [weak self] it, _ in
            guard it.status == .failed else { return }
            Task { @MainActor in
                guard let self, let id = self.bookID else { return }
                self.isPlaying = false
                self.message = "This chapter's audio is damaged. Trying to repair it from your Mac…"
                self.onDamaged?(id)
            }
        }
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false
        player = p

        let startTime = t ?? s.flatMap { id in timing?.sentences.first { $0.id == id }?.start } ?? 0
        sentence = s ?? timing?.sentences.first?.id ?? 0
        time = startTime
        if startTime > 0 { p.seek(to: CMTime(seconds: startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }

        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] cm in
            MainActor.assumeIsolated { self?.tick(cm.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.chapterEnded() }
        }
        updateNowPlaying()
    }

    private func stopEngine() {
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        observer = nil; endObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }

    // MARK: Transport

    public func play() {
        guard let player else { return }
        // At the end of a chapter: continue with the next one (e.g. after the "end of chapter"
        // sleep timer); at the end of the book, start the chapter again instead of silent "playing".
        if duration > 0, time >= duration - 0.5 {
            if let next = nextReady() { openChapter(next, sentence: nil, time: 0); self.player?.playImmediately(atRate: Float(rate)); isPlaying = true; updateNowPlaying(); return }
            seek(to: 0, player: player)
        }
        configureSession()
        player.playImmediately(atRate: Float(rate))
        isPlaying = true
        updateNowPlaying()
    }

    public func clearMessage() { message = nil }

    public func pause() {
        breakTask?.cancel(); breakTask = nil
        player?.pause()
        isPlaying = false
        save(force: true)
        updateNowPlaying()
    }

    public func toggle() { isPlaying ? pause() : play() }

    public func skip(_ seconds: TimeInterval) {
        guard let player else { return }
        let target = time + seconds
        let playing = isPlaying          // openChapter stops the engine; remember the state first
        if target < 0, let prev = previousReady() {
            openChapter(prev, sentence: nil, time: max(0, (prev.duration ?? 0) + target))
            if playing { play() }
            return
        }
        if target > duration, let next = nextReady() {
            openChapter(next, sentence: nil, time: min(target - duration, next.duration ?? 0))
            if playing { play() }
            return
        }
        seek(to: min(max(0, target), max(0, duration - 0.5)), player: player)
    }

    public func seek(fraction: Double) {
        guard let player, duration > 0 else { return }
        seek(to: duration * min(max(0, fraction), 1), player: player)
    }

    /// Jump to a sentence (from the reader's "listen from here"). The reader passes its book
    /// when the player has another one loaded (or none); otherwise the loaded book is used.
    public func jump(chapter c: Int, sentence s: Int, autoplay: Bool = true,
                     in bundle: BookBundle? = nil, manifest: BookManifest? = nil) {
        breakTask?.cancel(); breakTask = nil
        let bundle = bundle ?? self.bundle
        let manifest = manifest ?? self.manifest
        guard let bundle, let manifest else { return }
        if c == chapter, manifest.id == bookID, let start = timing?.sentences.first(where: { $0.id == s })?.start, let player {
            seek(to: start, player: player)
            sentence = s
            if autoplay { play() }
        } else {
            load(bundle: bundle, manifest: manifest, chapter: c, sentence: s, autoplay: autoplay)
        }
    }

    public func nextChapter() {
        breakTask?.cancel(); breakTask = nil
        guard let n = nextReady() else { return }
        let playing = isPlaying
        openChapter(n, sentence: nil, time: 0)
        if playing { play() }
        save(force: true)
    }

    public func previousChapter() {
        // Like a music player: restart this chapter unless we're at its very start.
        if time > 5, let player { seek(to: 0, player: player); return }
        guard let p = previousReady() else { return }
        let playing = isPlaying
        openChapter(p, sentence: nil, time: 0)
        if playing { play() }
        save(force: true)
    }

    public func cycleRate() {
        let i = Self.rates.firstIndex { $0 >= rate - 0.001 } ?? 0
        rate = Self.rates[(i + 1) % Self.rates.count]
    }

    public func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepTimer = minutes
        guard let m = minutes, m > 0 else { return }
        sleepTask = Task { [weak self] in
            var left = m
            while left > 0 {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { return }
                left -= 1
                await MainActor.run { self?.sleepTimer = left > 0 ? left : nil }
            }
            await MainActor.run { self?.pause() }
        }
    }

    /// Writes the current position now (app going to the background).
    public func flush() { save(force: true) }

    public func unload() {
        sleepTask?.cancel(); sleepTimer = nil
        breakTask?.cancel(); breakTask = nil
        save(force: true)
        stopEngine()
        bookID = nil
        #if os(iOS)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }

    private func seek(to t: TimeInterval, player: AVPlayer) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        tick(t)
        save(force: true)
        updateNowPlaying()
    }

    // MARK: Progress

    private func tick(_ t: TimeInterval) {
        guard t.isFinite else { return }
        time = t
        if let id = timing?.sentence(at: t + 0.05), id != sentence { sentence = id }
        save(force: false)
    }

    private func chapterEnded() {
        if sleepTimer == -1 { sleepTimer = nil; pause(); return }
        guard let next = nextReady() else {
            isPlaying = false
            time = duration
            message = manifest?.chapters.contains(where: { $0.index > chapter && $0.audioStatus == .pending }) == true
                ? "The next chapter is still being narrated on your Mac." : "The end."
            save(force: true)
            updateNowPlaying()
            return
        }
        openChapter(next, sentence: nil, time: 0)
        save(force: true)
        // Still "playing" during the break, so the controls don't flicker to paused.
        isPlaying = true
        breakTask?.cancel()
        breakTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.chapterBreak * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isPlaying else { return }
            self.breakTask = nil
            self.play()
        }
    }

    private func nextReady() -> ChapterInfo? { manifest?.chapters.first { $0.index > chapter && $0.audioStatus == .ready } }
    private func previousReady() -> ChapterInfo? { manifest?.chapters.last { $0.index < chapter && $0.audioStatus == .ready } }

    private func save(force: Bool) {
        guard let bookID else { return }
        if !force && Date().timeIntervalSince(lastSaved) < 15 { return }
        lastSaved = Date()
        onPosition?(bookID, chapter, sentence, time)
    }

    // MARK: System integration

    private func configureSession() {
        #if os(iOS)
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try? s.setActive(true)
        if !remoteConfigured {
            NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
                let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                let resume = ((n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0) & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0
                MainActor.assumeIsolated {
                    if type == .began { self?.player?.pause(); self?.isPlaying = false; self?.save(force: true) }
                    else if type == .ended, resume { self?.play() }
                }
            }
            NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
                let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
                // Headphones unplugged: the system pauses; keep our state honest.
                if reason == .oldDeviceUnavailable { MainActor.assumeIsolated { self?.pause() } }
            }
        }
        #endif
        configureRemote()
    }

    private func configureRemote() {
        guard !remoteConfigured else { return }
        remoteConfigured = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.play() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.toggle() }; return .success }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipBackwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(-15) }; return .success }
        c.skipForwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skip(30) }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.nextChapter() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previousChapter() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { if let self, let p = self.player { self.seek(to: e.positionTime, player: p) } }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard bookID != nil else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapterTitle,
            MPMediaItemPropertyAlbumTitle: bookTitle,
            MPMediaItemPropertyArtist: manifest?.author ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let manifest { info[MPNowPlayingInfoPropertyPlaybackProgress] = manifest.fraction(chapter: chapter, sentence: sentence) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }
}
