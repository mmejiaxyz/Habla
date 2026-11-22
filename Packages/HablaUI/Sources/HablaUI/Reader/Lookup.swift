import SwiftUI
#if canImport(Translation)
import Translation
#endif
#if canImport(UIKit)
import UIKit
#else
import AppKit
import CoreServices
#endif

/// The built-in dictionary and translator: both are Apple's, on-device and free.
/// iPhone: the system dictionary page (its "Manage" button downloads more dictionaries,
/// e.g. Spanish–English). Mac: the definition from Dictionary.app, shown inline.
enum Lookup {
    #if os(macOS)
    /// Plain-text definition from the Mac's dictionaries (nil if none has the word).
    static func definition(_ term: String) -> String? {
        let ns = term as NSString
        guard let def = DCSCopyTextDefinition(nil, ns, CFRange(location: 0, length: ns.length)) else { return nil }
        return def.takeRetainedValue() as String
    }
    #endif
}

#if canImport(UIKit)
/// Apple's dictionary page for a word.
struct DictionaryPage: UIViewControllerRepresentable {
    let term: String
    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }
    func updateUIViewController(_ vc: UIReferenceLibraryViewController, context: Context) {}
}
#endif

/// Shows Apple's translation card (iOS 17.4 / macOS 14.4 and later; on-device after the
/// first download of a language).
struct TranslateSheet: ViewModifier {
    @Binding var text: String?

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 17.4, macOS 14.4, *) {
            content.translationPresentation(isPresented: Binding(get: { text != nil }, set: { if !$0 { text = nil } }),
                                            text: text ?? "")
        } else {
            content
        }
        #else
        content
        #endif
    }

    static var isAvailable: Bool {
        #if canImport(Translation)
        if #available(iOS 17.4, macOS 14.4, *) { return true }
        #endif
        return false
    }
}
