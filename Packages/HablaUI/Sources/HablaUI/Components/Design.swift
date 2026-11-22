import SwiftUI
import HablaCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// The 2026-11 redesign (Figma "Habla student"): conventional structure (cover grid, tab bar,
// sheets) dressed in Habla's language — paper, ink, one light-blue accent, Bodoni display
// type, hairline rules, framed covers. Shared by the iPhone and the Mac app.

// MARK: - Covers

/// Loads a book's cover (and cover colour) from its bundle once per revision.
@MainActor enum CoverCache {
    private struct Entry { var image: Image?; var accent: String? }
    private static var entries: [String: Entry] = [:]

    private static func entry(bundle: URL, revision: Int) -> Entry {
        let key = "\(bundle.path)#\(revision)"
        if let e = entries[key] { return e }
        var e = Entry(image: nil, accent: nil)
        if let m = try? BookBundle(url: bundle).manifest() {
            e.accent = m.accentColor
            if let file = m.coverFile {
                let url = bundle.appendingPathComponent(file)
                #if canImport(UIKit)
                if let ui = UIImage(contentsOfFile: url.path) { e.image = Image(uiImage: ui) }
                #else
                if let ns = NSImage(contentsOf: url) { e.image = Image(nsImage: ns) }
                #endif
            }
        }
        entries[key] = e
        return e
    }

    static func image(bundle: URL, revision: Int) -> Image? { entry(bundle: bundle, revision: revision).image }
    static func accent(bundle: URL, revision: Int) -> String? { entry(bundle: bundle, revision: revision).accent }
}

/// A book cover: the real one when the bundle has it, otherwise a typographic cover in the
/// book's own colour (remote books, EPUBs without art). Always 2:3.
public struct BookCover: View {
    var title: String
    var author: String
    var accentHex: String?
    var image: Image?

    public init(title: String, author: String, accentHex: String? = nil, image: Image? = nil) {
        self.title = title; self.author = author; self.accentHex = accentHex; self.image = image
    }

