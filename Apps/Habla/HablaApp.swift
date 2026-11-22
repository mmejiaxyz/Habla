import SwiftUI
import HablaUI
import ParadeeKit

/// Habla for iPhone: listen to and read the books narrated by Habla on your Mac, and narrate
/// books on the phone itself (Paradee, the same voice as the Mac) when the Mac isn't around.
@main
struct HablaApp: App {
    init() { PhoneStore.onDeviceVoice = { ParadeeEngine() } }

    var body: some Scene {
        WindowGroup { PhoneRoot() }
    }
}
