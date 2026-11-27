import SwiftUI
import HablaCore

extension PhoneStore {
    /// What the Activity strip and sheet show: books coming in and going out (Wi-Fi or cloud),
    /// narration on any device, and anything waiting, with the plain reason.
    public var activitySnapshot: ActivitySnapshot {
        var entries: [ActivityEntry] = []
        var seen = Set<String>()
        let byID = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        func title(_ id: String?, _ fallback: String?) -> String {
            id.flatMap { byID[$0]?.title } ?? fallback ?? id.flatMap { cloudManifests[$0]?.title } ?? "A book"
        }
        func cover(_ id: String?) -> (Image?, String?) {
            guard let id, let m = manifest(id) else { return (nil, id.flatMap { cloudManifests[$0]?.accentColor }) }
            return (CoverCache.image(bundle: bundle(id).url, revision: m.revision), m.accentColor)
        }

        // Narrating: on this iPhone, or on another device of the account.
        for (id, fraction) in phoneNarration {
            let b = byID[id]; let (img, accent) = cover(id)
            entries.append(ActivityEntry(id: "narrate-" + id, kind: "Narrating · on this iPhone", title: title(id, nil),
                                         detail: "Readable now · \(b?.narrated ?? 0) of \(b?.narratable ?? 0) chapters narrated",
                                         cover: img, accentHex: accent, progress: fraction, tone: .running))
            seen.insert("narrate-" + id)
        }
        for b in books where !b.isTextOnly && !b.isFullyNarrated && !seen.contains("narrate-" + b.id) {
            guard let device = narratingOn[b.id] else { continue }
            let (img, accent) = cover(b.id)
            entries.append(ActivityEntry(id: "narrate-" + b.id, kind: "Narrating · chapter \(min(b.narrated + 1, b.narratable)) of \(b.narratable)",
                                         title: b.title, detail: "On \(device) · chapters arrive here as they’re done",
                                         cover: img, accentHex: accent,
                                         progress: b.narratable > 0 ? Double(b.narrated) / Double(b.narratable) : nil, tone: .running))
        }

        // Books coming in or going out (Wi-Fi and cloud), as the transfers report them.
        for e in activityEvents {
            let (img, accent) = cover(e.bookID)
            let name = title(e.bookID, e.title)
            let readable = e.bookID.map { manifest($0) != nil } ?? false
            var entry: ActivityEntry
            switch e.state {
            case .running(let p):
                let verb = e.kind == .sending ? "Sending" : "Getting"
                let pct = p.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
                entry = ActivityEntry(id: e.id, kind: verb + pct, title: name,
                                      detail: [readable && e.kind == .getting ? "Readable now" : nil, e.route].compactMap { $0 }.joined(separator: " · "),
                                      cover: img, accentHex: accent, progress: p, tone: .running)
            case .waiting(let why):
                entry = ActivityEntry(id: e.id, kind: "Waiting", title: name, detail: why, cover: img, accentHex: accent, tone: .waiting)
            case .failed(let why):
                let id = e.bookID
                entry = ActivityEntry(id: e.id, kind: "Didn’t finish", title: name, detail: why, cover: img, accentHex: accent,
                                      tone: .failed, actionLabel: "Try again") { [weak self] in
                    guard let self, let id else { return }
                    Task { try? await self.download(id) }
                }
            case .done:
                let time = e.updatedAt.formatted(date: .omitted, time: .shortened)
                entry = ActivityEntry(id: e.id, kind: (e.kind == .sending ? "Sent · " : "Arrived · ") + time, title: name,
                                      detail: e.kind == .sending ? "On its way to your other devices" : (e.route ?? "On this iPhone"),
                                      cover: img, accentHex: accent, tone: .done)
            }
            entries.append(entry)
            seen.insert(e.id)
        }

        // Waiting for Wi-Fi (mobile data needs a yes), or on its way through the cloud.
        for c in cloudIncoming where !seen.contains("get-" + c.id) {
            let (img, accent) = cover(c.id)
            let size = c.bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
            if c.waitsForWiFi {
                entries.append(ActivityEntry(id: "get-" + c.id, kind: "Waiting for Wi-Fi", title: title(c.id, c.title),
                                             detail: "Comes in once you’re on Wi-Fi" + (size.map { " (\($0))" } ?? "") + ".",
                                             cover: img, accentHex: accent, tone: .waiting, actionLabel: "Get it now") { [weak self] in
                    self?.confirmMobile = [c.id]
                })
            } else {
                entries.append(ActivityEntry(id: "get-" + c.id, kind: "Getting", title: title(c.id, c.title),
                                             detail: c.title == nil ? "Your other device is sending it through the cloud. Keep Habla open."
                                                                    : "Cloud · keep Habla open",
                                             cover: img, accentHex: accent, progress: c.fraction, tone: .running))
            }
        }

        // Books added here that still have to reach a Mac to be narrated.
        for id in outbox where isWaitingForMac(id) && !seen.contains("narrate-" + id) {
            let (img, accent) = cover(id)
            entries.append(ActivityEntry(id: "out-" + id, kind: "Waiting for a Mac", title: title(id, nil),
                                         detail: "Goes to the best Mac to be narrated as soon as one is on. You can read it now.",
                                         cover: img, accentHex: accent, tone: .waiting))
        }

        var notice: (String, String)?
        if let until = cloudPausedUntil, until > Date() {
            let day = until.formatted(.dateTime.day().month(.wide))
            notice = ("Cloud paused until \(day)",
                      "This period’s free allowance is used up. At home, Wi-Fi still works, and your place in each book keeps syncing there.")
        }
        return ActivitySnapshot(notice: notice, entries: entries)
    }

    /// The user said yes to downloading over mobile data.
    public func confirmMobileDownload() {
        guard let ids = confirmMobile else { return }
        confirmMobile = nil
        allowMobileData(for: ids)
    }

    /// Bytes still to download for books waiting for Wi-Fi.
    func pendingBytes(_ ids: [String]) -> Int {
        cloudIncoming.filter { ids.contains($0.id) }.reduce(0) { $0 + ($1.bytes ?? 0) }
    }
}

/// The Activity sheet (Figma "22 Sheet — Activity").
public struct PhoneActivitySheet: View {
    @ObservedObject var store: PhoneStore
    public init(store: PhoneStore) { self.store = store }
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activity").font(Theme.display(34)).foregroundStyle(Theme.text)
                        Text("Everything moving between your devices").font(Theme.grotesk(13)).foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                    Button("Done") { dismiss() }.font(.ui(15, weight: .medium)).foregroundStyle(Theme.accentText)
                }
                ActivityList(store.activitySnapshot)
            }
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 34)
        }
        .background(Theme.paper)
        .presentationDragIndicator(.visible)
        .mobileDataConfirmation(store)
    }
}

extension View {
    /// "Download 240 MB over mobile data?" for books the user asked to get now.
    func mobileDataConfirmation(_ store: PhoneStore) -> some View {
        confirmationDialog({
            let bytes = store.pendingBytes(store.confirmMobile ?? [])
            return bytes > 0 ? "Download \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) over mobile data?"
                             : "Download over mobile data?"
        }(), isPresented: Binding(get: { store.confirmMobile != nil }, set: { if !$0 { store.confirmMobile = nil } }),
           titleVisibility: .visible) {
            Button("Download now") { store.confirmMobileDownload() }
            Button("Wait for Wi-Fi", role: .cancel) { store.confirmMobile = nil }
        }
    }
}
