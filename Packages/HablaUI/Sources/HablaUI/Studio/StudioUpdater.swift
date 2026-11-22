#if os(macOS)
import AppKit
import Foundation
import HablaCore

/// Keeps Habla for Mac up to date from GitHub releases: checks on launch and every few hours,
/// downloads the new build in the background, and swaps it in when you restart (or quit).
@MainActor
public final class StudioUpdater: ObservableObject {
    public enum State: Equatable {
        case idle
        case checking
        case downloading(build: Int)
        case ready(build: Int)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    public let installedBuild: Int
    private let folder: URL
    private var staged: URL?            // the unpacked new Habla.app
    private var timer: Task<Void, Never>?
    private var installing = false
    private var terminateObserver: NSObjectProtocol?

    nonisolated public init(support: URL? = nil, installedBuild: Int = AppUpdate.installedBuild) {
        let base = support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Habla Studio", isDirectory: true)
        folder = base.appendingPathComponent("Updates", isDirectory: true)
        self.installedBuild = installedBuild
    }

    /// Developer builds run from Xcode / SwiftPM never replace themselves.
    var isDevelopmentBuild: Bool {
        let p = Bundle.main.bundlePath
        return p.contains("/DerivedData/") || p.contains("/.build/") || !p.hasSuffix(".app")
    }

    public func start() {
        guard timer == nil else { return }
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.installOnQuit() }
        }
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)      // let the app settle first
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
    }

    /// Looks for a newer release and downloads it. `userInitiated` reports "up to date" / errors.
    public func check(userInitiated: Bool = false) async {
        switch state { case .checking, .downloading, .ready: return; default: break }
        guard !isDevelopmentBuild else {
            if userInitiated { state = .failed("Updates are off for development builds.") }
            return
        }
        state = .checking
        guard let update = await AppUpdate.available(installed: installedBuild) else {
            state = userInitiated ? .failed("Habla is up to date (build \(installedBuild)).") : .idle
            return
        }
        guard let zip = update.assets["Habla-Mac.zip"] ?? update.assets["Habla-Studio.zip"] else { state = .idle; return }
        state = .downloading(build: update.build)
        do {
            staged = try await download(zip, build: update.build)
            state = .ready(build: update.build)
        } catch {
            state = userInitiated ? .failed("Couldn't download the update: \(error.localizedDescription)") : .idle
        }
    }

    public func dismissMessage() { if case .failed = state { state = .idle } }

    func download(_ url: URL, build: Int) async throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
        let zip = folder.appendingPathComponent("build-\(build).zip")
        try fm.moveItem(at: tmp, to: zip)
        let out = folder.appendingPathComponent("build-\(build)", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        try? fm.removeItem(at: zip)
        // The one app inside the archive (named "Habla.app" since the rename).
        guard let app = (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError("The download was incomplete.") }
        // Only accept a complete Habla Studio of exactly the advertised build.
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              Int(info["CFBundleVersion"] as? String ?? "") == build else { throw UpdateError("The download was incomplete.") }
        try run("/usr/bin/codesign", ["--verify", "--deep", app.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// Whether this copy can replace itself (it lives in a folder you can write to).
    public var canInstall: Bool {
        FileManager.default.isWritableFile(atPath: (Bundle.main.bundlePath as NSString).deletingLastPathComponent)
    }

    /// Quits, swaps in the new build, and opens it again.
    public func installAndRelaunch() {
        guard launchSwap(relaunch: true) else {
            NSWorkspace.shared.open(AppUpdate.releasesPage)
            return
        }
        NSApp.terminate(nil)
    }

    private func installOnQuit() { _ = launchSwap(relaunch: false) }

    private func launchSwap(relaunch: Bool) -> Bool {
        guard !installing, case .ready = state, let staged, canInstall,
              FileManager.default.fileExists(atPath: staged.path) else { return false }
        installing = true
        let script = """
        PID="$1"; OLD="$2"; NEW="$3"; RELAUNCH="$4"; TARGET="$5"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        BAK="$OLD.previous"
        rm -rf "$BAK"
        [ "$TARGET" != "$OLD" ] && [ -e "$TARGET" ] && TARGET="$OLD"   # never overwrite another app
        if mv "$OLD" "$BAK"; then
          if mv "$NEW" "$TARGET"; then rm -rf "$BAK"; else mv "$BAK" "$OLD"; TARGET="$OLD"; fi
        fi
        [ "$RELAUNCH" = 1 ] && open "$TARGET"
        exit 0
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "habla-update", String(ProcessInfo.processInfo.processIdentifier),
                       Bundle.main.bundlePath, staged.path, relaunch ? "1" : "0",
                       // Takes the new name if the app was renamed (Habla Studio.app → Habla.app).
                       ((Bundle.main.bundlePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent(staged.lastPathComponent)]
        do { try p.run() } catch { installing = false; return false }
        return true
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("The update couldn't be unpacked.") }
        return p.terminationStatus
    }

    struct UpdateError: LocalizedError {
        var message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}
#endif
