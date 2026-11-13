import SwiftUI
import SwiftData
import MusicKit

// MARK: - HomeView

struct HomeView: View {
    /// Starts a swipe session. `anchorSongs` is empty for the regular
    /// "Start Cullaing" path; when launched from `HomeArtCarouselView` it
    /// holds the centred song plus a small forward window so the swipe view
    /// can begin where the user was browsing (and the already-playing
    /// preview keeps going seamlessly).
    let onStart: (SwipeConfig, [Song]) -> Void
    /// Mode pile selection, owned by RootView so it survives Home ⇄ Swipe
    /// remounts but resets on a fresh app launch. See `RootView.selectedHomeMode`
    /// for the rationale; a local @State here would reset on every remount
    /// and desync the hero / carousel which both re-fetch off this mode.
    @Binding var selectedMode: ReviewMode
    /// Picked Sort-From scope, owned by RootView so it survives Home ⇄ Swipe
    /// remounts but resets on a fresh launch — same rationale as `selectedMode`.
    /// See `RootView.selectedSourceScope`.
    @Binding var source: SourceScope?
    /// Called once the first content load reaches the point where Home can show
    /// real content (playlists synced) — dismisses the launch splash. Optional
    /// so previews and any future caller can omit it. Harmless if it fires again
    /// on a later Home ⇄ Swipe remount; the splash is long gone by then.
    var onReady: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.appAccent) private var appAccent
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Shared namespace for the iOS 26 Liquid Glass morph. The mode-tile cluster
    /// and the source chips read it so their glass coordinates as one family —
    /// the cluster crystallizes out as the source chips crystallize in, instead
    /// of each being an isolated frosted bubble. Inert below iOS 26.
    @Namespace var glassMorph
    @State private var homeVM: HomeViewModel?
    @State var showSourcePicker = false
    @State private var showSettings = false
    @State private var showHistory = false
    /// Per-playlist track counts read from the persisted membership index.
    /// Used to display a meaningful count on the Library card when the user
    /// picks a source playlist — otherwise the card would show the total
    /// library count, which doesn't match what the swipe session will walk.
    /// `nil` while the snapshot is still loading so the card can show a
    /// loader instead of briefly rendering empty.
    @State private var sourceTrackCounts: [String: Int]?
    /// Current hero artwork — drives the ambient background's tint so the
    /// page color shifts with whichever album is being previewed. `nil` until
    /// the hero stack reports its first resolution, in which case the glow
    /// falls back to the app accent.
    @State private var heroArtwork: Artwork?
    /// Per-artist library track counts, lazily resolved when the user picks
    /// an artist source. Keyed by Apple Music artist ID. Absent → either
    /// loading (see `artistTrackCountsLoading`) or the fetch failed and we
    /// have nothing to render.
    @State private var artistTrackCounts: [String: Int] = [:]
    /// Artist IDs whose count is currently being fetched. Drives the loader
    /// on the Library mode card so it stops spinning after a failure instead
    /// of dangling forever because the count never landed.
    @State private var artistTrackCountsLoading: Set<String> = []
    /// Drives the `HomeArtCarouselView` overlay — flipped on by tapping the
    /// hero (only in source-less modes; sourced stacks route through their
    /// own UIs), flipped off by tapping the carousel's backdrop or by its
    /// "Start Cullaing" CTA handing off into the swipe view.
    @State private var showCarousel: Bool = false
    /// Apple Music song-id of the cover the user last centred in the
    /// carousel. Forwarded to `HomeHeroArtStack` so the hero on Home
    /// reflects "where you left off." Cleared whenever the deck source
    /// changes (mode / source / sort) so a stale id from one deck
    /// doesn't leak into another.
    @State private var lastCenteredCarouselSongID: String?
    /// Height of Home's column (the screen minus the safe areas). Picks the
    /// hero size; `.infinity` until the first layout reports it.
    @State private var columnHeight: CGFloat = .infinity
    @AppStorage("music.sortOrder") var sortOrderRaw: String = SortOrder.newestFirst.rawValue
    @AppStorage("music.sourceTransferMode") var sourceTransferModeRaw: String = SourceTransferMode.copy.rawValue
    /// Scoped-only opt-in: when on, dismissed tracks also surface inside
    /// playlist/artist sessions. Default off preserves prior behavior; the
    /// per-card "Dismissed Xmo ago" chip identifies them when they appear.
    @AppStorage("music.includeDismissedInScope") var includeDismissedInScope: Bool = false

    /// One-time hint under the hero — the fanned covers are draggable (peek
    /// ahead) and tappable (open the full-screen browser), neither of which is
    /// obvious from a static-looking stack.
    @AppStorage(OnboardingFlags.homeHeroHint) private var hasSeenHomeHeroHint: Bool = false

    var body: some View {
        ZStack {
            HomeAmbientBackground(tint: ambientTint)

            VStack(spacing: 0) {
                topMark
                    .padding(.top, 16)

                Spacer(minLength: 8)

                HomeHeroArtStack(
                    mode: selectedMode,
                    source: source,
                    sortOrder: SortOrder(rawValue: sortOrderRaw) ?? .newestFirst,
                    modelContext: modelContext,
                    includeDismissedInScope: includeDismissedInScope,
                    onPrimaryArtworkResolved: { heroArtwork = $0 },
                    onHeroTap: {
                        // Opening the carousel IS the action the hint points to
                        // ("tap to browse covers"), so retire the hint here too —
                        // otherwise it reappears the next time the user lands on
                        // Home. No animation needed: the `!showCarousel` gate
                        // already hides it the moment the carousel opens.
                        hasSeenHomeHeroHint = true
                        withAnimation(.easeInOut(duration: 0.28)) {
                            showCarousel = true
                        }
                    },
                    onDismissedOrphansVoided: {
                        // The hero's dismissed load just proved (and voided)
                        // rows whose song left the library — recompute so the
                        // Dismissed badge drops to the real number instead of
                        // keeping the phantom count.
                        homeVM?.triggerRecompute()
                    },
                    preferredFrontSongID: lastCenteredCarouselSongID,
                    scale: heroScale
                )
                // One-time discoverability hint for the hero's hidden gestures.
                // Floated as an overlay (not a row in the VStack) so dismissing it
                // just fades it out — it never reserved layout space, so the
                // screen doesn't reflow/jump. Gated on real artwork so it never
                // shows over the skeleton, and hidden while the carousel it points
                // to is open.
                .overlay(alignment: .bottom) {
                    // ZStack + `.animation(value:)` so BOTH directions animate.
                    // Before, only the dismiss was wrapped in `withAnimation`;
                    // the *insertion* fired when `heroArtwork` resolved — outside
                    // any transaction — so the tip popped in with no fade. Driving
                    // it off a Bool here gives the appear a real spring too.
                    ZStack {
                        if showsHeroHint {
                            CoachTip(icon: "hand.draw", text: "Drag to peek · tap to browse covers") {
                                hasSeenHomeHeroHint = true
                            }
                            .padding(.bottom, 6)
                            // Rise + grow on the way in, sink + shrink on the way
                            // out — a clearly visible motion, not the old
                            // near-invisible 0.94 nudge the user couldn't see.
                            .transition(
                                .opacity
                                    .combined(with: .scale(scale: 0.8, anchor: .bottom))
                                    .combined(with: .offset(y: 14))
                            )
                        }
                    }
                    .animation(.spring(response: 0.45, dampingFraction: 0.8), value: showsHeroHint)
                }

                // Mode tiles disappear once a scope is picked — at that point
                // mode is implicitly Library (the picker only surfaces there),
                // so the tiles are dead weight and would crowd the hero. The
                // sourceFilterButton's X button is the user's path back to the
                // unscoped state and the tiles.
                //
                // Asymmetric transition: on removal the stack scales down
                // *toward* the source area (anchor: .bottom) so it visually
                // hands focus to the picker; on insertion it drops in from
                // the hero (anchor: .top). Shares the scale-down-with-opacity
                // vocabulary used by sourceTransferPicker and
                // includeDismissedRow so the whole source-driven sequence
                // reads as one coordinated motion.
                //
                // The 32 pt gap under the hero rides on the tiles, so it leaves
                // with them: once a source is picked the dock grows, and the
                // freed space keeps everything on a 375 × 667 pt screen.
                if source == nil {
                    ModeChipRow(
                        selectedMode: selectedMode,
                        count: { count(for: $0) },
                        isLoadingCount: { isLoadingCount(for: $0) },
                        onSelect: { selectedMode = $0 }
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 32)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.94, anchor: .top)
                                .combined(with: .opacity),
                            removal: .scale(scale: 0.92, anchor: .bottom)
                                .combined(with: .opacity)
                        )
                    )
                    // On iOS 26 the cluster's glass crystallizes in/out (on top
                    // of the scale above) as the source is picked/cleared, so it
                    // hands focus to the source chips below as one glass family.
                    .glassMorphTransition(.materialize, reduceMotion: reduceMotion)
                }

                Spacer(minLength: 12)

                controlDock
            }
            .background {
                GeometryReader { geo in
                    Color.clear.onChange(of: geo.size.height, initial: true) { _, height in
                        columnHeight = height
                    }
                }
            }

            // Carousel overlay — covers Home while showing. Home stays
            // mounted underneath (its .task, ambient background, and source
            // state all persist), but the dim backdrop + covers visually
            // replace it. Tapping the CTA dismisses the carousel and starts
            // the session; tapping the backdrop returns to Home as-is.
            if showCarousel {
                HomeArtCarouselView(
                    mode: $selectedMode,
                    sortOrder: SortOrder(rawValue: sortOrderRaw) ?? .newestFirst,
                    source: source,
                    includeDismissedInScope: includeDismissedInScope,
                    modelContext: modelContext,
                    totalCount: count(for: selectedMode),
                    onStart: { anchor in
                        var config = buildSwipeConfig()
                        // Start the session from the cover the user is centred
                        // on in the carousel — its add-date anchors the whole
                        // library walk. Add-date timelines only (Library /
                        // Unsorted); Dismissed is sorted by dismissal date, so a
                        // library-add-date anchor doesn't apply there.
                        if config.source == nil, config.mode != .dismissed {
                            config.startFromDate = anchor.first?.libraryAddedDate
                        }
                        // Dismiss the carousel synchronously so Home is back
                        // beneath before RootView's startSession kicks off the
                        // Home → Swipe crossfade. The CTA's screen position is
                        // identical in both views, so the user never sees the
                        // swap.
                        showCarousel = false
                        onStart(config, anchor)
                    },
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            showCarousel = false
                        }
                        // The carousel feed voids orphaned dismissals during
                        // its full resolve (see CarouselSongFeed). Recompute on
                        // the way back so the badges pick that up — free when
                        // nothing changed (the count fingerprints still match).
                        homeVM?.triggerRecompute()
                    },
                    onCenteredSongOnExit: { id in
                        lastCenteredCarouselSongID = id
                    }
                )
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
                    .glassSurface(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
            .padding(.top, 16)
            // The overlay sits above the carousel's zIndex(100), so without
            // gating, the gear would stay tappable through the carousel.
            // Fade + disable in tandem so the carousel reads as a focused
            // exploration view, not a layer with stray Home chrome poking
            // through. The opacity picks up the `withAnimation` transaction
            // that toggles `showCarousel`, so the fade is in sync with the
            // carousel's own transition.
            .opacity(showCarousel ? 0 : 1)
            .allowsHitTesting(!showCarousel)
        }
        .overlay(alignment: .topLeading) {
            // History button — mirror image of the settings gear, flanking the
            // centred mark. Same carousel gating so it doesn't poke through
            // the exploration overlay.
            Button {
                showHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
                    .glassSurface(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
            .padding(.top, 16)
            .opacity(showCarousel ? 0 : 1)
            .allowsHitTesting(!showCarousel)
        }
        .task {
            let vm = HomeViewModel(modelContext: modelContext)
            homeVM = vm
            // Load source counts off the main actor in parallel with loadCounts.
            // Both snapshots do file IO + JSON decode, so we don't want them
            // on the main thread blocking the first frame.
            async let counts = Task.detached(priority: .userInitiated) {
                MembershipIndex.diskCountsSnapshot()
            }.value
            async let artistCounts = Task.detached(priority: .userInitiated) {
                MembershipIndex.diskArtistCountsSnapshot()
            }.value
            await vm.loadCounts(onReady: onReady)
            let initialSnapshot = await counts
            sourceTrackCounts = initialSnapshot
            artistTrackCounts = await artistCounts.counts

            // Cold-launch backstop: the persisted snapshot is written by the
            // swipe screen's membership index. On a fresh install the user
            // might pick a source before ever opening the swipe screen — in
            // that case there's no snapshot yet and the Library count would
            // render empty. Build the index in the background so the rest of
            // Home's task can complete; sourceTrackCounts updates when the
            // rebuild lands (the source picker shows a loader in the meantime).
            if initialSnapshot.isEmpty, !vm.playlists.isEmpty {
                Task { @MainActor in
                    let index = MembershipIndex(service: MusicLibraryService.shared)
                    await index.rebuild()
                    sourceTrackCounts = index.countsSnapshot()
                }
            }
        }
        .onChange(of: selectedMode) { _, newValue in
            if newValue != .library {
                source = nil
            }
            // The carousel's "where you left off" id is per-deck. Swapping
            // mode swaps the deck, so the stale id from the prior mode must
            // not leak into the new hero — clear it before the next render.
            lastCenteredCarouselSongID = nil
        }
        .onChange(of: source) { _, newValue in
            if case .artist(let id, _) = newValue {
                Task { await fetchArtistTrackCountIfNeeded(id: id) }
            }
            // Same as mode: picking / clearing a source changes the deck.
            lastCenteredCarouselSongID = nil
        }
        .onChange(of: sortOrderRaw) { _, _ in
            // Flipping newest/oldest reorders the deck — the carousel-anchor
            // song from the previous order would land at a meaningless slot.
            lastCenteredCarouselSongID = nil
        }
        .sheet(isPresented: $showSourcePicker) {
            SourceScopePickerSheet(
                playlists: sourcePlaylists,
                selectedScope: source
            ) { picked in
                source = picked
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet()
                // Undoing a movement deletes a SortedSong/DismissedSong row,
                // which changes the count fingerprints. Recompute on close so
                // Home's badges reflect the reversal without a cold relaunch.
                .onDisappear { homeVM?.triggerRecompute() }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedMode)
        // Source changes ripple across several children (mode tiles, source
        // filter, transfer picker, include-dismissed). A soft spring lets the
        // whole choreography breathe instead of snapping; tile selection
        // stays on the snappier curve above so tap feedback isn't sluggish.
        .animation(.smooth(duration: 0.38), value: source)
    }

    private func fetchArtistTrackCountIfNeeded(id: String) async {
        if artistTrackCounts[id] != nil { return }
        if artistTrackCountsLoading.contains(id) { return }
        artistTrackCountsLoading.insert(id)
        defer { artistTrackCountsLoading.remove(id) }
        do {
            let ids = try await MusicLibraryService.shared.artistLibrarySongIDs(
                artistID: MusicItemID(id)
            )
            artistTrackCounts[id] = ids.count
        } catch {
            // Don't write a sentinel into artistTrackCounts — the loader stops
            // when this function returns (artistTrackCountsLoading drops the id
            // via defer), and the count slot stays empty. Re-picking the same
            // artist retriggers the fetch, which is the right behavior for a
            // transient network failure.
            print("HomeView.fetchArtistTrackCount failed: \(error)")
        }
    }

    private var sourcePlaylists: [Playlist] {
        (homeVM?.playlists ?? [])
            .filter { $0.appleMusicPlaylistID != nil }
            .sorted { $0.displayOrder < $1.displayOrder }
    }

    /// "Move out" removes the song from the source, which Apple only allows on
    /// playlists this app created (see `Playlist.createdByApp`). Every other
    /// source — imported, Music-app made, read-only, artist — is capped to Copy.
    func playlistCanRemove(amID: String) -> Bool {
        homeVM?.playlists.first { $0.appleMusicPlaylistID == amID }?.createdByApp ?? false
    }

    /// Color the ambient background glow is keyed to. Reads the hero artwork's
    /// dominant background color when available so the page tone shifts per
    /// album; falls back to the app accent before the first resolve lands or
    /// when the artwork didn't expose a usable color.
    private var ambientTint: Color {
        if let cg = heroArtwork?.backgroundColor {
            return Color(cgColor: cg)
        }
        return appAccent
    }

    /// Whether the hero's one-time "drag/tap" hint should be on screen. Pulled
    /// out as a plain `Bool` so the overlay can drive a real fade with
    /// `.animation(_:value:)` — an `Artwork?` can't be observed there directly,
    /// which is why the insertion never animated before.
    private var showsHeroHint: Bool {
        !hasSeenHomeHeroHint && heroArtwork != nil && !showCarousel
    }

    // MARK: - Top mark

    /// The brand mark alone, centred in the same 38 pt row as the History and
    /// Settings buttons (the "culla music" words are gone from Home). The ring
    /// follows `.primary`; the centre dot keeps its brand blue. Fixed at 22 pt
    /// to match the fixed-size buttons beside it.
    private var topMark: some View {
        CullaLogo()
            .frame(width: 22, height: 22)
            .frame(maxWidth: .infinity)
            .frame(height: 38)
    }

    // MARK: - Hero size

    /// The hero's size multiplier (1 = the original 168 pt cover). 1.27 from
    /// the H1 workshop. An iPhone SE-sized screen (column under 700 pt) gets
    /// 1.15, so a picked playlist (the tallest dock) still fits without a
    /// scroll view. Accessibility text sizes go back to 1 to leave room for
    /// the bigger text.
    private var heroScale: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 1.0 }
        return columnHeight < 700 ? 1.15 : 1.27
    }

    // MARK: - Control dock

    /// Sort From, the scope options, Order and Start on one glass panel at the
    /// bottom (H1 workshop: radius 30, padding 14, gap 12, 10 pt side inset,
    /// 8 pt above the bottom safe area). The option rows keep their shared
    /// `GlassEffectContainer` so their glass still refracts as one family;
    /// Start sits outside it because it's a solid gradient, not glass.
    private var controlDock: some View {
        VStack(spacing: 12) {
            GlassStack(spacing: 12) {
                if selectedMode == .library {
                    sourceFilterButton
                        .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
                }

                if selectedMode == .library, case .playlist = source {
                    sourceTransferPicker
                        .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
                }

                if selectedMode == .library, source != nil {
                    includeDismissedRow
                        .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
                }

                orderRow
            }

            startButton
        }
        .padding(14)
        .glassSurface(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Start CTA

    /// Uses the shared `GradientCapsuleButton` so HomeView's CTA, AuthGate's
    /// "Continue", and EmptyState's "Refresh" all share one implementation —
    /// changes to the CTA vocabulary propagate to every screen at once.
    private var startButton: some View {
        GradientCapsuleButton(
            title: "Start Cullaing",
            icon: "play.fill",
            iconEffect: .pulse
        ) {
            onStart(buildSwipeConfig(), [])
        }
    }

    /// Builds the `SwipeConfig` from the current Home selections. Extracted
    /// so the carousel CTA can reuse the exact same resolution (transfer mode
    /// gating, scope gating, read-only fallback) the regular Start button uses.
    private func buildSwipeConfig() -> SwipeConfig {
        let order = SortOrder(rawValue: sortOrderRaw) ?? .newestFirst
        let storedMode = SourceTransferMode(rawValue: sourceTransferModeRaw) ?? .copy
        let activeScope: SourceScope? = selectedMode == .library ? source : nil
        // Force `.copy` whenever the source can't accept removals. Apple only
        // permits track removal on playlists THIS app created, so Move out is
        // honored solely for `createdByApp` sources; read-only / imported /
        // Music-app playlists and artist scope all fall back to Copy.
        let transferMode: SourceTransferMode = {
            switch activeScope {
            case .playlist(let id, _, _): return playlistCanRemove(amID: id) ? storedMode : .copy
            case .artist:                 return .copy
            case .none:                   return storedMode
            }
        }()
        // The flag is only meaningful in scoped sessions — gate it here
        // so an unrelated stored value can't leak into an All-Library run.
        let includeDismissed = activeScope != nil && includeDismissedInScope
        // `startFromDate` is left at its default (nil) here. The plain Start
        // button reviews the whole timeline; only a carousel launch sets it,
        // from the centred cover's add-date (see the carousel's `onStart`).
        return SwipeConfig(
            mode: selectedMode,
            order: order,
            source: activeScope,
            sourceTransferMode: transferMode,
            includeDismissedInScope: includeDismissed
        )
    }

    private func count(for mode: ReviewMode) -> Int? {
        guard let vm = homeVM else { return nil }
        switch mode {
        case .library:
            // When a source is picked, the swipe walks that scope — not the
            // whole library. Show its count instead so the number on the card
            // matches what the user is about to review.
            switch source {
            case .playlist(let id, _, _): return sourceTrackCounts?[id]
            case .artist(let id, _):      return artistTrackCounts[id]
            case .none:                   return vm.libraryCount
            }
        case .unsorted:  return vm.unsortedCount
        case .dismissed: return vm.dismissedCount
        }
    }

    private func isLoadingCount(for mode: ReviewMode) -> Bool {
        // Before `.task` runs, homeVM is nil — treat that as loading so the
        // count slot doesn't briefly render empty before the loader appears.
        guard let vm = homeVM else { return true }
        switch mode {
        case .library:
            // While a source is picked, loading state tracks the matching
            // count cache rather than the (currently-unused) library walk.
            switch source {
            case .playlist:          return sourceTrackCounts == nil
            case .artist(let id, _): return artistTrackCountsLoading.contains(id)
            case .none:              return vm.libraryCount == nil
            }
        case .unsorted:  return vm.unsortedCount == nil
        case .dismissed: return vm.dismissedCount == nil
        }
    }
}