    public var body: some View {
        GeometryReader { g in
            ZStack {
                if let image {
                    image.resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                } else {
                    let base = accentHex.map { Color(hex: $0) } ?? Theme.surface
                    base.shade(0.55)
                    VStack(spacing: g.size.width * 0.06) {
                        Text(title.uppercased())
                            .font(Theme.display(g.size.width * 0.13))
                            .multilineTextAlignment(.center).lineLimit(5).minimumScaleFactor(0.5)
                        Rectangle().fill(Theme.ink.opacity(0.4)).frame(width: g.size.width * 0.18, height: 1)
                        Text(author).font(Theme.displayItalic(g.size.width * 0.08)).lineLimit(2)
                            .multilineTextAlignment(.center).minimumScaleFactor(0.6)
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(g.size.width * 0.1)
                }
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A cover in a paper mat (the print-on-the-table look from the player and the cards).
public struct FramedCover: View {
    var cover: BookCover
    var width: CGFloat
    var mat: CGFloat
    var tilt: Double

    public init(_ cover: BookCover, width: CGFloat, mat: CGFloat = 6, tilt: Double = 0) {
        self.cover = cover; self.width = width; self.mat = mat; self.tilt = tilt
    }

    public var body: some View {
        cover.frame(width: width)
            .padding(mat)
            .background(Rectangle().fill(Theme.paper))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 12)
            .rotationEffect(.degrees(tilt))
    }
}

public extension Theme {
    /// Paper (screen) in light mode, whatever the appearance — used for mats and sheets.
    static let paper = Color(hex: "#F8F6F2")
}

// MARK: - Buttons

/// 44 pt round button on surface (the header +, •••, back, close).
public struct RoundIconButton: View {
    var symbol: String
    var label: String
    var fill: Color
    var action: () -> Void
    public init(_ symbol: String, label: String, fill: Color = Theme.surface, action: @escaping () -> Void) {
        self.symbol = symbol; self.label = label; self.fill = fill; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44).background(Circle().fill(fill)).contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

/// The round look for a `Menu` label.
public struct RoundIcon: View {
    var symbol: String
    var fill: Color
    public init(_ symbol: String, fill: Color = Theme.surface) { self.symbol = symbol; self.fill = fill }
    public var body: some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.ink)
            .frame(width: 44, height: 44).background(Circle().fill(fill)).contentShape(Circle())
    }
}

/// Ink / accent / outline pill with an optional SF Symbol.
public struct ActionPill: View {
    public enum Style { case ink, accent, outline }
    var title: String
    var symbol: String?
    var style: Style
    var height: CGFloat
    var action: () -> Void

    public init(_ title: String, symbol: String? = nil, style: Style = .ink, height: CGFloat = 50, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.style = style; self.height = height; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.system(size: 15, weight: .medium)) }
                Text(title).font(.ui(15, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(style == .ink ? Theme.paper : Theme.ink)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity).frame(height: height)
            .background(Capsule().fill(style == .ink ? Theme.ink : style == .accent ? Theme.accent : .clear))
            .overlay(Capsule().strokeBorder(Theme.ink.opacity(style == .outline ? 0.3 : 0), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

/// Small chip (player options, search scopes).
public struct Chip: View {
    var title: String
    var symbol: String?
    var selected: Bool
    var fill: Color
    public init(_ title: String, symbol: String? = nil, selected: Bool = false, fill: Color = Theme.paper.opacity(0.5)) {
        self.title = title; self.symbol = symbol; self.selected = selected; self.fill = fill
    }
    public var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .medium)) }
            Text(title).font(.ui(15, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(selected ? Theme.paper : Theme.ink)
        .padding(.horizontal, 14).frame(height: 40)
        .background(Capsule().fill(selected ? Theme.ink : fill))
        .frame(minHeight: 44).contentShape(Rectangle())
    }
}

public struct PressStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Section rule ("ALL BOOKS  06 ……… Recent ⌄")

public struct SectionRule<Trailing: View>: View {
    var title: String
    var count: Int?
    var trailing: Trailing
    public init(_ title: String, count: Int? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.count = count; self.trailing = trailing()
    }
    public var body: some View {
        VStack(spacing: 12) {
            Rectangle().fill(Theme.text.opacity(0.12)).frame(height: 1)
            HStack(spacing: 8) {
                Text(title.uppercased()).font(Theme.label(10)).tracking(1.2).foregroundStyle(Theme.text)
                if let count { Text(String(format: "%02d", count)).font(Theme.label(10)).tracking(1.2).foregroundStyle(Theme.text.opacity(0.45)) }
                Spacer()
                trailing
            }
        }
        .accessibilityElement(children: .contain)
    }
}

public extension SectionRule where Trailing == EmptyView {
    init(_ title: String, count: Int? = nil) { self.init(title, count: count) { EmptyView() } }
}

// MARK: - Vertical bubble (speed, sleep timer)

/// A small vertical list that grows out of the control that opened it.
public struct BubblePicker<Value: Hashable>: View {
    var options: [(Value, String)]
    var selected: Value?
    var width: CGFloat
    var choose: (Value) -> Void

    public init(_ options: [(Value, String)], selected: Value?, width: CGFloat = 64, choose: @escaping (Value) -> Void) {
        self.options = options; self.selected = selected; self.width = width; self.choose = choose
    }

    public var body: some View {
        VStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, label) = options[i]
                Button { choose(value) } label: {
                    Text(label).font(.ui(15, weight: .medium)).foregroundStyle(Theme.ink.opacity(value == selected ? 1 : 0.8))
                        .frame(width: width - 12, height: 40)
                        .background(Capsule().fill(value == selected ? Theme.accent : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(value == selected ? .isSelected : [])
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Theme.paper)
            .shadow(color: .black.opacity(0.2), radius: 24, y: 12))
    }
}

// MARK: - Progress line

public struct ProgressLine: View {
    var value: Double
    var color: Color
    var track: Color
    public init(_ value: Double, color: Color = Theme.ink, track: Color = Theme.ink.opacity(0.2)) {
        self.value = value; self.color = color; self.track = track
    }
    public var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(track).frame(height: 1)
                Rectangle().fill(color).frame(width: max(2, g.size.width * min(1, max(0, value))), height: 2)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}
