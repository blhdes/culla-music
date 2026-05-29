import SwiftUI

/// A single placeholder "bone" for skeleton loading states: a filled shape with
/// a soft highlight sweeping across it. Build a skeleton by laying these out in
/// the same geometry as the real content, so the reveal reads as the layout
/// *sharpening into focus* rather than a spinner popping into a finished screen.
///
/// The sweep is driven by a shared `TimelineView` clock, so several bones laid
/// out together stay phase-synced — at any instant their highlights sit at the
/// same fraction across, reading as one coordinated shimmer.
///
/// Respects `accessibilityReduceMotion`: when on, the sweep is dropped entirely
/// and the bone renders as a calm static placeholder (freeze, don't slow —
/// motion was explicitly opted out of).
struct SkeletonShape<S: Shape>: View {
    let shape: S
    var fill: Color = .primary.opacity(0.10)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        shape
            .fill(fill)
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation) { timeline in
                        SweepHighlight(phase: Self.phase(at: timeline.date))
                    }
                    // Clip the full-bleed sweep to this bone's own shape so the
                    // highlight shows at full strength inside crisp (rounded)
                    // edges — masking by the fill's alpha would dim it instead.
                    .clipShape(shape)
                    .allowsHitTesting(false)
                }
            }
    }

    /// 0→1 ramp on a 1.5s loop. The band is offscreen at both 0 and 1, so the
    /// wrap from 1→0 is invisible.
    private static func phase(at date: Date) -> Double {
        let period = 1.5
        let t = date.timeIntervalSinceReferenceDate
        return (t.truncatingRemainder(dividingBy: period)) / period
    }
}

/// A soft white band that travels left→right across its container, lightening
/// whatever sits beneath it via `.plusLighter` (works in both light and dark).
private struct SweepHighlight: View {
    let phase: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let band = max(w * 0.45, 60)
            LinearGradient(
                colors: [.clear, .white.opacity(0.5), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: band)
            // Start fully off the leading edge, end fully off the trailing edge.
            .offset(x: -band + (w + band) * phase)
            .blendMode(.plusLighter)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        SkeletonShape(shape: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .frame(width: 220, height: 220)
        HStack(spacing: 12) {
            SkeletonShape(shape: RoundedRectangle(cornerRadius: 6))
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonShape(shape: Capsule()).frame(width: 160, height: 11)
                SkeletonShape(shape: Capsule()).frame(width: 100, height: 9)
            }
            Spacer()
        }
    }
    .padding(40)
}
