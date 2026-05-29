import SwiftUI

/// Single branded loading state, shown while the song→artist resolution (root
/// sheet) and the topSongs/similarArtists fetch (root + every pushed artist)
/// are in flight. Used in BOTH the outer `ArtistDetailSheet` and the reused
/// inner `ArtistDetailView`, so the placeholder stays continuous across the
/// resolve → detail handoff and on every similar-artist push.
///
/// It's a content-shaped skeleton, not a centered spinner: the hero placeholder
/// is **top-aligned** so it lands exactly where the real hero will, and the
/// already-known artist name renders solid below it. Shimmering song-row
/// placeholders telegraph the Top Songs list that's coming. On reveal the real
/// `content` crossfades in over the same geometry — the hero resolves in place
/// instead of sliding up from center.
struct ArtistLoadingView: View {
    let name: String

    /// Varied widths so the song-row text bars don't read as a rigid grid.
    private let titleWidths: [CGFloat] = [180, 132, 156, 104]
    private let subtitleWidths: [CGFloat] = [110, 84, 96, 70]

    var body: some View {
        VStack(spacing: 28) {
            heroPlaceholder
                .padding(.horizontal, 20)
            topSongsSkeleton
        }
        .padding(.vertical, 20)
        // Top-aligned so the hero matches the real sheet's top-anchored layout;
        // the centered version slid the hero upward on reveal.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var heroPlaceholder: some View {
        VStack(spacing: 16) {
            SkeletonShape(shape: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .frame(width: 220, height: 220)
                .overlay(
                    Image(systemName: "music.mic")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.secondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )

            // The name is known up front, so it renders as finished content —
            // no shimmer. Only the unresolved artwork/songs get the bone treatment.
            Text(name)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .multilineTextAlignment(.center)
        }
    }

    private var topSongsSkeleton: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { index in
                songRow(index: index)
                if index < 3 {
                    Divider().padding(.leading, 76)
                }
            }
        }
    }

    /// Mirrors `TopSongRow`'s geometry: 44pt artwork, two stacked text bars,
    /// 20pt side / 10pt vertical padding — so the rows reveal in place.
    private func songRow(index: Int) -> some View {
        HStack(spacing: 12) {
            SkeletonShape(shape: RoundedRectangle(cornerRadius: 6))
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 6) {
                SkeletonShape(shape: Capsule())
                    .frame(width: titleWidths[index], height: 11)
                SkeletonShape(shape: Capsule())
                    .frame(width: subtitleWidths[index], height: 9)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

#Preview {
    ArtistLoadingView(name: "Caroline Polachek")
}
