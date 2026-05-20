import SwiftUI
import SwiftData
import MusicKit

/// Hero preview shown above the mode tiles on HomeView. Renders a single
/// glass-framed artwork that previews what the user is about to swipe, with
/// two smaller decorative cards peeking behind it for depth.
///
/// The front card refetches whenever `mode`, `source`, or the playlist context
/// changes. Refetch is keyed via `.task(id:)` so SwiftUI cancels in-flight
/// fetches when the user flips modes quickly — no race, no stale artwork.
///
/// Source resolution per mode:
/// - `.library` + playlist source → the playlist's own cover
/// - `.library` + artist source   → the artist's library artwork (or initials)
/// - `.library` / `.unsorted`     → most-recently-added library song
/// - `.dismissed`                  → most-recently-dismissed song
struct HomeHeroArtStack: View {
    let mode: ReviewMode
    let source: SourceScope?
    let modelContext: ModelContext

    @Environment(\.appAccent) private var appAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var frontArtwork: Artwork?
    @State private var frontFallbackKind: FallbackKind = .library
    @State private var pulse: Bool = false

    private let size: CGFloat = 168

    var body: some View {
        ZStack {
            backCard(rotation: -8, offset: CGSize(width: -34, height: 8), opacity: 0.55)
            backCard(rotation: 6, offset: CGSize(width: 32, height: 10), opacity: 0.7)
            frontCard
        }
        .frame(height: size + 24)
        .task(id: stackKey) {
            await loadFront()
        }
        .onAppear { triggerPulse() }
        .onChange(of: stackKey) { _, _ in triggerPulse() }
    }

    // MARK: - Subviews

    /// The hero card. Uses the per-source view when we have one (PlaylistCover,
    /// ArtistThumbnail) so we don't refetch artwork the rest of the app already
    /// has cached. Falls back to `frontArtwork` (a Song's artwork loaded async)
    /// otherwise.
    private var frontCard: some View {
        Group {
            switch source {
            case .playlist(let id, _, _):
                PlaylistCoverView(appleMusicPlaylistID: id, size: size, cornerRadius: 22)
            case .artist(let id, let name):
                ArtistHeroSquare(artistID: id, artistName: name, size: size)
            case .none:
                songArtworkCard
            }
        }
        .shadow(color: appAccent.opacity(0.35), radius: pulse ? 28 : 16, y: 12)
        .scaleEffect(pulse ? 1.0 : 0.96)
        .animation(.spring(response: 0.55, dampingFraction: 0.7), value: pulse)
        .id(stackKey) // forces a fade-swap when the key changes
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    @ViewBuilder
    private var songArtworkCard: some View {
        if let frontArtwork {
            ArtworkImage(frontArtwork, width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                )
        } else {
            placeholderCard
        }
    }

    /// Empty/loading state — also covers the "no songs left" case for .dismissed
    /// when the user has never dismissed anything. Uses the mode's SF symbol so
    /// the surface still telegraphs what's coming.
    private var placeholderCard: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.thinMaterial)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: frontFallbackKind.symbol)
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
    }

    /// Decorative card behind the hero — pure glass, no artwork. Two of these
    /// give the front card a sense of depth without paying for more fetches.
    private func backCard(rotation: Double, offset: CGSize, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.thinMaterial)
            .frame(width: size - 18, height: size - 18)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
            .opacity(opacity)
            .rotationEffect(.degrees(rotation))
            .offset(offset)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
    }

    // MARK: - State helpers

    /// A stable identity for the current selection. Drives `.task(id:)` so the
    /// loader restarts when *anything* about what we're previewing changes.
    private var stackKey: String {
        switch source {
        case .playlist(let id, _, _): return "\(mode.rawValue):playlist:\(id)"
        case .artist(let id, _):      return "\(mode.rawValue):artist:\(id)"
        case .none:                   return "\(mode.rawValue):none"
        }
    }

    private func triggerPulse() {
        guard !reduceMotion else { pulse = true; return }
        pulse = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) {
                pulse = true
            }
        }
    }

    // MARK: - Fetch

    private func loadFront() async {
        frontFallbackKind = fallbackKind(for: mode, source: source)

        switch source {
        case .playlist, .artist:
            // Per-source views render directly from cached artwork — no async
            // fetch needed. Clear `frontArtwork` so a previous song's artwork
            // doesn't briefly bleed through.
            frontArtwork = nil
            return

        case .none:
            break
        }

        switch mode {
        case .library, .unsorted:
            frontArtwork = await fetchNewestLibraryArtwork()
        case .dismissed:
            frontArtwork = await fetchMostRecentlyDismissedArtwork()
        }
    }

    /// Fresh single-item library request — does not touch the swipe-session
    /// paging cursor. Cheap (one item) and gracefully returns nil on failure
    /// so the placeholder card takes over.
    private func fetchNewestLibraryArtwork() async -> Artwork? {
        do {
            var request = MusicLibraryRequest<Song>()
            request.limit = 1
            request.sort(by: \.libraryAddedDate, ascending: false)
            let response = try await request.response()
            return response.items.first?.artwork
        } catch {
            return nil
        }
    }

    /// Reads SwiftData for the most-recently dismissed song, then fetches its
    /// Song directly by ID. Direct filter (not `resolveSongs`) so we don't
    /// page through the whole library looking for one match.
    private func fetchMostRecentlyDismissedArtwork() async -> Artwork? {
        var descriptor = FetchDescriptor<DismissedSong>(
            sortBy: [SortDescriptor(\.dismissedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let dismissed = try? modelContext.fetch(descriptor).first else { return nil }
        do {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: MusicItemID(dismissed.songID))
            let response = try await request.response()
            return response.items.first?.artwork
        } catch {
            return nil
        }
    }

    private func fallbackKind(for mode: ReviewMode, source: SourceScope?) -> FallbackKind {
        if case .artist = source { return .artist }
        if case .playlist = source { return .playlist }
        switch mode {
        case .library:   return .library
        case .unsorted:  return .unsorted
        case .dismissed: return .dismissed
        }
    }

    private enum FallbackKind {
        case library, unsorted, dismissed, playlist, artist

        var symbol: String {
            switch self {
            case .library:   "music.note"
            case .unsorted:  "tray.full"
            case .dismissed: "archivebox"
            case .playlist:  "music.note.list"
            case .artist:    "person.fill"
            }
        }
    }
}

// MARK: - ArtistHeroSquare

/// Big rounded-square version of the artist thumbnail. We keep this local
/// (rather than parameterizing the existing `ArtistThumbnail` which is private
/// to HomeView) because the hero needs a square + initials at large size, and
/// the small circular thumbnail in the source pill has different proportions.
private struct ArtistHeroSquare: View {
    let artistID: String
    let artistName: String
    let size: CGFloat

    @Environment(\.appAccent) private var appAccent

    var body: some View {
        Group {
            if let artwork = MusicLibraryService.shared.artwork(forArtistID: artistID) {
                ArtworkImage(artwork, width: size, height: size)
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(LinearGradient(
                colors: [appAccent.opacity(0.6), appAccent.opacity(0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            )
    }

    private var initials: String {
        let parts = artistName.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}
