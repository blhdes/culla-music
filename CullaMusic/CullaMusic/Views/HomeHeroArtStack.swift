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
    let sortOrder: SortOrder
    let modelContext: ModelContext
    /// Fires when the hero card's primary artwork is known — for source-picked
    /// modes that's the cached playlist/artist artwork, otherwise it's the
    /// first item from the freshly-fetched library/dismissed list. Used by
    /// HomeView to tint the ambient background to match the current preview.
    var onPrimaryArtworkResolved: ((Artwork?) -> Void)? = nil

    @Environment(\.appAccent) private var appAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Up to three artworks for the stack — [0] front, [1] left back, [2] right
    /// back. Empty for source-picked modes (the front uses PlaylistCoverView /
    /// ArtistHeroSquare instead) or while a fetch is in flight.
    @State private var artworks: [Artwork] = []
    @State private var frontFallbackKind: FallbackKind = .library
    @State private var pulse: Bool = false

    private let size: CGFloat = 168

    var body: some View {
        ZStack {
            backCard(
                artwork: backArtwork(at: 0),
                rotation: -8,
                offset: CGSize(width: -34, height: 8),
                opacity: 0.72
            )
            backCard(
                artwork: backArtwork(at: 1),
                rotation: 6,
                offset: CGSize(width: 32, height: 10),
                opacity: 0.85
            )
            frontCard
        }
        // `maxWidth: .infinity` pins the ZStack to whatever width the parent
        // proposes. Without it, the natural width is decided by the widest
        // child — and `ArtworkImage(width:height:)` doesn't reliably clamp
        // its layout size in iOS 26, so three stacked ArtworkImages were
        // inflating the parent VStack and pushing the rest of HomeView past
        // the screen edges (which is why the cards lost their margins).
        .frame(maxWidth: .infinity)
        .frame(height: size + 24)
        .task(id: stackKey) {
            await loadArtworks()
        }
        .onAppear { triggerPulse() }
        .onChange(of: stackKey) { _, _ in triggerPulse() }
    }

    /// Maps an index in `[0, 1]` (the two back-card slots) to an artwork from
    /// `artworks`. The pool starts at index 1 in song-mode (artworks[0] is the
    /// hero) and at index 0 in source-picked modes (the hero is rendered by
    /// PlaylistCoverView / ArtistHeroSquare, so artworks[0..1] feed the back).
    private func backArtwork(at slot: Int) -> Artwork? {
        let offset = (source == nil) ? 1 : 0
        let idx = offset + slot
        return idx < artworks.count ? artworks[idx] : nil
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
        if let front = artworks.first {
            ArtworkImage(front, width: size, height: size)
                .frame(width: size, height: size)
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

    /// Decorative card behind the hero. Shows the next sibling artwork when we
    /// have one (so the stack previews three songs in the user's sort order);
    /// falls back to pure glass when there's nothing to render — e.g. fewer
    /// than three dismissed songs, or a source-picked mode where the back
    /// cards are intentionally empty.
    private func backCard(
        artwork: Artwork?,
        rotation: Double,
        offset: CGSize,
        opacity: Double
    ) -> some View {
        let side = size - 18
        return Group {
            if let artwork {
                ArtworkImage(artwork, width: side, height: side)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.thinMaterial)
                    .frame(width: side, height: side)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                    )
            }
        }
        .opacity(opacity)
        .rotationEffect(.degrees(rotation))
        .offset(offset)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
    }

    // MARK: - State helpers

    /// A stable identity for the current selection. Drives `.task(id:)` so the
    /// loader restarts when *anything* about what we're previewing changes —
    /// including the user flipping the order toggle, which shuffles which
    /// three songs win the slots.
    private var stackKey: String {
        switch source {
        case .playlist(let id, _, _): return "\(mode.rawValue):\(sortOrder.rawValue):playlist:\(id)"
        case .artist(let id, _):      return "\(mode.rawValue):\(sortOrder.rawValue):artist:\(id)"
        case .none:                   return "\(mode.rawValue):\(sortOrder.rawValue):none"
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

    private func loadArtworks() async {
        frontFallbackKind = fallbackKind(for: mode, source: source)

        switch source {
        case .playlist(let id, _, _):
            // Hero is the playlist cover (rendered by PlaylistCoverView), so
            // we only need the next 2 track artworks for the back cards.
            artworks = await fetchPlaylistTrackArtworks(id: id, limit: 2)
            onPrimaryArtworkResolved?(MusicLibraryService.shared.artwork(forPlaylistID: id))
            return
        case .artist(let id, _):
            // Same idea — hero is the artist artwork; back cards preview the
            // first 2 songs by this artist in the user's sort order.
            artworks = await fetchArtistTrackArtworks(id: id, limit: 2)
            onPrimaryArtworkResolved?(MusicLibraryService.shared.artwork(forArtistID: id))
            return
        case .none:
            break
        }

        switch mode {
        case .library, .unsorted:
            artworks = await fetchLibraryArtworks(limit: 3)
        case .dismissed:
            artworks = await fetchRecentlyDismissedArtworks(limit: 3)
        }
        onPrimaryArtworkResolved?(artworks.first)
    }

    /// Fresh small library request — does not touch the swipe-session paging
    /// cursor. We ask for up to 3 items so the stack can show the next two
    /// covers behind the hero. Sort order matches the user's selected order
    /// so the preview is "the next songs you're about to see".
    private func fetchLibraryArtworks(limit: Int) async -> [Artwork] {
        do {
            var request = MusicLibraryRequest<Song>()
            request.limit = limit
            request.sort(by: \.libraryAddedDate, ascending: sortOrder.ascending)
            let response = try await request.response()
            return response.items.compactMap(\.artwork)
        } catch {
            return []
        }
    }

    /// Reads SwiftData for the most-recently dismissed songs, then fetches
    /// each artwork by ID in parallel. Direct filter (not `resolveSongs`) so
    /// we don't page through the whole library looking for matches.
    private func fetchRecentlyDismissedArtworks(limit: Int) async -> [Artwork] {
        var descriptor = FetchDescriptor<DismissedSong>(
            sortBy: [SortDescriptor(\.dismissedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        guard
            let dismissed = try? modelContext.fetch(descriptor),
            !dismissed.isEmpty
        else { return [] }

        // Parallel fetch keyed by index so we can put the results back in
        // dismissed-order — TaskGroup yields completions in any order.
        return await withTaskGroup(of: (Int, Artwork?).self) { group in
            for (idx, song) in dismissed.enumerated() {
                group.addTask {
                    do {
                        var request = MusicLibraryRequest<Song>()
                        request.filter(matching: \.id, equalTo: MusicItemID(song.songID))
                        let response = try await request.response()
                        return (idx, response.items.first?.artwork)
                    } catch {
                        return (idx, nil)
                    }
                }
            }
            var slots: [(Int, Artwork?)] = []
            for await pair in group { slots.append(pair) }
            return slots.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
    }

    /// Reads the first N tracks of a playlist without disturbing the swipe-
    /// session cursor (see MusicLibraryService.peekPlaylistTrackArtworks).
    /// Returns empty on failure so the back cards fall through to glass.
    private func fetchPlaylistTrackArtworks(id: String, limit: Int) async -> [Artwork] {
        do {
            return try await MusicLibraryService.shared.peekPlaylistTrackArtworks(
                playlistID: MusicItemID(id),
                limit: limit,
                ascending: sortOrder.ascending
            )
        } catch {
            return []
        }
    }

    /// Pulls the artist's library songs (already cached by the picker / by
    /// HomeView's count fetch) and returns the first N artworks in the user's
    /// sort order. Sort key is `libraryAddedDate` to match what the swipe
    /// walks — songs without a date sink to the end so dated ones lead.
    private func fetchArtistTrackArtworks(id: String, limit: Int) async -> [Artwork] {
        do {
            let songs = try await MusicLibraryService.shared.artistLibrarySongs(
                artistID: MusicItemID(id)
            )
            let ascending = sortOrder.ascending
            let sorted = songs.sorted { lhs, rhs in
                let l = lhs.libraryAddedDate ?? .distantPast
                let r = rhs.libraryAddedDate ?? .distantPast
                return ascending ? l < r : l > r
            }
            return sorted.prefix(limit).compactMap(\.artwork)
        } catch {
            return []
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
                    .frame(width: size, height: size)
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
