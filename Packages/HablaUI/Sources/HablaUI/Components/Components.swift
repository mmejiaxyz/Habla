import SwiftUI

// MARK: - Accent frame (the coloured phone rim in C5)

/// Wraps a screen in a thin accent-coloured rim with a rounded black screen inside.
public struct AccentFrame<Content: View>: View {
    let accent: Color
    let content: Content

    public init(accent: Color, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = content()
    }

    public var body: some View {
        ZStack {
            accent.ignoresSafeArea()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.screen)
                .clipShape(RoundedRectangle(cornerRadius: Theme.screenCorner, style: .continuous))
                .padding(Theme.frameWidth)
        }
    }
}

// MARK: - Top bar: ○  NAME  ×

public struct TopBar: View {
    var title: String
    var leading: String = "○"
    var trailing: String = "×"
    var onLeading: () -> Void = {}
    var onTrailing: () -> Void = {}

    public init(_ title: String, leading: String = "○", trailing: String = "×",
                onLeading: @escaping () -> Void = {}, onTrailing: @escaping () -> Void = {}) {
        self.title = title; self.leading = leading; self.trailing = trailing
        self.onLeading = onLeading; self.onTrailing = onTrailing
    }

    public var body: some View {
        HStack(spacing: 0) {
            control(leading, label: leadingLabel, action: onLeading, alignment: .leading)
            Spacer(minLength: 8)
            Text(title.uppercased()).font(Theme.label(9)).tracking(1.2).lineLimit(1)
            Spacer(minLength: 8)
            control(trailing, label: trailingLabel, action: onTrailing, alignment: .trailing)
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, Theme.margin - 12)
        .frame(height: 52)
    }

    /// 52×52 pt targets (Apple's minimum is 44) with a clear symbol; the whole square is tappable.
    @ViewBuilder func control(_ glyph: String, label: String, action: @escaping () -> Void, alignment: Alignment) -> some View {
        if glyph.isEmpty {
            Color.clear.frame(width: 52, height: 52)
        } else {
            Button(action: action) {
                Group {
                    if let symbol = Self.symbols[glyph] {
                        Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                    } else {
                        Text(glyph).font(Theme.label(12)).tracking(1.2)
                    }
                }
                .padding(.horizontal, 12)
                .frame(minWidth: 52, minHeight: 52, alignment: alignment)
                .contentShape(Rectangle())
            }
            .buttonStyle(TopBarButtonStyle())
            .accessibilityLabel(label)
        }
    }

    static let symbols = ["‹": "chevron.left", "⌄": "chevron.down", "×": "xmark", "+": "plus", "○": "circle"]
    var leadingLabel: String { Self.names[leading] ?? leading }
    var trailingLabel: String { Self.names[trailing] ?? trailing.capitalized }
    static let names = ["‹": "Back", "⌄": "Close", "×": "Close", "+": "Add books", "MAC": "Mac connection"]
}

/// Immediate pressed feedback (the plain style gives none).
struct TopBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Staggered uppercase copy ("ARCHI DESIGN —— / TAKE A LOOK / CNCPT 2021 ®")

public struct StaggeredCaps: View {
    public struct Line: Hashable {
        var text: String
        var indent: CGFloat   // in points
        public init(_ text: String, indent: CGFloat = 0) { self.text = text; self.indent = indent }
    }

    var lines: [Line]
    var size: CGFloat
    var color: Color

