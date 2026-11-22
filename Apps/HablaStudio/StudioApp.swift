import SwiftUI
import ServiceManagement
import HablaUI

/// Studio keeps working with no window open: it serves the iPhone, imports books it sends,
/// and narrates them. It also opens itself at login so this happens without anyone at the Mac.
final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
        // Start serving and narrating even if no window gets opened (login launch, window closed).
        MainActor.assumeIsolated {
            StudioApp.store.start()
            StudioApp.updater.start()
        }
    }
}

/// Habla for Mac: import EPUBs, narrate them with Kokoro, share with your iPhone.
@main
struct StudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var delegate
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
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
                    store.start()
                    updater.start()
                    player.onPosition = { [weak store] book, chapter, sentence, time in
                        guard let store, let m = store.books.first(where: { $0.id == book }) else { return }
                        store.progress.merge(.init(bookID: book, chapter: chapter, sentence: sentence, audioTime: time,
                                                   mode: .listening, deviceID: "mac", fraction: m.fraction(chapter: chapter, sentence: sentence)))
                    }
                }
        }
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await updater.check(userInitiated: true) } }
                Toggle("Open at Login", isOn: Binding(get: { openAtLogin }, set: { on in
                    UserDefaults.standard.set(on, forKey: "habla.openAtLogin")
                    if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    openAtLogin = SMAppService.mainApp.status == .enabled
                }))
            }
        }

        WindowGroup("Reader", for: String.self) { $id in
            if let id {
                StudioReaderWindow(store: store, bookID: id, player: player, dismiss: {})
            }
        }
        .defaultSize(width: 1240, height: 820)
    }
}
