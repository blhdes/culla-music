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

        let task = Task<ArtworkAccent?, Never> {
            guard let url = await Self.resolveHTTPSArtworkURL(for: song) else { return nil }
            return await Self.extract(from: url)
        }
        inFlight[id] = task
        let accent = await task.value
        inFlight.removeValue(forKey: id)
        if let accent { cache[id] = accent }
        return accent
    }

    // MARK: - URL resolution

    /// Returns a publicly-fetchable HTTPS artwork URL for the song.
    ///
    /// Library songs can hand back `musicKit://` artwork URLs that
    /// `URLSession` can't resolve, so the pixel extractor would silently nil
    /// out for any library item that wasn't catalog-matched as HTTPS. We
    /// bridge via the song's catalog twin (ISRC → title+artist) to get a
    /// public URL, mirroring the same trick `MusicLibraryService` already
    /// uses for hot-clip preview URLs.
    private static func resolveHTTPSArtworkURL(for song: Song) async -> URL? {
        if let url = song.artwork?.url(width: 64, height: 64), url.scheme == "https" {
            return url
        }

        if let isrc = song.isrc, !isrc.isEmpty {
            let request = MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc)
            if let match = try? await request.response().items.first,
               let url = match.artwork?.url(width: 64, height: 64),
               url.scheme == "https" {
                return url
            }
        }

        var search = MusicCatalogSearchRequest(
            term: "\(song.title) \(song.artistName)",
            types: [Song.self]
        )
        search.limit = 10
        guard let response = try? await search.response() else { return nil }

        let titleLower = song.title.lowercased()
        let artistLower = song.artistName.lowercased()
        let best = response.songs.first(where: {
            $0.title.lowercased() == titleLower &&
            $0.artistName.lowercased() == artistLower
        }) ?? response.songs.first

        if let url = best?.artwork?.url(width: 64, height: 64), url.scheme == "https" {
            return url
        }
        return nil
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

        // Single pass: bucket every meaningfully-colored pixel into a 4-bit-
        // per-channel histogram, accumulating rgb sums + a quality score per
        // bucket. The pre-aggregated stats let `bucketColor` compute centroids
        // without re-scanning the pixel grid.
        var stats: [UInt16: BucketStats] = [:]

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
                let lightnessScore = 1.0 - abs(l - 0.55) / 0.55

                var entry = stats[key] ?? BucketStats()
                entry.count += 1
                entry.rSum += Int(r)
                entry.gSum += Int(g)
                entry.bSum += Int(b)
                entry.score += s * lightnessScore
                entry.hue = h
                stats[key] = entry
            }
        }

        guard let primaryEntry = stats.max(by: { $0.value.score < $1.value.score }) else {
            // No bucket cleared the saturation gate → cover is essentially
            // monochrome. Don't bail: synthesize a tinted-slate pair keyed to
            // the cover's average lightness so B&W artwork still gets a
            // coherent sidebar tint instead of falling back to the palette.
            return monochromeAccent(pixels: pixels, size: size)
        }
        let primaryKey = primaryEntry.key
        let primaryHue = primaryEntry.value.hue
        guard let primaryColor = bucketColor(stats: primaryEntry.value) else { return nil }

        // Best bucket whose hue is ≥ ~40° (~0.11 in [0,1]) from primary = secondary.
        let hueGate: Double = 0.11
        let secondaryEntry = stats
            .filter { $0.key != primaryKey && hueDistance($0.value.hue, primaryHue) >= hueGate }
            .max(by: { $0.value.score < $1.value.score })

        let secondaryColor: Color
        if let secondaryEntry, let extracted = bucketColor(stats: secondaryEntry.value) {
            secondaryColor = extracted
        } else {
            // Monochrome artwork — derive a sibling by rotating the primary's hue.
            secondaryColor = derivedSecondary(from: primaryColor)
        }

        return ArtworkAccent(primary: primaryColor, secondary: secondaryColor)
    }

    /// Fallback for greyscale artwork: averages lightness across the same
    /// pixel grid (without the saturation gate) and builds a low-saturation
    /// tinted-slate pair. Dark covers get a cool slate (steel blue); light
    /// covers get a warm slate (sand). Per-cover lightness keeps the tint
    /// visibly varying between B&W songs instead of being one fixed grey.
    nonisolated private static func monochromeAccent(
        pixels: UnsafeMutablePointer<UInt8>,
        size: Int
    ) -> ArtworkAccent? {
        var lSum: Double = 0
        var count = 0
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                guard pixels[i + 3] > 200 else { continue }
                let r = Double(pixels[i]) / 255
                let g = Double(pixels[i + 1]) / 255
                let b = Double(pixels[i + 2]) / 255
                let (_, _, l) = rgbToHSL(r: r, g: g, b: b)
                if l < 0.05 || l > 0.95 { continue }
                lSum += l
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let avgL = lSum / Double(count)

        let hue = avgL < 0.5 ? 215.0 / 360.0 : 35.0 / 360.0
        let s = 0.22
        let l = min(max(avgL, 0.50), 0.65)
        let (r1, g1, b1) = hslToRGB(h: hue, s: s, l: l)
        let primary = Color(red: r1, green: g1, blue: b1)

        let secondHue = (hue + 40.0 / 360.0).truncatingRemainder(dividingBy: 1.0)
        let (r2, g2, b2) = hslToRGB(h: secondHue, s: s, l: l)
        let secondary = Color(red: r2, green: g2, blue: b2)
        return ArtworkAccent(primary: primary, secondary: secondary)
    }

    /// Reads the bucket's pre-aggregated centroid + clamps into the
    /// comfortable HSL accent range.
    nonisolated private static func bucketColor(stats: BucketStats) -> Color? {
        guard stats.count > 0 else { return nil }
        let rAvg = Double(stats.rSum) / Double(stats.count) / 255
        let gAvg = Double(stats.gSum) / Double(stats.count) / 255
        let bAvg = Double(stats.bSum) / Double(stats.count) / 255

        let (h, sRaw, lRaw) = rgbToHSL(r: rAvg, g: gAvg, b: bAvg)
        let s = max(sRaw, 0.45)
        let l = min(max(lRaw, 0.45), 0.70)
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

/// Per-bucket accumulator used by `AccentExtractor.dominantAccent`. Storing
/// rgb sums in the first pass means `bucketColor` no longer has to re-walk
/// all 1024 pixels twice (once per output color) — it reads the centroid
/// out of the pre-aggregated stats directly.
///
/// `nonisolated` because the project sets `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor`, which would otherwise make this struct's init @MainActor and
/// trip a warning when the nonisolated `dominantAccent` constructs one.
nonisolated fileprivate struct BucketStats {
    var count: Int = 0
    var rSum: Int = 0
    var gSum: Int = 0
    var bSum: Int = 0
    /// Sum of `s * lightnessScore` across pixels in this bucket. Replaces
    /// the old `scores[key] = count * s * lightnessScore` line that was
    /// overwriting on every hit — the final score reflected just the
    /// last pixel's color quality, not the bucket's overall.
    var score: Double = 0
    var hue: Double = 0
}
