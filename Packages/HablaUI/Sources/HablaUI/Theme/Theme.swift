import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Visual language from the C5 reference (ARCHI), softened: light paper screens framed by one
/// light-blue accent, oversized Didone serif titles, staggered thin uppercase grotesk,
/// hairline-ruled lists. All fonts ship with iOS.
public enum Theme {
    // MARK: Colour — light first: warm paper white, soft ink, one light-blue accent.
    public enum Appearance: Sendable { case light, dark }
    /// Prototype switch (light is the primary design). Wiring will follow the system setting.
    nonisolated(unsafe) public static var appearance: Appearance = .light
    static var isLight: Bool { appearance == .light }

    /// The one accent: soft light blue. Fills, rims, highlights, buttons.
    public static let accent = Color(hex: "#A7BFD6")
    /// Accent used as *text* — deeper on light backgrounds so it stays readable.
    public static var accentText: Color { isLight ? Color(hex: "#4A6985") : accent }   // ≥4.5:1 on paper and surface
    /// Dark ink for text sitting on the accent (both appearances).
    public static let ink = Color(hex: "#1F1E1C")

    public static var screen: Color { isLight ? Color(hex: "#F8F6F2") : Color(hex: "#1F1E1C") }
    public static var surface: Color { isLight ? Color(hex: "#ECE9E3") : Color(hex: "#2A2926") }
    public static var hairline: Color { isLight ? Color.black.opacity(0.08) : Color.white.opacity(0.10) }
    public static var text: Color { isLight ? Color(hex: "#1F1E1C") : Color(hex: "#EEE9E1") }
    /// Secondary text: 65% ink keeps WCAG AA (≥4.5:1) on paper and on surfaces.
    public static var textDim: Color { text.opacity(0.65) }
    public static var appAccent: Color { accent }

    // MARK: Type
    /// Display serif (Bodoni 72) for titles.
    public static func display(_ size: CGFloat) -> Font { .custom("BodoniSvtyTwoITCTT-Book", size: size, relativeTo: .title) }
    public static func displayItalic(_ size: CGFloat) -> Font { .custom("BodoniSvtyTwoITCTT-BookIta", size: size, relativeTo: .title3) }
    /// Light grotesk for headlines and UI labels.
    public static func grotesk(_ size: CGFloat) -> Font { .custom("HelveticaNeue-Light", size: size, relativeTo: .body) }
    public static func groteskThin(_ size: CGFloat) -> Font { .custom("HelveticaNeue-Thin", size: size, relativeTo: .body) }
    public static func label(_ size: CGFloat = 10) -> Font { .custom("HelveticaNeue", size: size, relativeTo: .caption) }
    /// Reading face outside the reader (quotes, previews).
    public static func reading(_ size: CGFloat) -> Font { .custom("IowanOldStyle-Roman", size: size) }
    public static func readingItalic(_ size: CGFloat) -> Font { .custom("IowanOldStyle-Italic", size: size) }

    // MARK: Metrics — generous, calm spacing
    public static let frameWidth: CGFloat = 5
    public static let screenCorner: CGFloat = 40
    public static let margin: CGFloat = 28
    public static let section: CGFloat = 36
}

public extension Font {
    /// A UI size that grows with the iPhone's text-size setting (Dynamic Type), and stays as
    /// designed on the Mac (whose text styles are smaller than iOS's).
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        #if canImport(UIKit)
        return .system(size: UIFontMetrics.default.scaledValue(for: size), weight: weight, design: design)
        #else
        return .system(size: size, weight: weight, design: design)
        #endif
    }
}

public extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255, opacity: 1)
    }

    /// Darker / lighter variant for cover art.
    func shade(_ amount: Double) -> Color {
        amount < 0 ? Color.black.blend(with: self, by: 1 + amount) : Color.white.blend(with: self, by: 1 - amount)
    }

    func blend(with other: Color, by t: Double) -> Color {
        #if canImport(UIKit)
        let a = UIColor(self), b = UIColor(other)
        var (r1, g1, b1, a1, r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0, 0, 0, 0, 0)
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1); b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        #else
        let a = NSColor(self).usingColorSpace(.sRGB)!, b = NSColor(other).usingColorSpace(.sRGB)!
        let (r1, g1, b1, r2, g2, b2) = (a.redComponent, a.greenComponent, a.blueComponent, b.redComponent, b.greenComponent, b.blueComponent)
        #endif
        let t = CGFloat(t)
        return Color(.sRGB, red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, opacity: 1)
    }
}
