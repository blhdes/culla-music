import SwiftUI
import MusicKit

/// One-time gesture guide, shown the first time the user lands on a populated
/// swipe deck. A balanced glass "compass": a small song-card token sits dead
/// centre, and four equal-sized direction tiles fan out around it on a 3×3 grid
/// — up = Love, left = Dismiss, right = Add, down = Share — so the spatial
/// mapping is taught purely by position. Each tile is a tinted meaning badge
/// (heart, ✕, +, share) over a one-word label; the grid keeps all four on a
/// shared axis so the cross reads symmetric, not lopsided.
///
/// The whole compass rides one soft glass slab (containment + depth) so it reads
/// as a single instrument rather than four loose chips. A quiet footer line
/// carries the one gesture with no spatial home — double-tap to skip — so it
/// lives here instead of as a separate post-guide capsule. The card token is a
/// 1:1 square, mirroring an album cover (the thing actually being swiped).
///
/// Sits on an opaque, theme-aware ground so it never reads as part of the deck
/// behind it. Dismissed by "Got it" or by tapping anywhere; the caller flips
/// `OnboardingFlags.swipeGuide` in `onDismiss`, so it appears only once.
struct SwipeGuideOverlay: View {
    /// Artwork of the card that will be dealt the moment the guide dismisses, so
    /// the centre token previews the real cover instead of a blank placeholder.
    /// Nil (artwork missing / errored) falls back to the music-note square.
    var artwork: Artwork?
    var onDismiss: () -> Void

    @Environment(\.appAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One-shot entrance: the content settles upward as it fades in. Transform
    /// only — never opacity on the glass — so it can't reproduce the flash.
    @State private var appeared = false

    private let tileWidth: CGFloat = 78

    var body: some View {
        ZStack {
            ground

            VStack(spacing: 28) {
                header
                // Compass + its footnote read as one unit, so they're grouped
                // tighter than the gaps to the header and CTA.
                VStack(spacing: 16) {
                    compass
                    doubleTapHint
                }
                cta
            }
            .padding(28)
            .offset(y: (!appeared && !reduceMotion) ? 14 : 0)
        }
        // Flatten the whole overlay into a single layer so the parent's
        // opacity fade-in/out composites it as one image. Fading glass/material
        // surfaces per-element makes each one re-rasterize its blur and flash;
        // compositing first applies the opacity to the finished result instead.
        .compositingGroup()
        .task {
            // Run the rise on the same clock as the parent's fade-in (≈0.3s, no
            // delay) so the glass lifts *as* it fades, instead of sitting fully
            // opaque while it's still sliding — that lag read as "buggy".
            guard !reduceMotion else { return }
            withAnimation(.smooth(duration: 0.3)) { appeared = true }
        }
    }

    // MARK: - Ground

    private var ground: some View {
        ZStack {
            Color(.systemBackground)
            // Neutral focus vignette — edges sink a touch so the compass lifts.
            // No color wash; depth only.
            RadialGradient(
                colors: [.clear, Color.primary.opacity(0.03)],
                center: .center, startRadius: 130, endRadius: 480
            )
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 5) {
            Text("Swipe to sort")
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
            Text("Flick a card toward what you want")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Compass

    /// A 3×3 grid keeps the card token on both axes and gives every direction
    /// tile an identical footprint, so the cross is symmetric regardless of how
    /// long each label is. The empty corners reserve their cells (sized off the
    /// tiles in the same row/column) so nothing collapses inward.
    private var compass: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                corner
                tile(.up)
                corner
            }
            GridRow {
                tile(.left)
                dragHintCard
                tile(.right)
            }
            GridRow {
                corner
                tile(.down)
                corner
            }
        }
        .padding(22)
        // One soft glass slab behind the whole compass — the containment that
        // turns four loose chips into a single instrument.
        .glassSurface(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// Empty grid cell. `Color.clear` adopts the size of the tile sharing its
    /// row/column, so the corners hold the cross's shape without drawing.
    private var corner: some View {
        Color.clear.frame(width: tileWidth, height: 1)
    }

    private func tile(_ dir: Dir) -> some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(dir.tint(accent).opacity(0.16))
                    .frame(width: 46, height: 46)
                Image(systemName: dir.symbol)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(dir.tint(accent))
                    .symbolRenderingMode(.hierarchical)
            }
            Text(dir.label)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(width: tileWidth)
    }

