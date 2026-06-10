import SwiftUI
import UIKit

/// HomeView's ambient backdrop. Replaces the old `LivingMeshBackground` which
/// read as generic AI-pastel: a slow mesh smothered under a thick material
/// veil. This version has shape and texture — a solid base, one large soft
/// glow centered on the hero, and a film-grain tile that breaks the flatness.
///
/// The glow `tint` is meant to be the dominant color of the hero artwork
/// (sampled by the caller via `Artwork.backgroundColor`), so every Home view
/// is tied to whichever album is currently previewed. Falls back to the app
/// accent until the artwork lands.
struct HomeAmbientBackground: View {
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Cached grain texture — generated once on first appearance and reused
    /// as a tile pattern. Regenerating it per frame would burn CPU for no
    /// visible benefit since film grain is supposed to look "frozen."
    @State private var grain: Image?

    /// Breathing cycle length for the glow, in seconds. Deliberately long —
    /// the motion should be sub-perceptual, something you'd only notice had
    /// stopped if you stared. Anything faster starts reading as animation,
    /// which is exactly the lava-lamp feel the old mesh was removed for.
    private static let breathePeriod: Double = 18

    /// Tames the raw `Artwork.backgroundColor` before painting the glow.
    /// Album-art dominant colors swing from "barely a tint" (monochrome
    /// covers) to "fully saturated neon" (pop / electronic covers). Left
    /// unbounded, vivid covers paint the page blue and the iOS-26 Liquid
    /// Glass cards refract that blue right through their edges, making the
    /// surfaces look like they have no margin. The clamp keeps saturation
    /// in a calm band and lifts very dim covers into a visible wash.
    private var clampedTint: Color {
        let ui = UIColor(tint)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        // `getHue` returns false for non-RGB sources (e.g. dynamic system
        // colors). Bail to the raw tint — better than NaNs.
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            return tint
        }
        let s2 = max(0.18, min(0.55, s))
        let b2 = max(0.42, min(0.78, b))
        return Color(UIColor(hue: h, saturation: s2, brightness: b2, alpha: 1.0))
    }

    var body: some View {
        // Color as the layout root — it accepts any width the parent proposes
        // and never demands more. The glow and grain ride as overlays so their
        // own frame requests don't bubble out and inflate the parent ZStack
        // (an earlier draft put a 540pt Circle as a ZStack sibling, which
        // forced HomeView's outer ZStack to 540pt and pushed every row past
        // the screen edges).
        Color(.systemBackground)
            .overlay {
                // The glow. Big, soft, anchored high so it sits behind the
                // hero stack rather than under the buttons. `.blur(radius: 160)`
                // dissolves the circle's edge entirely — what you see is a
                // wash, not a shape. The overlay can paint outside the Color's
                // bounds since SwiftUI overlays don't clip by default, so the
                // wash still bleeds to the safe-area extension below.
                //
                // The wash breathes: opacity 0.27→0.33 and ±3% scale on an
                // 18-second sine. Under Reduce Motion the timeline freezes
                // (`minimumInterval: .infinity`) and `t = 0` renders the one
                // static frame — phase 0 is exactly the old fixed 0.30 glow.
                TimelineView(.animation(minimumInterval: reduceMotion ? .infinity : 1.0 / 20.0)) { timeline in
                    let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    let phase = sin(t * 2 * .pi / Self.breathePeriod)
                    Circle()
                        .fill(clampedTint)
                        .frame(width: 540, height: 540)
                        .blur(radius: 160)
                        .scaleEffect(1 + 0.03 * phase)
                        .opacity(0.30 + 0.03 * phase)
                        .offset(y: -250)
                }
            }
            .overlay {
                if let grain {
                    grain
                        .resizable(resizingMode: .tile)
                        .opacity(0.13)
                        .blendMode(.overlay)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            // Cross-fade the tint when the hero artwork swaps, so the
            // background doesn't pop between albums.
            .animation(.easeInOut(duration: 0.55), value: tint)
            .onAppear {
                if grain == nil {
                    grain = Self.makeGrain(size: CGSize(width: 128, height: 128))
                }
            }
    }

    /// Generates a small noise tile by laying down a few thousand random
    /// 1-pixel dots. 128×128 is enough variety that the eye doesn't catch the
    /// repeat — and small enough that the encode cost is invisible.
    private static func makeGrain(size: CGSize) -> Image {
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { ctx in
            let cg = ctx.cgContext
            let pixelCount = Int(size.width * size.height) / 5
            for _ in 0..<pixelCount {
                let x = CGFloat.random(in: 0..<size.width)
                let y = CGFloat.random(in: 0..<size.height)
                let value = CGFloat.random(in: 0..<1)
                let alpha = CGFloat.random(in: 0.05..<0.45)
                cg.setFillColor(UIColor(white: value, alpha: alpha).cgColor)
                cg.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return Image(uiImage: uiImage)
    }
}

#Preview("Light — fallback tint") {
    HomeAmbientBackground(tint: .purple)
}

#Preview("Dark — warm tint") {
    HomeAmbientBackground(tint: Color(red: 0.93, green: 0.55, blue: 0.18))
        .preferredColorScheme(.dark)
}
