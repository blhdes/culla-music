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
    /// Fires when the user taps the hero — only in the scrub-deck branch
    /// (`source == nil` with artworks loaded). Used by HomeView to open the
    /// full carousel exploration screen. Sourced stacks (playlist / artist)
    /// route through their own UIs and don't trigger this.
    var onHeroTap: (() -> Void)? = nil
    /// Apple Music song-id of the last cover the user centred inside the
    /// carousel exploration screen. When set, the scrub deck prepends that
    /// song's artwork at position 0 so the hero reflects "where you left
    /// off." `nil` falls back to the default mode-sorted deck. Ignored for
    /// playlist/artist sources — those modes have their own portrait.
    var preferredFrontSongID: String? = nil

    @Environment(\.appAccent) private var appAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Mode-sorted, exclusion-filtered deck. In source-picked modes this is
    /// the two back-card artworks (the hero itself is PlaylistCoverView /
    /// ArtistHeroSquare). In source == nil modes this is the scrubbable fan,
    /// minus any prepended `leadArtwork`. Filter logic lives in
    /// `MusicLibraryService.deckExclusionSet` so the carousel and the hero
    /// can't drift on what counts as "next song."
    @State private var deckArtworks: [Artwork] = []
    /// Lead artwork prepended at slot 0 when the user has a "where you left
    /// off" cover from the carousel. Held separately from `deckArtworks` so a
    /// carousel-close event doesn't force a full library re-walk — only the
    /// lead refetches.
    @State private var leadArtwork: Artwork? = nil
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
            including: (source == nil && !combinedArtworks.isEmpty) ? .gesture : .subviews
        )
        // Tap (without a drag — DragGesture's minimumDistance keeps them
        // distinct) opens the full carousel exploration. Gated to source-less
        // modes with a loaded deck because sourced stacks have their own UIs
        // and an empty deck has nothing to navigate to.
        .onTapGesture {
            if source == nil, !combinedArtworks.isEmpty {
                onHeroTap?()
            }
        }
        // Two parallel tasks instead of one — splitting lets a carousel-close
        // event (which only changes `leadKey`) refresh the lead without
        // re-walking the library. When both keys change at once (mode swap,
        // which also clears the lead via HomeView), SwiftUI runs both
        // concurrently, so the deck refetch and lead clear overlap.
        .task(id: deckKey) {
            dragX = 0
            await loadDeck()
        }
        .task(id: leadKey) {
            await updateLead()
        }
        .onAppear { triggerPulse() }
        // Note: deliberately NOT re-triggering pulse on deck/lead changes.
        // The pulse is the hero's *entrance* — it should play once per
        // appearance, not every time the user flips a mode tile. Mode
        // swaps are content updates, not arrivals.
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
        // Compute once per body call (cheap 5-element array) instead of
        // letting ForEach call the computed property per-iteration.
        let cards = combinedArtworks
        if cards.isEmpty {
            placeholderCard
                .shadow(color: .black.opacity(0.22), radius: 18, y: 12)
                .scaleEffect(pulse ? 1.0 : 0.96)
                .animation(.spring(response: 0.55, dampingFraction: 0.7), value: pulse)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else {
            ZStack {
                ForEach(0..<min(cards.count, 5), id: \.self) { idx in
                    let layout = scrubLayout(for: idx)
                    scrubCard(artwork: cards[idx], layout: layout)
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
    private static let centreSlot      = ScrubLayout(offset: CGSize(width:    0, height:  0), scale: 1.00, rotation:   0, opacity: 1.0)
    private static let nearRightSlot   = ScrubLayout(offset: CGSize(width:   32, height: 10), scale: 0.92, rotation:   6, opacity: 0.85)
    private static let nearLeftSlot    = ScrubLayout(offset: CGSize(width:  -34, height:  8), scale: 0.92, rotation:  -8, opacity: 0.78)
    private static let spreadRightSlot = ScrubLayout(offset: CGSize(width:   92, height: 14), scale: 0.83, rotation:  10, opacity: 0.88)
    private static let spreadLeftSlot  = ScrubLayout(offset: CGSize(width:  -94, height: 12), scale: 0.83, rotation: -12, opacity: 0.88)
    private static let offRightSlot    = ScrubLayout(offset: CGSize(width:  240, height: 18), scale: 0.78, rotation:  16, opacity: 0.0)
    private static let offLeftSlot     = ScrubLayout(offset: CGSize(width: -242, height: 16), scale: 0.78, rotation: -18, opacity: 0.0)

    /// Renders one card with the layout values resolved for the current
    /// drag. All cards render at the same base size; scale is what makes a
    /// card read as "front" or "back". Shadow strength tracks scale too, so
    /// whichever card is currently closest to the centre carries the deeper
    /// shadow and the bigger lift — that's how the focus visibly shifts to
    /// whichever cover the user has dragged to the middle.
    private func scrubCard(artwork: Artwork, layout: ScrubLayout) -> some View {
        // Continuous "centre-ness": 1.0 at the centre slot's scale, fading
        // to 0 as the card shrinks toward the side scales. Used to scale
        // the plain depth shadow up as the user drags a new cover into
        // focus.
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
            // Neutral depth shadow whose strength rides `centreness`; the
            // centre card sits slightly higher off the page while off-centre
            // cards flatten toward the background. No accent tint — the
            // artwork and the artwork-keyed ambient glow carry all the colour.
            .shadow(
                color: .black.opacity(0.18 + 0.10 * centreness),
                radius: 14 + 6 * centreness,
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

    /// Resolved render values for one card in the scrub deck. Stacking order
    /// is derived from `scale` at the call site (line 161) so the focus card
    /// is always on top — no separate zIndex needed.
    private struct ScrubLayout {
        let offset: CGSize
        let scale: CGFloat
        let rotation: Double
        let opacity: Double

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
                opacity: a.opacity + (b.opacity - a.opacity) * tt
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
        // Playlist back cards come from the deck (lead never applies to
        // sourced stacks — `leadKey` returns "no-lead" for non-nil source).
        ZStack {
            if case .playlist = source {
                sourcedBackCard(
                    artwork: deckArtworks.indices.contains(0) ? deckArtworks[0] : nil,
                    rotation: -8,
                    offset: CGSize(width: -34, height: 8),
                    opacity: 0.72
                )
                sourcedBackCard(
                    artwork: deckArtworks.indices.contains(1) ? deckArtworks[1] : nil,
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
        .shadow(color: .black.opacity(0.22), radius: 18, y: 12)
        .scaleEffect(pulse ? 1.0 : 0.96)
        .animation(.spring(response: 0.55, dampingFraction: 0.7), value: pulse)
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

    /// Combined deck = optional lead + deck artworks, capped at `deckCapacity`.
    /// Computed (not cached) because the inputs are tiny — a 5-element array
    /// allocation per body call. Always derived from `leadArtwork` +
    /// `deckArtworks` so the two stay in lockstep without a sync bookkeeping
    /// surface.
    private var combinedArtworks: [Artwork] {
        guard let lead = leadArtwork else { return deckArtworks }
        var combined = [lead] + deckArtworks
        if combined.count > deckCapacity {
            combined.removeLast(combined.count - deckCapacity)
        }
        return combined
    }

    /// Identity for `.task(id:)` on the deck reload. Changes when the *source*
    /// of the deck changes — mode, sort, or the picked playlist/artist. Stable
    /// across carousel close events: those only affect `leadKey`, so closing
    /// the carousel at a new song no longer triggers a full library walk.
    private var deckKey: String {
        switch source {
        case .playlist(let id, _, _): return "\(mode.rawValue):\(sortOrder.rawValue):playlist:\(id)"
        case .artist(let id, _):      return "\(mode.rawValue):\(sortOrder.rawValue):artist:\(id)"
        case .none:                   return "\(mode.rawValue):\(sortOrder.rawValue):none"
        }
    }

    /// Identity for `.task(id:)` on the lead artwork. Folding `source` in
    /// forces the lead to clear when the user picks a source (sourced stacks
    /// render the source as the hero, not a "where you left off" cover).
    private var leadKey: String {
        switch source {
        case .playlist, .artist: return "no-lead"
        case .none:              return preferredFrontSongID ?? ""
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

    /// Refreshes the deck only. The lead is held separately via `updateLead`,
    /// so closing the carousel at a new song doesn't re-enter this function
    /// (which would re-walk the library on every carousel close).
    ///
    /// Every `await` below is guarded by `Task.isCancelled` before any
    /// `@State` mutation or callback. `.task(id: deckKey)` cancels the
    /// previous task when the key changes, but the awaited MusicKit /
    /// SwiftData calls may still resume with a result after that — without
    /// these guards the stale result would clobber the new task's
    /// `deckArtworks` (and tint the ambient background to the wrong cover
    /// via `onPrimaryArtworkResolved`).
    private func loadDeck() async {
        frontFallbackKind = fallbackKind(for: mode, source: source)

        switch source {
        case .playlist(let id, _, _):
            // Hero is the playlist cover (PlaylistCoverView), so the deck is
            // just the next 2 track artworks for the back cards.
            let result = await fetchPlaylistTrackArtworks(id: id, limit: 2)
            if Task.isCancelled { return }
            withAnimation(.smooth(duration: 0.3)) { deckArtworks = result }
            publishPrimaryArtwork()
            return
        case .artist:
            // Artist hero is a solo card — no back cards to fill, so the
            // deck stays empty. Ambient tint comes from the cached artist
            // artwork via `publishPrimaryArtwork`.
            if Task.isCancelled { return }
            withAnimation(.smooth(duration: 0.3)) { deckArtworks = [] }
            publishPrimaryArtwork()
            return
        case .none:
            break
        }

        let result: [Artwork]
        switch mode {
        case .library, .unsorted:
            // Mode-aware exclusion — before this, the hero ran an unfiltered
            // library request and could surface a song the carousel had
            // already excluded (`sorted`/`dismissed` in .library;
            // playlists+sorted+dismissed in .unsorted). The shared
            // `deckExclusionSet` is now the single source of truth.
            result = await fetchUnexcludedLibraryArtworks(limit: deckCapacity, mode: mode)
        case .dismissed:
            result = await fetchRecentlyDismissedArtworks(limit: deckCapacity)
        }
        if Task.isCancelled { return }

        withAnimation(.smooth(duration: 0.3)) { deckArtworks = result }
        publishPrimaryArtwork()
    }

    /// Refreshes the lead artwork only. Driven by `preferredFrontSongID`
    /// changes — typically when the user closes the carousel at a new song.
    /// Sourced stacks (playlist/artist) ignore the lead entirely; we clear
    /// any stale value when a source is picked so nothing leaks across the
    /// none ↔ sourced boundary.
    private func updateLead() async {
        guard source == nil, let preferredFrontSongID else {
            if leadArtwork != nil {
                withAnimation(.smooth(duration: 0.3)) { leadArtwork = nil }
                publishPrimaryArtwork()
            }
            return
        }
        let lead = await fetchSongArtwork(id: preferredFrontSongID)
        if Task.isCancelled { return }
        withAnimation(.smooth(duration: 0.3)) { leadArtwork = lead }
        publishPrimaryArtwork()
    }

    /// Reports the hero's "first visible" artwork up to HomeView so the
    /// ambient background can tint to match. Sourced modes prefer the cached
    /// playlist/artist artwork; source == nil falls through to lead ?? deck.
    /// Called from both `loadDeck` and `updateLead` so whichever finishes
    /// last writes the up-to-date value.
    private func publishPrimaryArtwork() {
        switch source {
        case .playlist(let id, _, _):
            onPrimaryArtworkResolved?(MusicLibraryService.shared.artwork(forPlaylistID: id))
        case .artist(let id, _):
            onPrimaryArtworkResolved?(MusicLibraryService.shared.artwork(forArtistID: id))
        case .none:
            onPrimaryArtworkResolved?(leadArtwork ?? deckArtworks.first)
        }
    }

    /// Direct single-song artwork fetch. Used to resolve the carousel's
    /// last-centred song for the hero's front card. One round-trip — the
    /// `\.id, equalTo:` filter is much cheaper than `resolveSongs([id])`,
    /// which pages the entire library matching against the set.
    private func fetchSongArtwork(id: String) async -> Artwork? {
        do {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: MusicItemID(id))
            let response = try await request.response()
            return response.items.first?.artwork
        } catch {
            return nil
        }
    }

    /// Pages the library (sorted to match the user's `sortOrder`), skipping
    /// anything in the mode's exclusion set, until we have `limit` artworks
    /// or the library is exhausted. The carousel uses the same exclusion via
    /// `CarouselSongFeed`, so the first cover here matches the first cover
    /// in the carousel — before this, the hero could surface already-sorted
    /// or already-dismissed songs that the carousel skipped.
    private func fetchUnexcludedLibraryArtworks(limit: Int, mode: ReviewMode) async -> [Artwork] {
        let exclusion = await MusicLibraryService.shared.deckExclusionSet(
            for: mode,
            modelContext: modelContext
        )
        if Task.isCancelled { return [] }

        var collected: [Artwork] = []
        var offset = 0
        let pageSize = 100
        do {
            while collected.count < limit {
                try Task.checkCancellation()
                var request = MusicLibraryRequest<Song>()
                request.limit = pageSize
                request.offset = offset
                request.sort(by: \.libraryAddedDate, ascending: sortOrder.ascending)
                let response = try await request.response()
                let page = response.items
                if page.isEmpty { break }
                for song in page where !exclusion.contains(song.id.rawValue) {
                    if let art = song.artwork {
                        collected.append(art)
                        if collected.count >= limit { break }
                    }
                }
                offset += page.count
                if page.count < pageSize { break }
            }
        } catch is CancellationError {
            return []
        } catch {
            print("HomeHeroArtStack fetchUnexcluded failed: \(error)")
        }
        return collected
    }

    /// Reads SwiftData for dismissed songs in the user's chosen order, then
    /// fetches each artwork by ID in parallel. Direct filter (not
    /// `resolveSongs`) so we don't page through the whole library looking
    /// for matches. The order MUST track `sortOrder.ascending` so the
    /// hero stack and the dismissed carousel show the same song first —
    /// otherwise oldest-first surfaces different covers on each surface.
    private func fetchRecentlyDismissedArtworks(limit: Int) async -> [Artwork] {
        var descriptor = FetchDescriptor<DismissedSong>(
            sortBy: [SortDescriptor(
                \.dismissedAt,
                order: sortOrder.ascending ? .forward : .reverse
            )]
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