    public init(_ lines: [Line], size: CGFloat = 25, color: Color = Theme.text) {
        self.lines = lines; self.size = size; self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: -size * 0.12) {
            ForEach(lines, id: \.self) { line in
                Text(line.text.uppercased())
                    .font(Theme.grotesk(size))
                    .tracking(-0.2)
                    .padding(.leading, line.indent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Read as words: "Good morning, keep listening", not "dash dash".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lines.map { $0.text.replacingOccurrences(of: "—", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Arch (third C5 screen)

public struct ArchShape: Shape {
    public init() {}
    public func path(in r: CGRect) -> Path {
        var p = Path()
        let radius = r.width / 2
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        p.addArc(center: CGPoint(x: r.midX, y: r.minY + radius), radius: radius,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Dashed circle button (C5 "↗")

public struct DashedCircleButton: View {
    var symbol: String
    var size: CGFloat
    var color: Color
    var action: () -> Void

    public init(_ symbol: String = "↗", size: CGFloat = 56, color: Color = Theme.text, action: @escaping () -> Void = {}) {
        self.symbol = symbol; self.size = size; self.color = color; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Text(symbol).font(Theme.grotesk(size * 0.36)).foregroundStyle(color)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hairline-ruled row (middle C5 screen)

public struct RuledRow<Trailing: View>: View {
    var title: String
    var number: String?
    var highlighted: Bool
    var accent: Color
    var trailing: Trailing

    public init(_ title: String, number: String? = nil, highlighted: Bool = false, accent: Color = Theme.appAccent,
                @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.number = number; self.highlighted = highlighted
        self.accent = accent; self.trailing = trailing()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let number {
                    Text(number).font(Theme.label(9)).foregroundStyle(highlighted ? accent : Theme.textDim)
                        .frame(width: 18, alignment: .leading)
                }
                Text(title.uppercased())
                    .font(Theme.grotesk(15))
                    .foregroundStyle(highlighted ? accent : Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                trailing
            }
            .padding(.vertical, 17)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }
}

public extension RuledRow where Trailing == EmptyView {
    init(_ title: String, number: String? = nil, highlighted: Bool = false, accent: Color = Theme.appAccent) {
        self.init(title, number: number, highlighted: highlighted, accent: accent) { EmptyView() }
    }
}

public struct Hairline: View {
    public init() {}
    public var body: some View { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
}

// MARK: - Footer label

public struct FooterLabel: View {
    var text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased()).font(Theme.label(8)).tracking(1.2).foregroundStyle(Theme.textDim)
            .frame(maxWidth: .infinity).padding(.vertical, 24)
    }
}

// MARK: - Small caps label

public struct CapsLabel: View {
    var text: String
    var color: Color
    public init(_ text: String, color: Color = Theme.textDim) { self.text = text; self.color = color }
    public var body: some View {
        Text(text.uppercased()).font(Theme.label(9)).tracking(1.1).foregroundStyle(color)
    }
}

/// Thin progress ring (narration on the Mac, downloads).
public struct ProgressRing: View {
    var value: Double
    var color: Color
    var lineWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false
    public init(value: Double, color: Color = Theme.accent, lineWidth: CGFloat = 2) { self.value = value; self.color = color; self.lineWidth = lineWidth }
    public var body: some View {
        ZStack {
            Circle().stroke(Theme.hairline, lineWidth: lineWidth)
            if value <= 0 {
                // Not started yet (the Mac is still sending it): a turning arc, not a stuck 0 %.
                Circle().trim(from: 0, to: 0.28).stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 270 : -90))
                    .onAppear { guard !reduceMotion else { return }; withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { spin = true } }
            } else {
                Circle().trim(from: 0, to: min(1, max(0.02, value))).stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((min(1, max(0, value)) * 100).rounded())) percent")
    }
}

/// Pill button in the app's style.
public struct PillButton: View {
    var title: String
    var filled: Bool
    var action: () -> Void
    public init(_ title: String, filled: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.filled = filled; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            Text(title).font(Theme.label(15)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(filled ? Theme.ink : Theme.text)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(Capsule().fill(filled ? Theme.accent : Theme.surface))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A small text action ("Unpair this Mac", "Preview"): the whole row around the words is
/// tappable (at least 44 pt tall), not just the letters.
public struct TextLinkButton: View {
    var title: String
    var size: CGFloat
    var color: Color
    var action: () -> Void
    public init(_ title: String, size: CGFloat = 14, color: Color = Theme.accentText, action: @escaping () -> Void) {
        self.title = title; self.size = size; self.color = color; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            Text(title).font(Theme.grotesk(size)).foregroundStyle(color)
                .padding(.vertical, 8).padding(.horizontal, 6)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)   // keep the text aligned with its neighbours
    }
}

/// A compact capsule action ("Install", "Restart", "Find"): the whole capsule is the button.
public struct CapsuleButton: View {
    var title: String
    var fill: Color
    var height: CGFloat
    var action: () -> Void
    public init(_ title: String, fill: Color = Theme.accent, height: CGFloat = 36, action: @escaping () -> Void) {
        self.title = title; self.fill = fill; self.height = height; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            Text(title).font(Theme.label(height > 40 ? 15 : 13)).foregroundStyle(Theme.ink)
                .padding(.horizontal, height > 40 ? 20 : 16).frame(minHeight: height)
                .background(Capsule().fill(fill))
                .frame(minHeight: 44).contentShape(Rectangle())   // 44 pt to tap, whatever it looks like
        }
        .buttonStyle(.plain)
    }
}

public enum Greeting {
    public static func now(_ date: Date = Date()) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }
}

// MARK: - Snapshot support

private struct StaticLayoutKey: EnvironmentKey { static let defaultValue = false }
public extension EnvironmentValues {
    /// Set by the snapshot tool: scroll views render as plain stacks (offscreen rendering can't draw them).
    var staticLayout: Bool {
        get { self[StaticLayoutKey.self] }
        set { self[StaticLayoutKey.self] = newValue }
    }
}

/// A vertical ScrollView that renders as a plain, top-aligned stack in snapshots.
public struct Scroll<Content: View>: View {
    @Environment(\.staticLayout) private var isStatic
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        if isStatic { content.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top).clipped() }
        else { ScrollView(showsIndicators: false) { content } }
    }
}

/// Over a book cover while it downloads: the cover fills in from the bottom as the bytes
/// arrive, a light sweep runs across what's still to come, and a ring shows the percentage
/// (a turning arc while the Mac is still sending it).
public struct DownloadVeil: View {
    var fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false
    public init(fraction: Double) { self.fraction = fraction }
    public var body: some View {
        GeometryReader { geo in
            let f = min(1, max(0, fraction))
            ZStack {
                // What hasn't arrived yet stays veiled; the veil shrinks from the bottom up.
                VStack(spacing: 0) {
                    ZStack {
                        Rectangle().fill(Theme.ink.opacity(0.55))
                        if !reduceMotion {
                            LinearGradient(colors: [.clear, Theme.paper.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: geo.size.width * 0.6)
                                .offset(x: sweep ? geo.size.width : -geo.size.width)
                                .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) { sweep = true } }
                        }
                    }
                    .frame(height: geo.size.height * (1 - f))
                    .clipped()
                    Spacer(minLength: 0)
                }
                .animation(.easeOut(duration: 0.5), value: f)

                // A solid badge, readable on any cover.
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ProgressRing(value: fraction, color: Theme.paper, lineWidth: 2.5).frame(width: 18, height: 18)
                        Text(fraction > 0 ? "\(Int((f * 100).rounded()))%" : "Waiting")
                            .font(.ui(13, weight: .semibold)).foregroundStyle(Theme.paper)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.3), value: Int(f * 100))
                    }
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Capsule().fill(Theme.ink.opacity(0.88)))
                    .padding(.bottom, 12)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(fraction > 0 ? "Downloading" : "Waiting for your Mac")
        .accessibilityValue(fraction > 0 ? "\(Int((min(1, max(0, fraction)) * 100).rounded())) percent" : "")
    }
}

/// Top of the library while books come through the cloud: how many, from where, and a bar
/// that moves (a sweep until the first bytes arrive).
public struct CloudIncomingBanner: View {
    var items: [PhoneStore.CloudIncoming]
    /// The user said yes to downloading the books waiting for Wi-Fi over mobile data.
    var onMobileDownload: (([String]) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false
    @State private var confirming = false
    public init(items: [PhoneStore.CloudIncoming], onMobileDownload: (([String]) -> Void)? = nil) {
        self.items = items; self.onMobileDownload = onMobileDownload
    }

    var held: [PhoneStore.CloudIncoming] { items.filter(\.waitsForWiFi) }
    var heldBytes: Int { held.reduce(0) { $0 + ($1.bytes ?? 0) } }
    var heldSize: String { ByteCountFormatter.string(fromByteCount: Int64(heldBytes), countStyle: .file) }

    var started: [PhoneStore.CloudIncoming] { items.filter { ($0.fraction ?? 0) > 0 } }
    var overall: Double { started.isEmpty ? 0 : items.reduce(0) { $0 + ($1.fraction ?? 0) } / Double(items.count) }
    var title: String {
        if items.count == 1, let t = items[0].title { return started.isEmpty ? "Getting “\(t)”" : "Downloading “\(t)”" }
        return started.isEmpty ? "Getting \(items.count) books" : "Downloading \(items.count) books"
    }
    var detail: String {
        started.isEmpty ? "Your Mac is sending it through the cloud. Keep Habla open." : "\(Int((overall * 100).rounded()))%  ·  keep Habla open"
    }

    public var body: some View {
        if !held.isEmpty && held.count == items.count { waitingForWiFi } else { downloading }
    }

    /// On mobile data: the books wait for Wi-Fi unless the user says yes.
    var waitingForWiFi: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi").font(.system(size: 18)).foregroundStyle(Theme.accentText).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(held.count == 1 ? "“\(held[0].title ?? "A book")” is waiting for Wi-Fi" : "\(held.count) books are waiting for Wi-Fi")
                    .font(.ui(15, weight: .medium)).foregroundStyle(Theme.text).lineLimit(2)
                Text(heldBytes > 0 ? "\(heldSize) · it comes in once you’re on Wi-Fi" : "It comes in once you’re on Wi-Fi")
                    .font(Theme.grotesk(13)).foregroundStyle(Theme.textDim).lineLimit(2)
            }
            Spacer(minLength: 0)
            if onMobileDownload != nil {
                Button("Download now") { confirming = true }
                    .font(.ui(14, weight: .semibold)).foregroundStyle(Theme.accentText)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
        .confirmationDialog(heldBytes > 0 ? "Download \(heldSize) over mobile data?" : "Download over mobile data?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Download now") { onMobileDownload?(held.map(\.id)) }
            Button("Wait for Wi-Fi", role: .cancel) {}
        }
    }

    var downloading: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProgressRing(value: overall, color: Theme.accentText, lineWidth: 2.5).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(15, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(detail).font(Theme.grotesk(13)).foregroundStyle(Theme.textDim).lineLimit(2)
                        .contentTransition(.numericText()).animation(.easeOut(duration: 0.3), value: Int(overall * 100))
                }
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    if started.isEmpty {
                        Capsule().fill(Theme.accentText.opacity(0.7)).frame(width: geo.size.width * 0.3)
                            .offset(x: reduceMotion ? 0 : (sweep ? geo.size.width * 0.7 : 0))
                            .onAppear { guard !reduceMotion else { return }; withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { sweep = true } }
                    } else {
                        Capsule().fill(Theme.accentText).frame(width: max(6, geo.size.width * overall))
                            .animation(.easeOut(duration: 0.5), value: overall)
                    }
                }
            }
            .frame(height: 4)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
        .accessibilityElement(children: .combine)
    }
}
