import SwiftUI
import ServiceManagement
import HablaUI

/// Studio keeps working with no window open: it serves the iPhone, imports books it sends,
/// and narrates them. It also opens itself at login so this happens without anyone at the Mac.
final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// "Keep working in the background" (on by default): ⌘Q hides Habla instead of stopping it.
    static var background: Bool { UserDefaults.standard.object(forKey: "habla.background") as? Bool ?? true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let allowed = MainActor.assumeIsolated { AppQuit.allowed }
        guard Self.background, !allowed else { return .terminateNow }
        MainActor.assumeIsolated { StudioAppDelegate.goToBackground() }
        return .terminateCancel
    }

    /// No window, no Dock icon: narrating, syncing and helping go on; the menu bar icon stays.
    @MainActor static func goToBackground() {
        for w in NSApp.windows where w.isVisible && w.canBecomeMain { w.close() }   // the main window and readers
        NSApp.setActivationPolicy(.accessory)
    }

    @MainActor static func comeForward() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One Habla per Mac: quit any other running copy (e.g. "Habla Studio" from before the
        // rename, started by its old login item) so they don't fight over the sharing port.
        let me = NSRunningApplication.current
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where other.processIdentifier != me.processIdentifier {
            other.terminate()
        }
        // On by default; re-registered each launch so it follows the app if it moves or is renamed.
        if UserDefaults.standard.object(forKey: "habla.openAtLogin") as? Bool ?? true {
            try? SMAppService.mainApp.register()
        }
        // Log out, restart and shut down quit for real.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppQuit.allowed = true }
        }
        // The last window closed while working in the background: drop the Dock icon too.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard Self.background, let closing = note.object as? NSWindow, closing.canBecomeMain else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain && $0 !== closing }) {
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
        }
        // Start serving and narrating even if no window gets opened (login launch, window closed).
        MainActor.assumeIsolated {
            StudioApp.store.start()
            StudioApp.updater.start()
        }
    }
}

/// Habla for Mac: import EPUBs, narrate them with Paradee, share with your iPhone.
@main
struct StudioApp: App {
    /// One line for the menu bar: no titles (a helper Mac never shows the books).
    var backgroundStatus: String {
        if let r = store.render {
            let pct = r.bookSentencesTotal > 0 ? Int(100 * Double(r.bookSentencesDone) / Double(r.bookSentencesTotal)) : 0
            let more = store.queue.count > 1 ? " · \(store.queue.count - 1) more waiting" : ""
            return "Narrating a book · \(pct)%" + more
        }
        if store.helperOnly { return "Helping narrate · idle" }
        return store.paused && !store.queue.isEmpty ? "Narration paused" : "Working in the background"
    }

    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    /// Saved in "habla.background". Plain @State on purpose: MenuBarExtra(isInserted:) bound to
    /// @AppStorage makes SwiftUI rebuild the menus forever (100% CPU, a frozen window) on macOS 27.
    @State private var showsMenuIcon = StudioAppDelegate.background
    private var background: Binding<Bool> {
        Binding(get: { showsMenuIcon }, set: { on in
            UserDefaults.standard.set(on, forKey: "habla.background")
            showsMenuIcon = on
        })
    }
    @MainActor static let store = StudioStore()
    @MainActor static let updater = StudioUpdater()
    @ObservedObject private var store = StudioApp.store
    @StateObject private var player = NarrationPlayer()
    @ObservedObject private var updater = StudioApp.updater
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Habla", id: "main") {
            StudioWindowView(store: store, updater: updater,
                             installScript: Bundle.main.url(forResource: "install", withExtension: "sh"),
                             openReader: { openWindow(value: $0) })
                .frame(minWidth: 1100, minHeight: 700)
                // Double-clicked EPUBs, "Open With", or files dropped on the Dock icon.
                .onOpenURL { url in if url.isFileURL { store.importFiles([url]) } }
                .onAppear {
                    StudioAppDelegate.comeForward()             // back in the Dock while the window is open
                    store.start()
                    updater.start()
                    player.onPosition = { [weak store] book, chapter, sentence, time in
                        guard let store, let m = store.books.first(where: { $0.id == book }) else { return }
                        store.progress.record(.init(bookID: book, chapter: chapter, sentence: sentence, audioTime: time,
                                                   mode: .listening, deviceID: "mac", fraction: m.fraction(chapter: chapter, sentence: sentence)))
                    }
                }
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Habla") {
                    let credits = NSAttributedString(string: store.aboutCredits, attributes: [
                        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await updater.check(userInitiated: true) } }
                Toggle("Keep Working in the Background", isOn: background)
                Toggle("Open at Login", isOn: Binding(get: { openAtLogin }, set: { on in
                    UserDefaults.standard.set(on, forKey: "habla.openAtLogin")
                    if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    openAtLogin = SMAppService.mainApp.status == .enabled
                }))
            }
        }

        // While working in the background: what Habla is doing, without a window.
        MenuBarExtra(isInserted: $showsMenuIcon) {
            Text(backgroundStatus)
            Divider()
            Button("Open Habla") { StudioAppDelegate.comeForward(); openWindow(id: "main") }
            Toggle("Keep Working in the Background", isOn: background)
            Divider()
            Button("Quit Habla Completely") { AppQuit.allowed = true; NSApp.terminate(nil) }
        } label: {
            Image(systemName: store.render != nil ? "waveform" : "book.closed")
        }

        WindowGroup("Reader", for: String.self) { $id in
            if let id {
                StudioReaderWindow(store: store, bookID: id, player: player, dismiss: {})
            }
        }
        .defaultSize(width: 1240, height: 820)
    }
}
