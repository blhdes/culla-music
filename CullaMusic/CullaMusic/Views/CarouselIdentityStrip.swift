import SwiftUI

/// Top breadcrumb strip on `HomeArtCarouselView`. Tells the user which mode
/// they're exploring and how many covers are loaded into the deck, and is the
/// tap target for the mode-switcher Menu the carousel wraps it in. The
/// trailing `chevron.up.chevron.down` is the only affordance for that
/// interactivity — small and secondary so the strip still reads as a label
/// first, control second.
///
/// Lives in its own file (instead of as a private struct on the carousel
/// view) so `HomeArtCarouselView.swift` stays under the global manifesto's
/// 200-line extraction threshold.
///
/// The count uses `.contentTransition(.numericText())` so the digit ticks
/// up smoothly as the feed pages in additional songs.
struct CarouselIdentityStrip: View {
    let mode: ReviewMode
    /// Song count to display. `nil` while no count is known yet — renders
    /// a quiet "Loading…" instead of a placeholder zero (which would
    /// briefly flash an empty count before the real value lands).
    let count: Int?
    /// True when `count` is the loaded-so-far page count, not the real
    /// total. Appends a "+" to the digits so the user sees e.g. "100+
    /// songs" rather than a misleading absolute number.
    let isPartial: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: mode.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(mode.title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.3)
                .foregroundStyle(.primary)
                .contentTransition(.opacity)

            Circle()
                .fill(.secondary)
                .frame(width: 3, height: 3)
                .opacity(0.55)

            countLabel

            // Standard "this opens a menu" affordance — same glyph iOS uses
            // for Menu-backed controls system-wide. Kept secondary and small
            // so the strip still reads label-first.
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Capsule())
        .glassSurface(in: Capsule(), interactive: false)
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var countLabel: some View {
        if let count {
            HStack(spacing: 4) {
                // numericText animates the digit roll; the "+" suffix sits in
                // its own non-animated Text so the two don't compete for the
                // numericText transition. The "+" only appears when the count
                // is a loaded-so-far page count (real total still loading).
                HStack(spacing: 0) {
                    Text(count.formatted())
                        .contentTransition(.numericText())
                    if isPartial {
                        Text("+")
                    }
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)

                Text(count == 1 ? "song" : "songs")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Loading…")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}
