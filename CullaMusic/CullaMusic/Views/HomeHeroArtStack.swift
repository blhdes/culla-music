import SwiftUI
import SwiftData
import MusicKit

/// Hero preview shown above the mode tiles on HomeView. Renders a glass-framed
/// horizontal fan of the next few covers — a one-journey peek at what the user
/// is about to swipe. The user can drag a single continuous gesture across the
/// screen to scrub through them; letting go springs everything back to the
/// first cover. Tapping opens the full carousel exploration (`onHeroTap`). No
/// commit, no "swipe again to see the next one", just a finger across the
/// screen to glance ahead.
///
/// What fills the deck depends on the current source/mode:
/// - `source == nil`, `.library` / `.unsorted` → most-recently-added library songs
/// - `source == nil`, `.dismissed`              → most-recently-dismissed songs
/// - **playlist source** → the playlist's cover pinned on top (when it has one),
///   then the playlist's tracks behind it; no cover → the tracks scrub alone
/// - **artist source**   → the artist's photo pinned on top (when it has one),
///   then the artist's library tracks behind it; no photo → the tracks alone
///
/// The pinned source cover/photo rides the same `leadArtwork` slot the
/// "where you left off" feature uses, so the fan layout is identical across
/// every source — only what fills slot 0 differs.
struct HomeHeroArtStack: View {
    let mode: ReviewMode
    let source: SourceScope?
    let sortOrder: SortOrder
    let modelContext: ModelContext
    /// Whether dismissed tracks surface inside a scoped (playlist/artist) deck.
    /// Forwarded to `MusicLibraryService.scopeExclusionSet`; ignored when
    /// `source == nil` (those decks hide dismissals via `deckExclusionSet`).
    let includeDismissedInScope: Bool
    /// Fires when the hero card's primary artwork is known — the pinned lead
    /// (source cover / "where you left off") when present, otherwise the first
    /// cover in the deck. Used by HomeView to tint the ambient background to
    /// match the current preview.
    var onPrimaryArtworkResolved: ((Artwork?) -> Void)? = nil
    /// Fires when the user taps the hero (any source, once the deck has
    /// loaded). Used by HomeView to open the full carousel exploration screen.
    var onHeroTap: (() -> Void)? = nil
    /// Fires when the dismissed-deck load proves some `DismissedSong` rows are
    /// orphaned (their song was deleted from the library) and prunes them.
    /// HomeView uses it to recompute the mode-tile counts, so the Dismissed
    /// badge drops to the real number instead of counting phantom rows.
    var onDismissedOrphansPruned: (() -> Void)? = nil
    /// Apple Music song-id of the last cover the user centred inside the
    /// carousel exploration screen. When set, the scrub deck prepends that
    /// song's artwork at position 0 so the hero reflects "where you left
    /// off." `nil` falls back to the default mode-sorted deck. Ignored for
    /// playlist/artist sources — there the pinned lead is the source's own
    /// cover, which stays put regardless of where the carousel was left.
    var preferredFrontSongID: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Exclusion-filtered deck behind the lead — the scrubbable fan, minus any
    /// prepended `leadArtwork`. Unscoped modes fill it from the library /
    /// dismissed walks; scoped modes fill it with the playlist/artist tracks.
    /// Filter logic lives in `MusicLibraryService` (`deckExclusionSet` /
    /// `scopeExclusionSet`) so the carousel and the hero can't drift on what
    /// counts as "next song."
    @State private var deckArtworks: [Artwork] = []
    /// Lead artwork pinned at slot 0. Unscoped: the carousel's "where you left
    /// off" cover. Scoped: the playlist cover / artist photo. Held separately
    /// from `deckArtworks` so a carousel-close event doesn't force a full
    /// re-walk — only the lead refetches.
    @State private var leadArtwork: Artwork? = nil
    @State private var frontFallbackKind: FallbackKind = .library
    /// Flips true once `loadDeck` finishes a pass for the current `deckKey`.
    /// Without it, an empty result is indistinguishable from "still loading",
    /// so a mode whose deck resolves to zero covers (e.g. a Dismissed mode left
    /// holding only a stale, unresolvable row) shimmers its skeleton forever.
    /// Reset at the start of every load so a mode swap re-shows the skeleton.
    @State private var hasLoadedDeck: Bool = false
    @State private var pulse: Bool = false
    /// Live horizontal drag translation for the scrub gesture. Negative values
    /// pull the deck leftwards to reveal later covers; lifting the finger
    /// springs this back to 0 so the first cover returns to the front.
    @State private var dragX: CGFloat = 0
    /// Axis lock for the scrub gesture. The first tick past `minimumDistance`
    /// picks `.horizontal` or `.ignored` from the dominant translation axis;
    /// subsequent ticks honor that lock for the rest of the gesture so a
    /// mid-drag vertical drift can't freeze the deck halfway through a scrub.
    /// `.onEnded` resets to `.undecided`.
    @State private var dragAxis: DragAxis = .undecided

