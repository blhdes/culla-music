import SwiftUI
import SwiftData
import MusicKit

/// Hero preview shown above the mode tiles on HomeView. Renders a glass-framed
/// artwork that previews what the user is about to swipe.
///
/// Two modes of presentation, depending on `source`:
///
/// - **source == nil** (library / unsorted / dismissed): the stack becomes a
///   horizontal fan of the next few covers. The user can drag a single
///   continuous gesture across the screen to scrub through them; letting go
///   springs everything back to the first cover. It's a one-journey peek —
///   no commit, no "swipe again to see the next one", just a finger across
///   the screen to glance ahead.
///
/// - **source != nil** (playlist / artist picked): the hero is locked to the
///   source's cover. No scrub gesture — the hero IS the source, there's
///   nothing to cycle. Playlists keep two static decorative cards behind the
///   front cover; artists render as a single solo card because the artist
///   profile reads as its own portrait without a deck behind it.
///
/// Source resolution per mode:
/// - `.library` + playlist source → the playlist's own cover
/// - `.library` + artist source   → the artist's library artwork (or initials)
/// - `.library` / `.unsorted`     → most-recently-added library songs
/// - `.dismissed`                  → most-recently-dismissed songs
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

    /// Pool of preview artworks. In source-picked modes this feeds the two
    /// back cards (the hero is rendered by PlaylistCoverView /
    /// ArtistHeroSquare). In source == nil modes this is the full scrubbable
    /// fan — each artwork is one card in the deck.
    @State private var artworks: [Artwork] = []
    @State private var frontFallbackKind: FallbackKind = .library
    @State private var pulse: Bool = false
    /// Live horizontal drag translation for the scrub gesture (source == nil
    /// only). Negative values pull the deck leftwards to reveal later covers;
    /// lifting the finger springs this back to 0 so the first cover returns
    /// to the front. Always 0 in source-picked modes.
    @State private var dragX: CGFloat = 0
    /// Axis lock for the scrub gesture. The first tick past `minimumDistance`
    /// picks `.horizontal` or `.ignored` from the dominant translation axis;
    /// subsequent ticks honor that lock for the rest of the gesture so a
    /// mid-drag vertical drift can't freeze the deck halfway through a scrub.
    /// `.onEnded` resets to `.undecided`.
    @State private var dragAxis: DragAxis = .undecided

    private enum DragAxis { case undecided, horizontal, ignored }

    private let size: CGFloat = 168
    /// Library/dismissed deck holds up to this many covers — the rest state
    /// shows the first three balanced (centre + near-left + near-right);
    /// the last two live off-screen and slide in when the user drags in
    /// their direction. Anything past 5 is loaded but not rendered.
    private let deckCapacity: Int = 5
    /// Drag distance per stage in the scrub. Stage 1 (`0 → revealDistance`)
    /// pulls the near-side rest peek to centre; stage 2 (`revealDistance →
    /// 2 × revealDistance`) pulls the newcomer all the way to centre. So the
    /// total drag to fully reveal a newcomer is `2 × revealDistance`. Sized
    /// so even stage 2 lands well within a single thumb sweep — earlier 120pt
    /// made the newcomer's centring need ~240pt, almost full screen width.
    /// Past the second stage the gesture rubber-bands so the user feels the
    /// end of the deck without an abrupt stop.
    private let revealDistance: CGFloat = 80

    var body: some View {
        ZStack {
            if source == nil {
                scrubDeck
            } else {
                sourcedStack
            }
        }
        // Pin to parent width so the surrounding VStack sizes itself to the
        // screen instead of shrinking to the natural width of the small
        // overlapping cards (which would push the horizontally-padded rows
        // below off-center).
        .frame(maxWidth: .infinity)
        .frame(height: size + 24)
        // Hit-test the whole section, not just the centred card silhouette,
        // so the scrub can start from the empty flanks too. The
        // `including:` mask disables the gesture entirely when the scrub
        // doesn't apply (sourced modes, empty-deck loading state), which
        // matches the prior behavior where the gesture only lived inside
        // the cards branch of `scrubDeck`.
        .contentShape(Rectangle())
        .gesture(
            scrubGesture,
            including: (source == nil && !artworks.isEmpty) ? .gesture : .subviews
        )
        .task(id: fetchKey) {
            dragX = 0
            await loadArtworks()
        }
        .onAppear { triggerPulse() }
        .onChange(of: fetchKey) { _, _ in triggerPulse() }
    }

    // MARK: - Scrub deck (source == nil)

    /// Bidirectional peek-deck.
    ///
    /// Rest state is the original balanced pile: card 0 centred, card 1
    /// peeking on the right, card 2 peeking on the left. Cards 3 and 4 live
    /// off-screen and only slide in when the user drags toward their side
    /// (right drag reveals 3, left drag reveals 4). Lifting the finger
    /// springs `dragX` back to zero so the rest state returns.
    @ViewBuilder
    private var scrubDeck: some View {
        if artworks.isEmpty {
            placeholderCard
                .shadow(color: appAccent.opacity(0.35), radius: pulse ? 28 : 16, y: 12)
                .scaleEffect(pulse ? 1.0 : 0.96)
                .animation(.spring(response: 0.55, dampingFraction: 0.7), value: pulse)
                .id(fetchKey)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else {
            ZStack {
                ForEach(0..<min(artworks.count, 5), id: \.self) { idx in
                    let layout = scrubLayout(for: idx)
                    scrubCard(artwork: artworks[idx], layout: layout)
                        // Scale-based stacking: whichever card is currently
                        // closest to the centre slot sits on top, and every
                        // peeking card — whether a rest back (slot 1 / 2) or
                        // a newcomer (slot 3 / 4) — sits behind it the same
                        // way. Keeps the "centre on top, sides peeking from
                        // behind" relationship consistent throughout the drag.
                        .zIndex(Double(layout.scale))
                }
            }
            .scaleEffect(pulse ? 1.0 : 0.96)
            .animation(.spring(response: 0.55, dampingFraction: 0.7), value: pulse)
            .id(fetchKey)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    /// Layout for one card in the bidirectional peek deck. Five named slots
    /// that every card can be at — `centre`, `nearRight`, `nearLeft`,
    /// `offRight` (hidden right), `offLeft` (hidden left). Each card has a
    /// rest slot plus a destination for each drag direction, and we
    /// linearly interpolate between rest and destination as the drag
    /// progresses. The result: at full right-drag the deck has fully
    /// rotated one position rightwards (card 1 is the new centre, card 3
    /// has slid in as the new right peek, card 0 has moved to the left
    /// peek). At full left-drag the mirror is true. Lifting the finger
    /// springs `dragX` to zero, restoring the rest pile.
    private func scrubLayout(for slot: Int) -> ScrubLayout {
        // Each card sits at a fixed virtual position in a linear sequence,
        // left to right: card 4 (-2), card 2 (-1), card 0 (0), card 1 (+1),
        // card 3 (+2). Dragging shifts every card's virtual position by
        // `dragX / revealDistance`, so each card scrubs through every
        // visible slot in turn — passing through centre when the drag
        // arrives at it. No per-slot special cases: every card runs the
        // same layout function, so the newcomers behave identically to
        // the initial three.
        guard slot < Self.restPositions.count else { return Self.centreSlot }
        let virtualPos = Self.restPositions[slot] - dragX / revealDistance
        return layoutAtVirtualPosition(virtualPos)
    }

    /// Rest virtual positions indexed by `slot`. Hoisted to `static let` so the
    /// scrub gesture's 60Hz body re-evaluations don't allocate a fresh array
    /// per card per tick.
    private static let restPositions: [CGFloat] = [0, 1, -1, 2, -2]

    /// Maps a continuous virtual position to the rendered card layout.
    /// Waypoints: 0 = centre, ±1 = near peek, ±1.5 = spread peek,
    /// ±2+ = off-screen. The spread peek sits between near and off so
    /// cards at rest virtual position ±2 (i.e. the newcomers) are
    /// naturally off-screen — no opacity hack required to keep the rest
    /// pile reading as three cards.
    private func layoutAtVirtualPosition(_ v: CGFloat) -> ScrubLayout {
        let absV = abs(v)
        let rightSide = v >= 0
        let nearSlot   = rightSide ? Self.nearRightSlot   : Self.nearLeftSlot
        let spreadSlot = rightSide ? Self.spreadRightSlot : Self.spreadLeftSlot
        let offSlot    = rightSide ? Self.offRightSlot    : Self.offLeftSlot

        if absV >= 2.0 { return offSlot }
        if absV >= 1.5 { return ScrubLayout.lerp(from: spreadSlot,  to: offSlot,    t: (absV - 1.5) * 2) }
        if absV >= 1.0 { return ScrubLayout.lerp(from: nearSlot,    to: spreadSlot, t: (absV - 1.0) * 2) }
        return            ScrubLayout.lerp(from: Self.centreSlot,   to: nearSlot,   t: absV)
    }

    // The named slots a card can occupy.
    //
    // - `centre` / `nearRight` / `nearLeft` define the rest pile (the
    //   balanced 3-card look the user wanted preserved).
    // - `spreadRight` / `spreadLeft` are the *during-drag* peek positions
    //   — wider apart than the rest near-slots so the newly-revealed card
    //   has space to actually be seen past the new centre's silhouette.
    // - `offRight` / `offLeft` are the off-screen hiding positions for
    //   cards 3 and 4 at rest, and for whichever side card is being
    //   shoved off during a drag in the opposite direction.
    private static let centreSlot      = ScrubLayout(offset: CGSize(width:    0, height:  0), scale: 1.00, rotation:   0, opacity: 1.0, zIndex: 0)
    private static let nearRightSlot   = ScrubLayout(offset: CGSize(width:   32, height: 10), scale: 0.92, rotation:   6, opacity: 0.85, zIndex: 0)
    private static let nearLeftSlot    = ScrubLayout(offset: CGSize(width:  -34, height:  8), scale: 0.92, rotation:  -8, opacity: 0.78, zIndex: 0)
    private static let spreadRightSlot = ScrubLayout(offset: CGSize(width:   92, height: 14), scale: 0.83, rotation:  10, opacity: 0.88, zIndex: 0)
    private static let spreadLeftSlot  = ScrubLayout(offset: CGSize(width:  -94, height: 12), scale: 0.83, rotation: -12, opacity: 0.88, zIndex: 0)
    private static let offRightSlot    = ScrubLayout(offset: CGSize(width:  240, height: 18), scale: 0.78, rotation:  16, opacity: 0.0,  zIndex: 0)
    private static let offLeftSlot     = ScrubLayout(offset: CGSize(width: -242, height: 16), scale: 0.78, rotation: -18, opacity: 0.0,  zIndex: 0)

    /// Renders one card with the layout values resolved for the current
    /// drag. All cards render at the same base size; scale is what makes a
    /// card read as "front" or "back". Shadow strength tracks scale too, so
    /// whichever card is currently closest to the centre carries the accent
    /// halo and the bigger lift — that's how the focus visibly shifts to
    /// whichever cover the user has dragged to the middle.
    private func scrubCard(artwork: Artwork, layout: ScrubLayout) -> some View {
        // Continuous "centre-ness": 1.0 at the centre slot's scale, fading
        // to 0 as the card shrinks toward the side scales. Used to blend
        // between the accent halo and the plain depth shadow as the user
        // drags a new cover into focus.
        let centreness = max(0, min(1, (layout.scale - 0.92) / (1.0 - 0.92)))

        return ArtworkImage(artwork, width: size, height: size)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.17), lineWidth: 1)
            )
            .scaleEffect(layout.scale)
            .rotationEffect(.degrees(layout.rotation))
            .offset(layout.offset)
            .opacity(layout.opacity)
            // Single accent halo whose strength rides `centreness`; off-centre
            // cards naturally fade to no shadow. Dropping the secondary depth
            // shadow that used to cross-fade in here halves the per-tick
            // offscreen-shadow renders without changing the focus-card halo.
            .shadow(
                color: appAccent.opacity(0.35 * centreness),
                radius: 16 + (pulse ? 12 : 0) * centreness,
                y: 6 + 6 * centreness
            )
    }

    /// Bidirectional scrub. The drag never commits — releasing always
    /// springs back to the rest state. The drag range spans two stages
    /// per direction: stage 1 (one `revealDistance`) brings the rest
    /// peek (card 1 or 2) to centre with the newcomer arriving at the
    /// spread slot; stage 2 (two `revealDistance`) brings the newcomer
    /// (card 3 or 4) all the way to centre. Past the second stage the
    /// gesture rubber-bands so the user feels the end of the deck.
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                // Pick an axis on the first tick past minimumDistance and keep
                // it for the rest of the gesture. Without this, a per-tick
                // dominant-axis check would freeze the deck mid-scrub the
                // moment vertical motion briefly outpaced horizontal — and
                // then resume when horizontal caught back up, reading to the
                // user as the gesture randomly cutting out.
                if dragAxis == .undecided {
                    dragAxis = abs(value.translation.width) >= abs(value.translation.height)
                        ? .horizontal
                        : .ignored
                }
                guard dragAxis == .horizontal else { return }

                let raw = value.translation.width
                let maxDrag = 2 * revealDistance
                let absRaw = abs(raw)
                if absRaw <= maxDrag {
                    dragX = raw
                } else {
                    let overshoot = absRaw - maxDrag
                    let damped = sqrt(overshoot) * 6
                    let sign: CGFloat = raw < 0 ? -1 : 1
                    dragX = sign * (maxDrag + min(50, damped))
                }
            }
            .onEnded { _ in
                dragAxis = .undecided
                withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
                    dragX = 0
                }
            }
    }

    /// Resolved render values for one card in the scrub deck.
    private struct ScrubLayout {
        let offset: CGSize
        let scale: CGFloat
        let rotation: Double
        let opacity: Double
        /// Reserved for future use — currently we derive stacking order
        /// from `scale` at the call site so it tracks the current focus.
        let zIndex: Double

        /// Linear interpolation between two slot layouts. `t` is the drag
        /// progress in [0, 1] toward the destination.
        static func lerp(from a: ScrubLayout, to b: ScrubLayout, t: CGFloat) -> ScrubLayout {
            let tt = Double(t)
            return ScrubLayout(
                offset: CGSize(
                    width: a.offset.width + (b.offset.width - a.offset.width) * t,
                    height: a.offset.height + (b.offset.height - a.offset.height) * t
                ),
                scale: a.scale + (b.scale - a.scale) * t,
                rotation: a.rotation + (b.rotation - a.rotation) * tt,
                opacity: a.opacity + (b.opacity - a.opacity) * tt,
                zIndex: a.zIndex + (b.zIndex - a.zIndex) * tt
            )
        }
    }

    // MARK: - Sourced stack (playlist / artist)

    /// Layout shown when the user has picked a specific playlist or artist as
    /// the source. The front card is the source's cover. Playlists render two
    /// static decorative back cards previewing the next two tracks; artists
    /// render solo since the profile portrait reads better without a deck
    /// behind it. No scrub here — the hero IS the source, there's no deck.
    private var sourcedStack: some View {
        ZStack {
            if case .playlist = source {
                sourcedBackCard(
                    artwork: artworks.indices.contains(0) ? artworks[0] : nil,
                    rotation: -8,
                    offset: CGSize(width: -34, height: 8),
                    opacity: 0.72
                )
                sourcedBackCard(
                    artwork: artworks.indices.contains(1) ? artworks[1] : nil,
                    rotation: 6,
                    offset: CGSize(width: 32, height: 10),
                    opacity: 0.85
                )
            }
            sourcedFrontCard
        }
    }

    private var sourcedFrontCard: some View {
        Group {
            switch source {
            case .playlist(let id, _, _):
                PlaylistCoverView(appleMusicPlaylistID: id, size: size, cornerRadius: 22)
            case .artist(let id, let name):
                ArtistHeroSquare(artistID: id, artistName: name, size: size)
            case .none:
                EmptyView() // unreachable — `sourcedStack` only renders with a source
            }
        }
        .shadow(color: appAccent.opacity(0.35), radius: pulse ? 28 : 16, y: 12)
        .scaleEffect(pulse ? 1.0 : 0.96)
        .animation(.spring(response: 0.55, dampingFraction: 0.7), value: pulse)
        .id(fetchKey)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    /// Decorative back card used only in source-picked stacks. Falls back to
    /// a glass placeholder when the source doesn't yield enough track
    /// artworks to fill the slot.
    private func sourcedBackCard(
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

    /// Empty/loading state. Used by the scrub deck before artworks land,
    /// and visually reused so the hero never goes blank during a swap.
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

    // MARK: - State helpers

    /// Identity used by `.task(id:)` to refetch artworks — refetches only
    /// when the deck *source* changes (mode, picked source, sort order).
    /// The continuous scrub does not change this key, so dragging never
    /// triggers a library re-hit.
    private var fetchKey: String {
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

        // Every `await` below is guarded by `Task.isCancelled` before any
        // @State mutation or callback. `.task(id: fetchKey)` cancels the
        // previous task when the key changes, but the awaited MusicKit /
        // SwiftData calls may still resume with a result after that — and
        // without these guards the stale result would clobber the new
        // task's `artworks` (and tint the ambient background to the wrong
        // cover via `onPrimaryArtworkResolved`).

        switch source {
        case .playlist(let id, _, _):
            // Hero is the playlist cover (rendered by PlaylistCoverView), so
            // we only need the next 2 track artworks for the back cards.
            let result = await fetchPlaylistTrackArtworks(id: id, limit: 2)
            if Task.isCancelled { return }
            artworks = result
            onPrimaryArtworkResolved?(MusicLibraryService.shared.artwork(forPlaylistID: id))
            return
        case .artist(let id, _):
            // Artist hero is a solo card — no back cards to fill, so we skip
            // the per-track artwork fetch entirely and just publish the
            // artist's cached artwork for the ambient tint.
            if Task.isCancelled { return }
            artworks = []
            onPrimaryArtworkResolved?(MusicLibraryService.shared.artwork(forArtistID: id))
            return
        case .none:
            break
        }

        let result: [Artwork]
        switch mode {
        case .library, .unsorted:
            result = await fetchLibraryArtworks(limit: deckCapacity)
        case .dismissed:
            result = await fetchRecentlyDismissedArtworks(limit: deckCapacity)
        }
        if Task.isCancelled { return }
        artworks = result
        // Ambient tint always follows the first cover — the scrub is a peek
        // that returns home, so the background colour shouldn't follow the
        // finger (would feel busy and jittery during the gesture).
        onPrimaryArtworkResolved?(result.first)
    }

    /// Fresh small library request — does not touch the swipe-session paging
    /// cursor. We ask for `deckCapacity` items so the user can peek through
    /// a few covers by dragging the front card. Sort order matches the
    /// user's selected order so the preview is "the next songs you're
    /// about to see".
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
