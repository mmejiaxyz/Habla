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
    public init(value: Double, color: Color = Theme.accent) { self.value = value; self.color = color }
    public var body: some View {
        ZStack {
            Circle().stroke(Theme.hairline, lineWidth: 2)
            Circle().trim(from: 0, to: min(1, max(0.02, value))).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
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
