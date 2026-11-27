import SwiftUI
import HablaCore

// The Activity view (Figma "21 Library — activity strip", "22 Sheet — Activity",
// "M7 Activity — toolbar popover"): everything moving between the account's devices.

/// One row as shown: what, which book, how it's going, and what can be done about it.
public struct ActivityEntry: Identifiable {
    public enum Tone { case running, waiting, failed, done }
    public var id: String
    public var kind: String            // "GETTING · 42%", "NARRATING · CHAPTER 3 OF 42"
    public var title: String
    public var detail: String
    public var cover: Image?
    public var accentHex: String?
    public var progress: Double?
    public var tone: Tone
    public var actionLabel: String?
    public var action: (() -> Void)?

    public init(id: String, kind: String, title: String, detail: String, cover: Image? = nil, accentHex: String? = nil,
                progress: Double? = nil, tone: Tone, actionLabel: String? = nil, action: (() -> Void)? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.cover = cover
        self.accentHex = accentHex; self.progress = progress; self.tone = tone
        self.actionLabel = actionLabel; self.action = action
    }
}

/// A device of the account, for the Mac popover's device list.
public struct ActivityDevice: Identifiable {
    public var id: String
    public var name: String
    public var status: String
    public var online: Bool
    public init(id: String, name: String, status: String, online: Bool) {
        self.id = id; self.name = name; self.status = status; self.online = online
    }
}

/// Everything the Activity view shows.
public struct ActivitySnapshot {
    public var notice: (title: String, detail: String)?
    public var entries: [ActivityEntry]
    public var devices: [ActivityDevice]
    public init(notice: (title: String, detail: String)? = nil, entries: [ActivityEntry] = [], devices: [ActivityDevice] = []) {
        self.notice = notice; self.entries = entries; self.devices = devices
    }
    public var running: [ActivityEntry] { entries.filter { $0.tone == .running } }
    public var waiting: [ActivityEntry] { entries.filter { $0.tone == .waiting || $0.tone == .failed } }
    public var done: [ActivityEntry] { entries.filter { $0.tone == .done } }
    public var isEmpty: Bool { notice == nil && entries.allSatisfy { $0.tone == .done } }
}

private let failedRed = Color(red: 0.70, green: 0.27, blue: 0.22)

public struct ActivityRow: View {
    var entry: ActivityEntry
    var coverWidth: CGFloat = 36
    public init(_ entry: ActivityEntry, coverWidth: CGFloat = 36) { self.entry = entry; self.coverWidth = coverWidth }

    public var body: some View {
        HStack(alignment: .top, spacing: 14) {
            coverView
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.kind.uppercased()).font(Theme.label(10)).tracking(1.2)
                    .foregroundStyle(entry.tone == .failed ? failedRed : Theme.accentText)
                Text(entry.title).font(Theme.display(19)).foregroundStyle(Theme.text)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(entry.detail).font(Theme.grotesk(13)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                if let p = entry.progress, entry.tone == .running {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.surface)
                            Capsule().fill(Theme.text).frame(width: max(4, geo.size.width * min(1, max(0, p))))
                                .animation(.easeOut(duration: 0.4), value: p)
                        }
                    }
                    .frame(height: 3).padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if entry.tone == .done {
                Image(systemName: "checkmark").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.text)
            } else if let label = entry.actionLabel, let action = entry.action {
                Button(label, action: action).buttonStyle(.plain)
                    .font(.ui(13, weight: .medium))
                    .foregroundStyle(entry.tone == .running ? Theme.textDim : Theme.accentText)
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder var coverView: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        if let image = entry.cover {
            image.resizable().aspectRatio(contentMode: .fill)
                .frame(width: coverWidth, height: coverWidth * 1.45).clipShape(shape)
        } else {
            shape.fill(entry.accentHex.map { Color(hex: $0) } ?? Theme.surface)
                .frame(width: coverWidth, height: coverWidth * 1.45)
        }
    }
}

/// The sections of the Activity view (sheet on iPhone, popover on Mac).
public struct ActivityList: View {
    var snapshot: ActivitySnapshot
    var showDevices: Bool
    public init(_ snapshot: ActivitySnapshot, showDevices: Bool = false) { self.snapshot = snapshot; self.showDevices = showDevices }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let n = snapshot.notice {
                VStack(alignment: .leading, spacing: 3) {
                    Text(n.title).font(.ui(15, weight: .medium)).foregroundStyle(Theme.text)
                    Text(n.detail).font(Theme.grotesk(13)).foregroundStyle(Theme.text.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.32)))
                .padding(.top, 16)
            }
            if showDevices && !snapshot.devices.isEmpty {
                label("Your devices")
                ForEach(snapshot.devices) { d in
                    HStack(spacing: 10) {
                        Circle().fill(d.online ? Color(red: 0.35, green: 0.65, blue: 0.45) : Theme.text.opacity(0.25)).frame(width: 7, height: 7)
                        Text(d.name).font(.ui(13)).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(d.status).font(Theme.grotesk(12)).foregroundStyle(Theme.textDim).lineLimit(1)
                    }
                    .padding(.vertical, 7)
                }
            }
            section("In progress", snapshot.running)
            section("Waiting", snapshot.waiting)
            section("Earlier today", snapshot.done)
            if snapshot.entries.isEmpty {
                Text("Nothing is moving right now. New books, narration and downloads show up here.")
                    .font(Theme.grotesk(14)).foregroundStyle(Theme.textDim).padding(.top, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder func section(_ title: String, _ items: [ActivityEntry]) -> some View {
        if !items.isEmpty {
            label(title)
            ForEach(items) { ActivityRow($0) }
        }
    }

    func label(_ s: String) -> some View {
        Text(s.uppercased()).font(Theme.label(10)).tracking(1.2).foregroundStyle(Theme.text.opacity(0.5))
            .padding(.top, 22).padding(.bottom, 2)
    }
}

/// The iPhone's strip under the Library header: the first thing happening, and how many more.
public struct ActivityStrip: View {
    var snapshot: ActivitySnapshot
    var open: () -> Void
    public init(_ snapshot: ActivitySnapshot, open: @escaping () -> Void) { self.snapshot = snapshot; self.open = open }

    var headline: String {
        if let r = snapshot.running.first {
            let verb = r.kind.components(separatedBy: " · ")[0].lowercased()
            let pct = r.progress.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
            return verb.prefix(1).uppercased() + verb.dropFirst() + " " + r.title + pct
        }
        if let n = snapshot.notice { return n.title }
        if let w = snapshot.waiting.first { return w.title + " · " + w.kind.lowercased() }
        return "Activity"
    }

    var more: String? {
        var parts: [String] = []
        let r = max(0, snapshot.running.count - 1)
        if r > 0 { parts.append("\(r) more in progress") }
        let w = snapshot.waiting.count - (snapshot.running.isEmpty && snapshot.notice == nil ? 1 : 0)
        if w > 0 { parts.append("\(w) waiting") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    public var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Circle().fill(snapshot.waiting.contains { $0.tone == .failed } ? failedRed : Theme.accentText).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.ui(13)).foregroundStyle(Theme.text).lineLimit(1)
                    if let more { Text(more).font(.ui(12)).foregroundStyle(Theme.textDim).lineLimit(1) }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text.opacity(0.4))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Activity: \(headline)")
        .accessibilityHint("Shows everything moving between your devices")
    }
}
