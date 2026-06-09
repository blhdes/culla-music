import SwiftUI

/// One-time gesture guide, shown the first time the user lands on a populated
/// swipe deck. Four glass chips fan out around a small card token — the thing
/// being swiped — so the spatial mapping (up = Love, left = Dismiss, right =
/// Add, down = Share) is taught purely by position. Each chip carries the
/// *meaning* icon (heart, plus, ✕, share) rather than a plain arrow: the
/// layout already says which way to flick, so the glyph can say what it does.
///
/// Deliberately near-wordless — one title, four one-word chips, one button.
/// The secondary gestures (double-tap, info button) are left to be discovered
/// so the guide stays a glance, not a manual.
///
/// Sits on an opaque, theme-aware ground so it never reads as part of the deck
/// behind it. Dismissed by "Got it" or by tapping anywhere; the caller flips
/// `OnboardingFlags.swipeGuide` in `onDismiss`, so it appears only once.
struct SwipeGuideOverlay: View {
    var onDismiss: () -> Void

    @Environment(\.appAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One-shot entrance: the content settles upward as it fades in. Transform
    /// only — never opacity on the glass — so it can't reproduce the flash.
    @State private var appeared = false

    var body: some View {
        ZStack {
            ground

            VStack(spacing: 32) {
                header
                compass
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
            // Delay ~matches the parent's fade-in delay so the rise plays while
            // the overlay is actually visible, not behind opacity 0.
            guard !reduceMotion else { return }
            withAnimation(.smooth(duration: 0.45).delay(0.2)) { appeared = true }
        }
    }

    // MARK: - Ground

    private var ground: some View {
        ZStack {
            Color(.systemBackground)
            // Neutral focus vignette — edges sink a touch so the compass lifts.
            // No color wash; depth only.
            RadialGradient(
                colors: [.clear, Color.primary.opacity(0.05)],
                center: .center, startRadius: 130, endRadius: 480
            )
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
    }

    // MARK: - Header

    private var header: some View {
        Text("Swipe to sort")
            .font(.title2.weight(.semibold))
            .foregroundStyle(.primary)
    }

    // MARK: - Compass

    private var compass: some View {
        VStack(spacing: 14) {
            chip(.up)
            HStack(spacing: 14) {
                chip(.left)
                cardToken
                chip(.right)
            }
            chip(.down)
        }
    }

    private func chip(_ dir: Dir) -> some View {
        HStack(spacing: 7) {
            Image(systemName: dir.symbol)
                .font(.body.weight(.bold))
                .foregroundStyle(dir.tint(accent))
                .symbolRenderingMode(.hierarchical)
            Text(dir.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassSurface(in: Capsule())
    }

    private var cardToken: some View {
        Image(systemName: "music.note")
            .font(.title3.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 56, height: 74)
            .glassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - CTA

    private var cta: some View {
        // Reuse the app's hero CTA vocabulary (bold accent gradient, not glass),
        // constrained to a compact width so it invites without shouting.
        GradientCapsuleButton(title: "Got it", action: onDismiss)
            .frame(maxWidth: 200)
            .padding(.top, 4)
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

    var label: String {
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