    private enum DragAxis { case undecided, horizontal, ignored }

    private let size: CGFloat = 168
    /// The deck holds up to this many covers — the rest state shows the first
    /// three balanced (centre + near-left + near-right); the last two live
    /// off-screen and slide in when the user drags in their direction.
    /// Anything past 5 is loaded but not rendered.
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
            scrubDeck
        }
        // Pin to parent width so the surrounding VStack sizes itself to the
        // screen instead of shrinking to the natural width of the small
        // overlapping cards (which would push the horizontally-padded rows
        // below off-center).
        .frame(maxWidth: .infinity)
        .frame(height: size + 24)
        // Hit-test the whole section, not just the centred card silhouette,
        // so the scrub can start from the empty flanks too. The `including:`
        // mask disables the gesture while the deck is empty (loading / nothing
        // to preview) so an empty card silhouette isn't draggable.
        .contentShape(Rectangle())
        .gesture(
            scrubGesture,
            including: hasArtworks ? .gesture : .subviews
        )
        // Tap (without a drag — DragGesture's minimumDistance keeps them
        // distinct) opens the full carousel exploration. Gated only by a
        // loaded deck now — every source (including playlist/artist) scrubs
        // and expands; an empty deck has nothing to navigate to.
        .onTapGesture {
            // In screenshot mode the tap would open the carousel — which still
            // renders real artwork — so suppress it; the neutral hero is the
            // whole point of the shot.
            if hasArtworks && !cullaScreenshotMode {
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

    // MARK: - Scrub deck

    /// Bidirectional peek-deck.
    ///
    /// Rest state is the original balanced pile: card 0 centred, card 1
    /// peeking on the right, card 2 peeking on the left. Cards 3 and 4 live
    /// off-screen and only slide in when the user drags toward their side
    /// (right drag reveals 3, left drag reveals 4). Lifting the finger
    /// springs `dragX` back to zero so the rest state returns.
    @ViewBuilder
    private var scrubDeck: some View {
        if cullaScreenshotMode {
            // Portfolio / App Store screenshots can't show real album artwork
            // (the Guideline 5.2.1 rejection that prompted this), so a
            // screenshot build renders a fan of code-generated neutral covers
            // instead. Same scrub layout, stacking, and entrance pulse as the
            // real deck — only the card contents differ.
            screenshotDeck
        } else {
            realScrubDeck
        }
    }

    /// The real deck: the user's actual covers (or the loading skeleton /
    /// settled-empty state). Split out from `scrubDeck` so `cullaScreenshotMode`
    /// can swap in the neutral covers without touching the gesture/tap wiring
    /// in `body`.
    @ViewBuilder
    private var realScrubDeck: some View {
        // Compute once per body call (cheap 5-element array) instead of
        // letting ForEach call the computed property per-iteration.
        let cards = combinedArtworks
        if cards.isEmpty {
            // Skeleton only while a load is genuinely in flight. Once the load
            // settles with nothing to show, fall through to a quiet empty card
            // so the hero stops shimmering over a deck that will never fill.
            Group {
                if hasLoadedDeck {
                    emptyDeckCard
                } else {
                    skeletonDeck
                }
            }
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
        scrubCard(layout: layout) {
            ArtworkImage(artwork, width: size, height: size)
        }
    }

    /// Continuous "centre-ness" of a card: 1.0 at the centre slot's scale,
    /// fading to 0 as the card shrinks toward the side scales. Drives the
    /// depth shadow in `scrubCard`, and in screenshot mode the brand mark's
    /// size/strength, so both track the drag the same way.
    private static func centreness(of layout: ScrubLayout) -> CGFloat {
        max(0, min(1, (layout.scale - 0.92) / (1.0 - 0.92)))
    }

    /// Shared card chrome around whatever fills a scrub slot — the frame,
    /// rounded clip, hairline border, the layout-driven
    /// scale/rotation/offset/opacity, and the centre-tracking depth shadow.
    /// Both the real `ArtworkImage` path and the `cullaScreenshotMode`
    /// neutral-cover path route through here, so the two decks scrub, stack,
    /// and cast shadows identically — only the inner content differs.
    private func scrubCard<Content: View>(
        layout: ScrubLayout,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let centreness = Self.centreness(of: layout)

        return content()
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

    // MARK: - Screenshot covers

    /// Fanned deck of neutral glass covers, shown when `cullaScreenshotMode`
    /// is on. Mirrors `realScrubDeck`'s non-empty branch (same `ForEach`,
    /// `scrubLayout`, `zIndex`, and entrance pulse) so the screenshot build is
    /// visually indistinguishable from the real hero apart from the card art —
    /// which here is Liquid Glass plus the Culla brand mark, carrying zero
    /// third-party copyright. The mark fades with depth (see
    /// `screenshotCover`), so the fan reads as a deck rather than one sticker
    /// repeated five times.
    private var screenshotDeck: some View {
        ZStack {
            ForEach(0..<deckCapacity, id: \.self) { idx in
                let layout = scrubLayout(for: idx)
                scrubCard(layout: layout) {
                    screenshotCover(centreness: Self.centreness(of: layout))
                }
                .zIndex(Double(layout.scale))
            }
        }
        .scaleEffect(pulse ? 1.0 : 0.96)
        .animation(.spring(response: 0.55, dampingFraction: 0.7), value: pulse)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    /// One neutral cover: clear Liquid Glass — the app's own `glassSurface`
    /// (real `glassEffect` on iOS 26, thin material below) — behind the Culla
    /// brand mark (`CullaLogo`, the official mark ported from
    /// `design/app-icon.svg`). The mark rides `centreness`: full-size,
    /// full-colour, and fully opaque on the centre card, then smaller, paler,
    /// and desaturated on the cards behind — the same depth cue the real
    /// deck gets from its shadows, expressed in the mark itself. The card
    /// still carries no colour of its own, so the ambient glow shows through
    /// the glass. Fills the card frame `scrubCard` applies, so it clips to
    /// the same rounded silhouette as a real cover.
    private func screenshotCover(centreness: CGFloat) -> some View {
        Color.clear
            .overlay {
                CullaLogo()
                    .frame(width: size * (0.38 + 0.12 * centreness))
                    .saturation(0.25 + 0.75 * Double(centreness))
                    .opacity(0.55 + 0.45 * Double(centreness))
            }
            .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Scrub gesture

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

    /// Resolved render values for one card in the scrub deck. The call site
    /// sets `.zIndex(layout.scale)`, so whichever card is largest (closest to
    /// centre) sits on top — no separate hand-tuned stacking index needed.
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

    /// Empty/loading state for the deck, shown before the album
    /// artworks land. Three shimmering bones laid out at the SAME rest slots
    /// the real covers occupy (`centreSlot` + the two near peeks), so when the
    /// art arrives it sharpens into this exact pile instead of a single
    /// placeholder popping into a three-card deck. Reuses `SkeletonShape` — the
    /// same coordinated shimmer the artist sheet's loading state uses — so
    /// loading reads identically across the app.
    private var skeletonDeck: some View {
        ZStack {
            skeletonCard(layout: Self.nearLeftSlot, isCentre: false)
            skeletonCard(layout: Self.nearRightSlot, isCentre: false)
            skeletonCard(layout: Self.centreSlot, isCentre: true)
        }
    }

    /// Shown when a deck finished loading but resolved to nothing — e.g. the
    /// only Dismissed row left is a stale record that no longer resolves to a
    /// song, or a scoped playlist whose every track is filtered out. A single
    /// quiet glass card with the mode's fallback symbol, deliberately NOT
    /// shimmering, so the hero reads as "nothing to preview" instead of looping
    /// a load that will never finish.
    private var emptyDeckCard: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.ultraThinMaterial)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: frontFallbackKind.symbol)
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    /// One bone in `skeletonDeck`, transformed to its rest slot. The centre
    /// bone keeps the mode's fallback symbol (`music.note` / `tray.full` /
    /// `archivebox`) as a quiet "what am I loading" hint; the back bones stay
    /// blank. Side bones are deliberately NOT dimmed to their slot opacity —
    /// keeping all three at full strength telegraphs the deck, and the real
    /// covers settle to their slot opacities on reveal.
    private func skeletonCard(layout: ScrubLayout, isCentre: Bool) -> some View {
        SkeletonShape(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(width: size, height: size)
            .overlay {
                if isCentre {
                    Image(systemName: frontFallbackKind.symbol)
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .scaleEffect(layout.scale)
            .rotationEffect(.degrees(layout.rotation))
            .offset(layout.offset)
            // Neutral depth shadow matching `scrubCard` — centre lifts, sides
            // flatten toward the page. No accent tint.
            .shadow(
                color: .black.opacity(isCentre ? 0.22 : 0.16),
                radius: isCentre ? 16 : 10,
                y: isCentre ? 10 : 6
            )
    }

    // MARK: - State helpers

    /// Cheap emptiness check that answers "is there anything to show?" without
    /// building `combinedArtworks`. The gesture mask and tap gate are
    /// re-evaluated on every body pass — i.e. every scrub tick — so allocating
    /// a fresh array there just to read `.isEmpty` is wasted per-frame work.
    private var hasArtworks: Bool {
        // Screenshot mode renders a fixed neutral fan (no fetched artwork), so
        // report "has covers" to keep the scrub gesture live for framing.
        if cullaScreenshotMode { return true }
        return leadArtwork != nil || !deckArtworks.isEmpty
    }

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
    /// of the deck changes — mode, sort, the picked playlist/artist, or the
    /// scoped include-dismissed toggle (which changes the scope's exclusion).
    /// Stable across carousel close events: those only affect `leadKey`, so
    /// closing the carousel at a new song no longer triggers a full re-walk.
    private var deckKey: String {
        let base = "\(mode.rawValue):\(sortOrder.rawValue)"
        switch source {
        case .playlist(let id, _, _): return "\(base):playlist:\(id):\(includeDismissedInScope)"
        case .artist(let id, _):      return "\(base):artist:\(id):\(includeDismissedInScope)"
        case .none:                   return "\(base):none"
        }
    }

    /// Identity for `.task(id:)` on the lead artwork. For a scope the lead is
    /// the source's own cover (keyed on its id so it loads once); for an
    /// unscoped deck it's the "where you left off" cover keyed on
    /// `preferredFrontSongID`. Folding `source` in keeps the two from leaking
    /// across the none ↔ scoped boundary.
    private var leadKey: String {
        switch source {
        case .playlist(let id, _, _): return "playlist-cover:\(id)"
        case .artist(let id, _):      return "artist-cover:\(id)"
        case .none:                   return preferredFrontSongID ?? ""
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
        // Screenshot-demo: the deck is the fixed neutral fan (`screenshotDeck`),
        // so skip the real library walk entirely — no fetch, and nothing
        // published to `onPrimaryArtworkResolved`, which keeps the ambient
        // background on the brand accent instead of a real album's colour.
        if cullaScreenshotMode { return }

        frontFallbackKind = fallbackKind(for: mode, source: source)
        // Treat this deckKey as loading until the pass below settles, so an
        // empty result reads as "loading then empty", not "empty forever".
        hasLoadedDeck = false

        // A picked scope fills the deck with the collection's tracks; the
        // source's own cover is pinned separately as the lead (see `updateLead`).
        if let source {
            let result = await fetchScopeArtworks(source: source, limit: deckCapacity)
            if Task.isCancelled { return }
            withAnimation(.smooth(duration: 0.3)) { deckArtworks = result }
            hasLoadedDeck = true
            publishPrimaryArtwork()
            return
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
        hasLoadedDeck = true
        publishPrimaryArtwork()
    }

    /// Refreshes the lead artwork — the card pinned at slot 0.
    ///
    /// - Scoped source → the playlist's cover / artist's photo, read straight
    ///   from the service cache (no round-trip). It deliberately ignores
    ///   `preferredFrontSongID` so the cover stays pinned even after the user
    ///   scrubs the expanded carousel to a different track. A scope with no
    ///   cover image resolves to `nil`, so the deck's tracks scrub on their own.
    /// - Unscoped → the carousel's "where you left off" cover, fetched by id.
    private func updateLead() async {
        // Screenshot-demo: no pinned lead cover; the neutral fan stands alone.
        if cullaScreenshotMode { return }

        switch source {
        case .playlist(let id, _, _):
            let cover = MusicLibraryService.shared.artwork(forPlaylistID: id)
            withAnimation(.smooth(duration: 0.3)) { leadArtwork = cover }
            publishPrimaryArtwork()
            return
        case .artist(let id, _):
            let photo = MusicLibraryService.shared.artwork(forArtistID: id)
            withAnimation(.smooth(duration: 0.3)) { leadArtwork = photo }
            publishPrimaryArtwork()
            return
        case .none:
            break
        }
        guard let preferredFrontSongID else {
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

    /// Reports the hero's "first visible" artwork up to HomeView so the ambient
    /// background can tint to match. Always the front card: the pinned lead
    /// (source cover / where-you-left-off) when present, otherwise the deck's
    /// first cover. Called from both `loadDeck` and `updateLead` so whichever
    /// finishes last writes the up-to-date value.
    private func publishPrimaryArtwork() {
        onPrimaryArtworkResolved?(leadArtwork ?? deckArtworks.first)
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

    /// Result of one per-ID library lookup in `fetchRecentlyDismissedArtworks`.
    /// Distinguishes "the song is there but has no artwork" from "the song is
    /// gone" from "the request failed" — only the middle one is prune evidence.
    private enum DismissedLookup {
        /// Song is in the library (its artwork may still be nil).
        case inLibrary(Artwork?)
        /// Request succeeded with no match — the song left the library.
        case missing
        /// Request threw — no evidence either way.
        case failed
    }

    /// Reads SwiftData for dismissed songs in the user's chosen order, then
    /// fetches each artwork by ID in parallel. Direct filter (not
    /// `resolveSongs`) so we don't page through the whole library looking
    /// for matches. The order MUST track `sortOrder.ascending` so the
    /// hero stack and the dismissed carousel show the same song first —
    /// otherwise oldest-first surfaces different covers on each surface.
    ///
    /// The per-ID filter doubles as orphan detection: an exact-ID library
    /// request only ever returns the match or nothing, so a request that
    /// SUCCEEDS empty proves the song was deleted from the library. Those rows
    /// are pruned (via the shared reconciler, which spares catalog rows) and
    /// the window re-fetched — otherwise a deleted song holds a deck slot as
    /// a blank forever while Home's Dismissed count keeps counting it.
    private func fetchRecentlyDismissedArtworks(limit: Int) async -> [Artwork] {
        // Each pass either returns, or prunes ≥1 orphan row and re-fetches the
        // now-smaller window — so the loop always terminates.
        while !Task.isCancelled {
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

            // Plain-value copy so the parallel tasks below never touch the
            // SwiftData models off the main actor.
            let ids = dismissed.map(\.songID)

            // Parallel fetch keyed by index so we can put the results back in
            // dismissed-order — TaskGroup yields completions in any order.
            let outcomes = await withTaskGroup(of: (Int, DismissedLookup).self) { group in
                for (idx, id) in ids.enumerated() {
                    group.addTask {
                        do {
                            var request = MusicLibraryRequest<Song>()
                            request.filter(matching: \.id, equalTo: MusicItemID(id))
                            let response = try await request.response()
                            guard let song = response.items.first else {
                                return (idx, .missing)
                            }
                            return (idx, .inLibrary(song.artwork))
                        } catch {
                            return (idx, .failed)
                        }
                    }
                }
                var slots: [(Int, DismissedLookup)] = []
                for await pair in group { slots.append(pair) }
                return slots.sorted { $0.0 < $1.0 }.map(\.1)
            }

            let artworks: [Artwork] = outcomes.compactMap {
                if case .inLibrary(let artwork) = $0 { return artwork }
                return nil
            }

            // Only decisive lookups (found / authoritatively missing) may feed
            // the reconciler — a thrown request proves nothing about its row.
            var decisiveRows: [DismissedSong] = []
            var inLibraryIDs: Set<String> = []
            for (row, outcome) in zip(dismissed, outcomes) {
                switch outcome {
                case .inLibrary:
                    decisiveRows.append(row)
                    inLibraryIDs.insert(row.songID)
                case .missing:
                    decisiveRows.append(row)
                case .failed:
                    break
                }
            }

            // When NOT ONE row in the window resolved, the "missing" verdicts
            // could equally mean the library read back empty before syncing
            // (the cold-open trap SortedSongReconciler refuses to reconcile
            // against). One limit-1 probe settles it: a readable library
            // returns something, so the misses really are deletions. If even
            // the probe comes back empty, skip pruning — a later pass
            // self-heals once the library is actually there.
            let hasOrphanCandidates = decisiveRows.contains {
                !$0.isCatalogTrack && !inLibraryIDs.contains($0.songID)
            }
            if hasOrphanCandidates, inLibraryIDs.isEmpty {
                var probe = MusicLibraryRequest<Song>()
                probe.limit = 1
                let probeItems = (try? await probe.response())?.items
                guard let probeItems, !probeItems.isEmpty else { return artworks }
            }

            let pruned = DismissedSongReconciler.pruneOrphans(
                rows: decisiveRows,
                resolvedIDs: inLibraryIDs,
                in: modelContext
            )
            guard !pruned.isEmpty else { return artworks }

            onDismissedOrphansPruned?()
            // The window shrank — go around to refill it from the rows that
            // were previously beyond the fetchLimit.
        }
        return []
    }

    /// Resolves the scope's track artworks for the scrub deck. Applies the same
    /// dismissed filter the scoped swipe session uses (via `scopeExclusionSet`),
    /// so the hero and the expanded carousel preview the same tracks in the same
    /// order. The playlist cover / artist photo itself is pinned separately as
    /// `leadArtwork` (see `updateLead`), so it isn't drawn from here. Returns
    /// empty on failure → the deck falls through to its empty/loading state.
    private func fetchScopeArtworks(source: SourceScope, limit: Int) async -> [Artwork] {
        let exclusion = MusicLibraryService.shared.scopeExclusionSet(
            includeDismissed: includeDismissedInScope,
            modelContext: modelContext
        )
        do {
            let songs = try await MusicLibraryService.shared.scopeSongs(
                for: source,
                sortOrder: sortOrder
            )
            if Task.isCancelled { return [] }
            var collected: [Artwork] = []
            for song in songs where !exclusion.contains(song.id.rawValue) {
                if let art = song.artwork {
                    collected.append(art)
                    if collected.count >= limit { break }
                }
            }
            return collected
        } catch {
            print("HomeHeroArtStack fetchScopeArtworks failed: \(error)")
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
