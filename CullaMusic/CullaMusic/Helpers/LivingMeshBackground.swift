import SwiftUI

/// Slow-drifting mesh gradient seeded by the current app accent. Acts as the
/// ambient backdrop for HomeView — gives the screen a heartbeat without
/// stealing focus from the controls.
///
/// Reads `appAccent` from environment and pairs it with a darker companion
/// derived from the accent itself, so the palette stays cohesive when the user
/// switches accents.
///
/// Honors `accessibilityReduceMotion`: when reduce-motion is on, the mesh
/// renders a single static frame instead of animating.
///
/// Falls back to a simple linear gradient on iOS < 18 (MeshGradient is iOS 18+).
struct LivingMeshBackground: View {
    @Environment(\.appAccent) private var appAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if #available(iOS 18.0, *) {
            meshLayer
        } else {
            fallbackLayer
        }
    }

    @available(iOS 18.0, *)
    private var meshLayer: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? .infinity : 1.0 / 30.0)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            MeshGradient(
                width: 3,
                height: 3,
                points: meshPoints(at: t),
                colors: meshColors
            )
            .ignoresSafeArea()
            // A material veil keeps the gradient from washing out body text.
            // 0.55 in light mode, 0.35 in dark — dark backgrounds need the
            // accent to read through more strongly to feel alive.
            .overlay(
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(colorScheme == .dark ? 0.35 : 0.55)
                    .ignoresSafeArea()
            )
        }
    }

    private var fallbackLayer: some View {
        LinearGradient(
            colors: [appAccent.opacity(0.25), Color(.systemBackground)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    /// 9 control points on a 3×3 grid. The four interior corners wander on a
    /// slow Lissajous curve so the gradient looks like ink drifting in water.
    /// Edges stay anchored so the gradient never "leaves" the screen.
    ///
    /// The side-middle points are based slightly inboard of x=0/x=1 (and the
    /// wander amp is conservative) so a wandered coordinate can never leave
    /// the unit square. MeshGradient does bilinear interpolation; once an
    /// interior point crosses the boundary, the quad triangulation degenerates
    /// and the gradient renders empty triangles ("diagonal cuts") — visible
    /// app-wide whenever the timer ticks across the cycle.
    @available(iOS 18.0, *)
    private func meshPoints(at t: TimeInterval) -> [SIMD2<Float>] {
        let amp: Float = 0.045
        let speed: Float = 0.18
        let phase = Float(t) * speed

        func wander(_ base: SIMD2<Float>, _ seedX: Float, _ seedY: Float) -> SIMD2<Float> {
            SIMD2(
                base.x + amp * sin(phase + seedX),
                base.y + amp * cos(phase + seedY)
            )
        }

        return [
            SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0),
            wander(SIMD2(0.05, 0.5), 0.0, 1.3),
            wander(SIMD2(0.5,  0.5), 1.7, 2.9),
            wander(SIMD2(0.95, 0.5), 3.1, 0.7),
            SIMD2(0, 1), SIMD2(0.5, 1), SIMD2(1, 1)
        ]
    }

    /// Color stops keyed to the accent. Darker companion sits in the corners,
    /// the accent itself blooms in the center, and `.systemBackground` anchors
    /// the edges so the page never feels weightless.
    private var meshColors: [Color] {
        let bg = Color(.systemBackground)
        let accent = appAccent
        let companion = appAccent.opacity(0.65)
        return [
            bg,                       accent.opacity(0.18),     bg,
            companion.opacity(0.45),  accent.opacity(0.35),     companion.opacity(0.45),
            bg,                       accent.opacity(0.18),     bg
        ]
    }
}

#Preview("Light") {
    LivingMeshBackground()
        .environment(\.appAccent, .blue)
}

#Preview("Dark") {
    LivingMeshBackground()
        .environment(\.appAccent, Color(red: 0.93, green: 0.55, blue: 0.18))
        .preferredColorScheme(.dark)
}
