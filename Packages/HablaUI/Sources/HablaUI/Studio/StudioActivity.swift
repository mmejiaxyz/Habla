#if os(macOS)
import SwiftUI
import HablaCore

extension StudioStore {
    /// What the Activity popover shows: the account's devices, narration here and elsewhere,
    /// books going through the cloud, and anything waiting, with the plain reason.
    public var activitySnapshot: ActivitySnapshot {
        var entries: [ActivityEntry] = []
        func cover(_ id: String?) -> (Image?, String?, String) {
            guard let id, let m = books.first(where: { $0.id == id }) else { return (nil, nil, "A book") }
            return (CoverCache.image(bundle: BookBundle.url(for: id, in: library), revision: m.revision), m.accentColor, m.title)
        }

        // Narrating here.
        if let r = render {
            let (img, accent, title) = cover(r.bookID)
            let fraction = r.bookSentencesTotal > 0 ? Double(r.bookSentencesDone) / Double(r.bookSentencesTotal) : nil
            let left = r.secondsLeft.map { " · about \(Format.duration($0)) left" } ?? ""
            entries.append(ActivityEntry(id: "narrate-" + r.bookID,
                                         kind: paused ? "Paused" : "Narrating · chapter \(r.chaptersDone + 1) of \(max(r.chaptersTotal, 1))",
                                         title: title, detail: "Here\(left). Your other devices get each chapter as it’s done.",
                                         cover: img, accentHex: accent, progress: fraction, tone: .running,
                                         actionLabel: paused ? nil : "Pause", action: paused ? nil : { [weak self] in self?.pauseNarration() }))
        }
        // Narrating on another device of the account.
        for m in books where !m.isFullyRendered {
            guard let device = narratingOn[m.id], render?.bookID != m.id else { continue }
            let (img, accent, _) = cover(m.id)
            let narratable = m.chapters.filter { $0.audioStatus != .skipped }
            let done = narratable.filter { $0.audioStatus == .ready }.count
            entries.append(ActivityEntry(id: "narrate-" + m.id, kind: "Narrating · chapter \(min(done + 1, narratable.count)) of \(narratable.count)",
                                         title: m.title, detail: "On \(device) · chapters arrive here as they’re done",
                                         cover: img, accentHex: accent,
                                         progress: narratable.isEmpty ? nil : Double(done) / Double(narratable.count), tone: .running))
        }
        // In the queue here.
        for id in queue where id != render?.bookID {
            let (img, accent, title) = cover(id)
            let why = paused ? (pauseReason.map { "Paused: \($0)." } ?? "Paused. Choose Resume to go on.")
                             : (voiceEngine == .ready ? "Narrated here after the book before it." : "Waiting for the voice engine.")
            entries.append(ActivityEntry(id: "queue-" + id, kind: "Waiting", title: title, detail: why,
                                         cover: img, accentHex: accent, tone: .waiting,
                                         actionLabel: "Cancel", action: { [weak self] in self?.cancelNarration(id) }))
        }
        // Books going through the cloud.
        for e in activityEvents {
            let (img, accent, title) = cover(e.bookID)
            let name = e.title ?? title
            switch e.state {
            case .running(let p):
                let pct = p.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
                entries.append(ActivityEntry(id: e.id, kind: (e.kind == .sending ? "Sending" : "Getting") + pct, title: name,
                                             detail: e.kind == .sending ? "Through the cloud to your other devices" : "Through the cloud",
                                             cover: img, accentHex: accent, progress: p, tone: .running))
            case .waiting(let why):
                entries.append(ActivityEntry(id: e.id, kind: "Waiting", title: name, detail: why, cover: img, accentHex: accent, tone: .waiting))
            case .failed(let why):
                entries.append(ActivityEntry(id: e.id, kind: "Didn’t finish", title: name, detail: why, cover: img, accentHex: accent,
                                             tone: .failed, actionLabel: "Try again", action: { [weak self] in self?.kickBridge(after: 0.5) }))
            case .done:
                let time = e.updatedAt.formatted(date: .omitted, time: .shortened)
                entries.append(ActivityEntry(id: e.id, kind: (e.kind == .sending ? "Sent · " : "Arrived · ") + time, title: name,
                                             detail: e.kind == .sending ? "On the cloud for your other devices" : "From your other device",
                                             cover: img, accentHex: accent, tone: .done))
            }
        }

        // The account's devices: this Mac first.
        let busyNames = Set(narratingOn.values)
        var devices = [ActivityDevice(id: "this", name: "This Mac · " + server.serviceName.replacingOccurrences(of: "Habla on ", with: ""),
                                      status: render != nil ? "Narrating" : (voiceEngine == .ready ? "Ready to narrate" : "Voice engine not ready"),
                                      online: true)]
        for d in accountDevices where d.id != bridgeDeviceID {
            let status: String
            if busyNames.contains(d.name) { status = "Narrating" }
            else if d.online || Date().timeIntervalSince(d.lastSeen) < 5 * 60 { status = d.kind == .phone ? "Open now" : "Idle · ready to help" }
            else { status = "Seen " + d.lastSeen.formatted(.relative(presentation: .named)) }
            devices.append(ActivityDevice(id: d.id, name: d.name, status: status,
                                          online: d.online || Date().timeIntervalSince(d.lastSeen) < 5 * 60))
        }

        var notice: (String, String)?
        if let until = cloudPausedUntil, until > Date() {
            notice = ("Cloud paused until \(until.formatted(.dateTime.day().month(.wide)))",
                      "This period’s free allowance is used up. Wi-Fi at home still works; the cloud picks up again then.")
        }
        return ActivitySnapshot(notice: notice, entries: entries, devices: devices)
    }
}

/// The toolbar button and its popover (Figma "M7 Activity — toolbar popover").
struct StudioActivityButton: View {
    @ObservedObject var store: StudioStore
    @State private var open = false

    var body: some View {
        let snapshot = store.activitySnapshot
        let active = snapshot.running.count
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                if active > 0 {
                    ProgressView().controlSize(.mini)
                    Text("\(active) active").font(.ui(12))
                } else if snapshot.notice != nil || !snapshot.waiting.isEmpty {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 12))
                    Text("Activity").font(.ui(12))
                } else {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 11))
                    Text("Activity").font(.ui(12))
                }
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Theme.surface))
        }
        .buttonStyle(.plain)
        .help("What’s moving between your devices")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Activity").font(Theme.display(24)).foregroundStyle(Theme.text)
                    ActivityList(snapshot, showDevices: true)
                }
                .padding(20)
            }
            .frame(width: 400)
            .frame(maxHeight: 560)
            .background(Theme.paper)
        }
    }
}
#endif
