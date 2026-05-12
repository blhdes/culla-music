import SwiftUI
import UIKit
import MusicKit

/// A pair of UI-friendly colors sampled from a song's artwork.
/// `secondary` is chosen to be hue-distant from `primary` so a gradient
/// between them reads as two distinct tones, not a near-flat fill.
struct ArtworkAccent: Sendable, Equatable {
    let primary: Color
    let secondary: Color

    static func flat(_ color: Color) -> ArtworkAccent {
        ArtworkAccent(primary: color, secondary: color)
    }
}

/// Extracts a UI-friendly accent pair from a song's artwork.
///
/// Pipeline:
/// 1. Fetch the artwork via `Artwork.url(width:height:)` at a tiny size (we never display this image).
/// 2. Downscale into a 32×32 bitmap and bucket pixels into a 4-bit-per-channel histogram,
///    ignoring near-black / near-white / desaturated pixels.
/// 3. Pick the bucket with the best `count × saturation × mid-lightness` score for `primary`,
///    then pick the next-best bucket whose hue is at least ~40° away for `secondary`.
/// 4. Clamp each color into a comfortable HSL range so muddy artwork doesn't muddy the UI.
/// 5. When the image is essentially monochrome, derive `secondary` from `primary` by
///    rotating the hue so the gradient still has some life in it.
///
/// Results are cached in-memory by `songID`.
@MainActor
final class AccentExtractor {
    static let shared = AccentExtractor()

    private var cache: [String: ArtworkAccent] = [:]
    private var inFlight: [String: Task<ArtworkAccent?, Never>] = [:]

    private init() {}

    /// Returns a cached or freshly-extracted accent pair for the song.
    /// Nil when the song has no artwork or extraction fails.
    func accent(for song: Song) async -> ArtworkAccent? {
        let id = song.id.rawValue
        if let cached = cache[id] { return cached }
        if let existing = inFlight[id] { return await existing.value }

        let url = song.artwork?.url(width: 64, height: 64)
        let task = Task<ArtworkAccent?, Never> {
            guard let url else { return nil }
            return await Self.extract(from: url)
        }
        inFlight[id] = task
        let accent = await task.value
        inFlight.removeValue(forKey: id)
        if let accent { cache[id] = accent }
        return accent
    }

    // MARK: - Extraction

