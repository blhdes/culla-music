import SwiftUI

// MARK: - Shared playback chrome

/// The play/pause + progress vocabulary shared by the art carousel (`CoverCard`)
/// and the swipe deck (`SongCardView`). They were near-identical copies that
/// drifted apart once and cost a multi-iteration bug, so the *pixels* live here
/// in one place. What stays at each call site is the structure that legitimately
/// differs: who owns the tap (the carousel's disc is a passive overlay; the
/// swipe card wraps the disc in its own `Button`) and where the disc sits in the
/// layout (always a ZStack sibling of the artwork, never an `.overlay` on it).

/// Circular progress trace drawn around the play disc, filling clockwise from
/// 12 o'clock — the universal "playback progress" idiom.
///
/// `smoothingValue` is the divergence the two screens keep on purpose: the
/// carousel passes the live position so the trim eases between ticks with a
/// hairline `.linear(0.2)`; the swipe card's hot-clip ring passes `nil` so the
/// trim steps un-animated (it already updates ~10×/s, and an implicit animation
/// there would only add a competing layout transaction next to the disc).
struct PlaybackProgressRing: View {
    /// Raw 0…1 fraction; clamped here so a transient `inf`/`NaN` can't escape.
    let progress: Double
    let size: CGFloat
    var lineWidth: CGFloat = 3
    var smoothingValue: Double? = nil

    var body: some View {
        Circle()
            .trim(from: 0, to: min(1, max(0, progress)))
            .stroke(
                .white.opacity(0.92),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            // -90° puts the start of the trim at 12 o'clock.
            .rotationEffect(.degrees(-90))
            .animation(smoothingValue == nil ? nil : .linear(duration: 0.2), value: smoothingValue)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
    }
}

/// Frosted-glass play/pause disc with a white glyph. The stacking order is
/// load-bearing: `glassSurface` is applied first (sits closer to the icon) and
/// the black scrim second (lands further back), giving a darkened frosted disk
/// that keeps the white glyph readable on any artwork — bright or dark.
///
/// This is the *visual only* — it claims no touches and isn't a button. Callers
/// add their own affordance: the carousel marks it `.allowsHitTesting(false)`
/// and routes taps through the cover's `Button`; the swipe card wraps it in a
/// `Button(action:)`.
struct GlassPlayPauseDisc: View {
    let isPlaying: Bool
    let iconSize: CGFloat
    let discSize: CGFloat

    var body: some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: iconSize, weight: .bold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: discSize, height: discSize)
            .glassSurface(in: Circle(), interactive: true)
            .background(.black.opacity(0.45), in: Circle())
    }
}