    /// The card token, looping a soft drag demo — it leans toward Add (right),
    /// springs back, then toward Love (up) — so the user sees the cover is the
    /// thing you drag, not a static badge. Reduce Motion gets the still card.
    @ViewBuilder
    private var dragHintCard: some View {
        if reduceMotion {
            cardToken
        } else {
            PhaseAnimator(DragHint.allCases) { phase in
                cardToken
                    // Rotate first (around the card's own centre), then offset,
                    // so a right flick tilts *and* slides like a real drag.
                    .rotationEffect(phase.rotation)
                    .offset(phase.offset)
            } animation: { phase in
                phase.animation
            }
        }
    }

    /// The thing being swiped — a 1:1 square (an album cover) lifted off the
    /// glass slab with a soft shadow, so it reads as solid content sitting on
    /// the (translucent) instrument around it.
    private var cardToken: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(.secondarySystemBackground))
            .frame(width: 66, height: 66)
            .overlay {
                // The real cover when we have it (library artwork needs
                // ArtworkImage, not AsyncImage); the music-note square otherwise.
                if let artwork {
                    ArtworkImage(artwork, width: 66, height: 66)
                } else {
                    Image(systemName: "music.note")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
    }

    /// The one swipe gesture with no spatial home on the compass — a quiet line
    /// directly under it, deliberately lighter than the tiles so it reads as a
    /// footnote, not a fifth direction.
    private var doubleTapHint: some View {
        HStack(spacing: 7) {
            Image(systemName: "hand.tap.fill")
                .font(.footnote.weight(.semibold))
            Text("Double-tap a card to skip it")
                .font(.system(.footnote, design: .rounded).weight(.medium))
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - CTA

    private var cta: some View {
        // Reuse the app's hero CTA vocabulary (bold accent gradient, not glass),
        // constrained to a compact width so it invites without shouting.
        GradientCapsuleButton(title: "Got it", action: onDismiss)
            .frame(maxWidth: 220)
            .padding(.top, 4)
    }
}

// MARK: - Drag-hint keyframes

/// The looping demo the card token cycles through: rest → lean right (Add) →
/// rest → lean up (Love) → rest… The two `center` rests are distinct cases so
/// the loop has four clean keyframes (a card springs back between flicks).
/// `allCases` order *is* the playback order.
private enum DragHint: CaseIterable {
    case center1, right, center2, up

    var offset: CGSize {
        switch self {
        case .center1, .center2: .zero
        case .right: CGSize(width: 16, height: 0)
        case .up: CGSize(width: 0, height: -16)
        }
    }

    /// Tilt follows the drag: a right flick rolls the card clockwise; the
    /// straight-up flick stays level. Rests sit square.
    var rotation: Angle {
        switch self {
        case .center1, .center2, .up: .degrees(0)
        case .right: .degrees(5)
        }
    }

    /// Animation used to move *into* this keyframe. Flicks ease out after a
    /// short hold (the delay pauses the card at centre first); rests spring
    /// back so the release feels elastic.
    var animation: Animation {
        switch self {
        case .center1, .center2: .spring(response: 0.45, dampingFraction: 0.72)
        case .right, .up: .easeOut(duration: 0.5).delay(0.55)
        }
    }
}

// MARK: - Direction model

private enum Dir {
    case up, down, left, right

    /// The *meaning* glyph, not a direction arrow — position around the card
    /// already conveys which way to flick, so each icon can describe the action.
    var symbol: String {
        switch self {
        case .up: "heart.fill"
        case .down: "square.and.arrow.up"
        case .left: "xmark"
        case .right: "plus"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .up: "Love"
        case .down: "Share"
        case .left: "Dismiss"
        case .right: "Add"
        }
    }

    func tint(_ accent: Color) -> Color {
        switch self {
        case .up: .pink
        case .right: accent
        case .left, .down: .secondary
        }
    }
}