    private static func extract(from url: URL) async -> ArtworkAccent? {
        await Task.detached(priority: .userInitiated) { () -> ArtworkAccent? in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data),
                  let cgImage = image.cgImage else { return nil }
            return dominantAccent(from: cgImage)
        }.value
    }

    /// Pure-pixel work — safe to call off the main actor.
    nonisolated private static func dominantAccent(from cgImage: CGImage) -> ArtworkAccent? {
        let size = 32
        let bytesPerRow = size * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let raw = ctx.data else { return nil }
        let pixels = raw.bindMemory(to: UInt8.self, capacity: size * size * 4)

        // First pass: build a histogram of meaningfully-colored pixels and
        // track the best-scoring bucket along the way.
        var counts: [UInt16: Int] = [:]
        var scores: [UInt16: Double] = [:]
        var hues: [UInt16: Double] = [:]

        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let r = pixels[i]
                let g = pixels[i + 1]
                let b = pixels[i + 2]
                let a = pixels[i + 3]
                guard a > 200 else { continue }

                let (h, s, l) = rgbToHSL(
                    r: Double(r) / 255,
                    g: Double(g) / 255,
                    b: Double(b) / 255
                )
                if s < 0.25 || l < 0.15 || l > 0.85 { continue }

                let key = (UInt16(r >> 4) << 8) | (UInt16(g >> 4) << 4) | UInt16(b >> 4)
                counts[key, default: 0] += 1
                hues[key] = h

                let lightnessScore = 1.0 - abs(l - 0.55) / 0.55
                scores[key] = Double(counts[key]!) * s * lightnessScore
            }
        }

        // Best bucket = primary.
        guard let primaryKey = scores.max(by: { $0.value < $1.value })?.key else {
            return nil
        }
        let primaryHue = hues[primaryKey] ?? 0
        let primaryColor = bucketColor(key: primaryKey, pixels: pixels, size: size)
        guard let primaryColor else { return nil }

        // Best bucket whose hue is ≥ ~40° (~0.11 in [0,1]) from primary = secondary.
        let hueGate: Double = 0.11
        let secondaryKey = scores
            .filter { hueDistance(hues[$0.key] ?? 0, primaryHue) >= hueGate }
            .max(by: { $0.value < $1.value })?.key

        let secondaryColor: Color
        if let secondaryKey, let extracted = bucketColor(key: secondaryKey, pixels: pixels, size: size) {
            secondaryColor = extracted
        } else {
            // Monochrome artwork — derive a sibling by rotating the primary's hue.
            secondaryColor = derivedSecondary(from: primaryColor)
        }

        return ArtworkAccent(primary: primaryColor, secondary: secondaryColor)
    }

    /// Average pixels in a bucket for a stable centroid, then clamp into the
    /// comfortable HSL accent range.
    nonisolated private static func bucketColor(
        key: UInt16,
        pixels: UnsafeMutablePointer<UInt8>,
        size: Int
    ) -> Color? {
        var rSum = 0, gSum = 0, bSum = 0, n = 0
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let r = pixels[i], g = pixels[i + 1], b = pixels[i + 2]
                let k = (UInt16(r >> 4) << 8) | (UInt16(g >> 4) << 4) | UInt16(b >> 4)
                if k == key {
                    rSum += Int(r); gSum += Int(g); bSum += Int(b); n += 1
                }
            }
        }
        guard n > 0 else { return nil }

        let rAvg = Double(rSum) / Double(n) / 255
        let gAvg = Double(gSum) / Double(n) / 255
        let bAvg = Double(bSum) / Double(n) / 255

        var (h, s, l) = rgbToHSL(r: rAvg, g: gAvg, b: bAvg)
        s = max(s, 0.45)
        l = min(max(l, 0.45), 0.70)
        let (rOut, gOut, bOut) = hslToRGB(h: h, s: s, l: l)
        return Color(red: rOut, green: gOut, blue: bOut)
    }

    /// When no second hue exists in the artwork, build one by rotating the
    /// primary ~50° around the wheel and nudging lightness for contrast.
    nonisolated private static func derivedSecondary(from color: Color) -> Color {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        var (h, s, l) = rgbToHSL(r: Double(r), g: Double(g), b: Double(b))
        h = (h + 50.0 / 360.0).truncatingRemainder(dividingBy: 1.0)
        if h < 0 { h += 1 }
        l = min(max(l + 0.08, 0.45), 0.70)
        s = max(s, 0.45)
        let (rOut, gOut, bOut) = hslToRGB(h: h, s: s, l: l)
        return Color(red: rOut, green: gOut, blue: bOut)
    }

    /// Shortest distance between two normalized hues (treats hue as circular).
    nonisolated private static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    // MARK: - Color math

    nonisolated private static func rgbToHSL(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let l = (maxC + minC) / 2
        let delta = maxC - minC

        if delta == 0 { return (0, 0, l) }

        let s = l > 0.5 ? delta / (2 - maxC - minC) : delta / (maxC + minC)

        var h: Double
        if maxC == r {
            h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            h = (b - r) / delta + 2
        } else {
            h = (r - g) / delta + 4
        }
        h /= 6
        if h < 0 { h += 1 }
        return (h, s, l)
    }

    nonisolated private static func hslToRGB(h: Double, s: Double, l: Double) -> (r: Double, g: Double, b: Double) {
        if s == 0 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return (
            hueToRGB(p: p, q: q, t: h + 1.0 / 3.0),
            hueToRGB(p: p, q: q, t: h),
            hueToRGB(p: p, q: q, t: h - 1.0 / 3.0)
        )
    }

    nonisolated private static func hueToRGB(p: Double, q: Double, t: Double) -> Double {
        var t = t
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
        if t < 1.0 / 2.0 { return q }
        if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
        return p
    }
}
