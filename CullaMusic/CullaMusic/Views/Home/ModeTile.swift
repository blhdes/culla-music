import SwiftUI

// MARK: - ModeTile

/// One row in the mode selector. Unselected tiles sit on a glass surface
/// (iOS 26) / `.thinMaterial` fallback. The selected tile fills solid with the
/// accent gradient and flips its label, icon, and count to a contrast-aware
/// foreground (`Color.idealForeground`) so it reads clearly on any palette —
/// the fill alone telegraphs "this is the deck you open", no accent halo.
struct ModeTile: View {
    let mode: ReviewMode
    let isSelected: Bool
    let count: Int?
    let isLoadingCount: Bool
    let onTap: () -> Void

    @Environment(\.appAccent) private var appAccent

    /// Foreground for the selected (accent-filled) state — white on dark
    /// swatches, near-black on light ones (Amber, Rose) so the label stays
    /// legible whatever the accent.
    private var accentForeground: Color { appAccent.idealForeground }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                iconBadge

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(isSelected ? accentForeground : .primary)
                    Text(mode.description)
                        .font(.caption)
                        .foregroundStyle(isSelected ? accentForeground.opacity(0.82) : .secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                countSlot

                if isSelected {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accentForeground)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            // Selected → a confident solid accent fill (same gradient
            // vocabulary as the Start CTA). Sits in front of the glass below
            // so the white/near-black label reads against an opaque surface
            // instead of a muddy tint. Unselected → nothing here, just glass.
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(
                            colors: [appAccent, appAccent.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .glassSurface(
                in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                interactive: true
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isSelected ? .white.opacity(0.20) : .white.opacity(0.06),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isSelected)
    }

    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(isSelected ? accentForeground.opacity(0.20) : Color.secondary.opacity(0.12))
                .frame(width: 40, height: 40)
            Image(systemName: mode.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isSelected ? accentForeground : .secondary)
                .symbolEffect(.bounce, value: isSelected)
        }
    }

    @ViewBuilder
    private var countSlot: some View {
        Group {
            if isLoadingCount {
                // A shimmering "a number is coming" bone — same SkeletonShape
                // vocabulary as the hero deck, so the badges and the hero
                // shimmer in sync on a cold launch. Tinted to the contrast
                // foreground when the tile is selected (accent-filled) so the
                // bone stays legible instead of vanishing into the accent.
                SkeletonShape(
                    shape: Capsule(),
                    fill: isSelected ? accentForeground.opacity(0.28) : .primary.opacity(0.10)
                )
                .frame(width: 36, height: 15)
            } else if let count {
                Text(count.formatted())
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(isSelected ? accentForeground : .secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
            }
        }
        .frame(width: 52, alignment: .trailing)
        .animation(.snappy, value: count)
    }
}
