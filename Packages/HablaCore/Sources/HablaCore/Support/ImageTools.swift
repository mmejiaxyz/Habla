import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Cover handling using only ImageIO/CoreGraphics (works on macOS and iOS).
public enum ImageTools {
    /// Soft palette (terracotta, sage, butter, dusty blue), used when a cover has no usable colour.
    public static let fallbackAccents = ["#E39E84", "#B5C9A3", "#E9D29B", "#A7BFD6"]

    /// Downscales and re-encodes a cover as JPEG (keeps bundles small for the phone).
    public static func normalizedCover(_ data: Data, maxPixels: Int = 1200) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Picks the cover's most prominent colour, softened to sit calmly on charcoal.
    public static func accentColor(from data: Data?, seed: String) -> String {
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return stableFallback(seed) }

        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return stableFallback(seed) }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Weighted hue histogram over vivid pixels.
        let buckets = 18
        var weight = [Double](repeating: 0, count: buckets)
        var sums = [(Double, Double, Double)](repeating: (0, 0, 0), count: buckets)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let (h, s, v) = rgbToHsv(r, g, b)
            guard s > 0.3, v > 0.25 else { continue }
            let bucket = min(buckets - 1, Int(h * Double(buckets)))
            let w = s * s * v
            weight[bucket] += w
            sums[bucket].0 += h * w; sums[bucket].1 += s * w; sums[bucket].2 += v * w
        }
        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 2 else {
            return stableFallback(seed)
        }
        let w = weight[best]
        let h = sums[best].0 / w
        // Soft and approachable: muted saturation, light but not glaring.
        let s = min(0.42, max(0.26, sums[best].1 / w * 0.6))
        let v = min(0.90, max(0.80, sums[best].2 / w))
        let (r, g, b) = hsvToRgb(h, s, v)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    static func stableFallback(_ seed: String) -> String {
        let sum = seed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return fallbackAccents[sum % fallbackAccents.count]
    }

    static func rgbToHsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6; if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    static func hsvToRgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
