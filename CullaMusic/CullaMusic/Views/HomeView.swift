import SwiftUI
import SwiftData
import MusicKit

// MARK: - HomeViewModel

@Observable
final class HomeViewModel {
    var dismissedCount: Int? = nil  // nil = computing
    var unsortedCount: Int? = nil   // nil = computing
    var libraryCount: Int? = nil    // nil = computing
    var playlists: [Playlist] = []

    private let modelContext: ModelContext

    /// Tracks the in-flight recompute kicked off by `triggerRecompute()`.
    /// Cancelling it before starting a new one prevents two full library
    /// walks from racing when the user flips the toggle in rapid succession.
    private var pendingRecompute: Task<Void, Never>?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func loadCounts() async {
        // Local SwiftData fetch — paint the dismissed card immediately
        // instead of waiting on the Apple Music playlist sync round-trip.
        let dismissedSnapshot = (try? modelContext.fetchCount(FetchDescriptor<DismissedSong>())) ?? 0
        dismissedCount = dismissedSnapshot
        await syncPlaylistsFromAppleMusic()
        // Route through the cancellable slot so a toggle-flip arriving
        // mid-cold-start cancels this walk instead of racing it for the
        // cache. Previously the initial walk wasn't cancellable, so its
        // late write could clobber the toggled fingerprint's fresh value.
        triggerRecompute()
        await pendingRecompute?.value
    }

    /// Recomputes (or reads from cache) the library and unsorted counts. Both
    /// modes need to walk the full library on a cache miss, so we do it in a
    /// single pass and tally each count from the same iteration.
    ///
    /// Library cache is fingerprinted by Sorted/Dismissed counts + calendar
    /// day. Unsorted adds the chip toggle to its fingerprint, so flipping the
    /// toggle invalidates only the unsorted slot — the library cache stays warm.
    func recomputeCounts() async {
        let sortedSnapshot = (try? modelContext.fetchCount(FetchDescriptor<SortedSong>())) ?? 0
        let dismissedSnapshot = (try? modelContext.fetchCount(FetchDescriptor<DismissedSong>())) ?? 0
        dismissedCount = dismissedSnapshot
        let today = todayString()

        // Library cache.
        let libraryFingerprint = "\(sortedSnapshot):\(dismissedSnapshot)"
        let libraryCachedDate = UserDefaults.standard.string(forKey: "music.libraryCountDate") ?? ""
        let libraryCachedFP = UserDefaults.standard.string(forKey: "music.libraryCountFingerprint") ?? ""
        let libraryCachedValue = UserDefaults.standard.integer(forKey: "music.libraryCountCached")
        let libraryFresh = (libraryCachedDate == today && libraryCachedFP == libraryFingerprint)

        // Unsorted cache.
        let unsortedFingerprint = "\(sortedSnapshot):\(dismissedSnapshot)"
        let unsortedCachedDate = UserDefaults.standard.string(forKey: "music.unsortedCountDate") ?? ""
        let unsortedCachedFP = UserDefaults.standard.string(forKey: "music.unsortedCountFingerprint") ?? ""
        let unsortedCachedValue = UserDefaults.standard.integer(forKey: "music.unsortedCountCached")
        let unsortedFresh = (unsortedCachedDate == today && unsortedCachedFP == unsortedFingerprint)

        if libraryFresh { libraryCount = libraryCachedValue }
        if unsortedFresh { unsortedCount = unsortedCachedValue }

        guard !libraryFresh || !unsortedFresh else { return }

        // Cache miss — only show the loader if we have nothing to show yet.
        // If we already have a stale value, keep it visible during recompute
        // to avoid a count → loader → same-count flicker on toggle/invalidate.
        // The fresh value overwrites it when the walk completes.

        do {
            // Only fetch playlist memberships when unsorted needs them — saves
            // the round-trip on a toggle-only or library-only invalidation.
            let playlistIDs: Set<String>
            if !unsortedFresh {
                playlistIDs = try await MusicLibraryService.shared.fetchPlaylistSongIDs(
                    includeCurated: true
                )
            } else {
                playlistIDs = []
            }
            let sortedIDs = Set((try? modelContext.fetch(FetchDescriptor<SortedSong>()))?.map(\.songID) ?? [])
            let dismissedIDs = Set((try? modelContext.fetch(FetchDescriptor<DismissedSong>()))?.map(\.songID) ?? [])
            // Unsorted = "still needs a decision": not in any playlist, not
            // already sorted, and not dismissed. Dismissed must be excluded
            // here — otherwise the unsorted cache fingerprint (which includes
            // dismissedSnapshot) invalidates without the count ever changing.
            let unsortedExclusion = playlistIDs.union(sortedIDs).union(dismissedIDs)
            let libraryExclusion = sortedIDs.union(dismissedIDs)

            var libCount = 0
            var unsCount = 0
            let pageSize = 100
            var offset = 0

            while true {
                try Task.checkCancellation()
                var request = MusicLibraryRequest<Song>()
                request.limit = pageSize
                request.offset = offset
                let response = try await request.response()
                let page = response.items

                for song in page {
                    let id = song.id.rawValue
                    if !libraryFresh, !libraryExclusion.contains(id) {
                        libCount += 1
                    }
                    if !unsortedFresh, !unsortedExclusion.contains(id) {
                        unsCount += 1
                    }
                }

                offset += page.count
                if page.count < pageSize { break }
            }

            if !libraryFresh {
                libraryCount = libCount
                UserDefaults.standard.set(libCount, forKey: "music.libraryCountCached")
                UserDefaults.standard.set(today, forKey: "music.libraryCountDate")
                UserDefaults.standard.set(libraryFingerprint, forKey: "music.libraryCountFingerprint")
            }
            if !unsortedFresh {
                unsortedCount = unsCount
                UserDefaults.standard.set(unsCount, forKey: "music.unsortedCountCached")
                UserDefaults.standard.set(today, forKey: "music.unsortedCountDate")
                UserDefaults.standard.set(unsortedFingerprint, forKey: "music.unsortedCountFingerprint")
            }
        } catch is CancellationError {
            // A newer recompute superseded this one — leave the counts as
            // they are. The replacement task will write the up-to-date values.
            return
        } catch {
            print("Recompute counts failed: \(error)")
        }
    }

    /// Kick off a recompute that cancels any prior in-flight one. Use this
    /// from event handlers (e.g. toggle changes) where rapid re-entry is
    /// possible. Internal callers that need to await completion should call
    /// `recomputeCounts()` directly.
    func triggerRecompute() {
        pendingRecompute?.cancel()
        pendingRecompute = Task { @MainActor [weak self] in
            await self?.recomputeCounts()
        }
    }

    private func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        // Fixed locale + calendar so the cache key is stable across users
        // with Persian/Hebrew/Buddhist calendars or non-Arabic numerals.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f.string(from: .now)
    }

    private func syncPlaylistsFromAppleMusic() async {
        do {
            let amPlaylists = try await MusicLibraryService.shared.refreshUserPlaylists()
            let local = fetchLocalPlaylists()
            let localByAMID = Dictionary(
                uniqueKeysWithValues: local.compactMap { playlist -> (String, Playlist)? in
                    guard let appleMusicPlaylistID = playlist.appleMusicPlaylistID else { return nil }
                    return (appleMusicPlaylistID, playlist)
                }
            )
            var nextOrder = (local.map(\.displayOrder).max() ?? -1) + 1

            for amPlaylist in amPlaylists {
                let editable = computeEditability(for: amPlaylist)

                if let existing = localByAMID[amPlaylist.id.rawValue] {
                    // Sticky-downgrade: never re-upgrade a playlist that was
                    // previously marked read-only (by either sync's heuristic
                    // or by the self-heal path in MusicSwipeViewModel.loveCurrent).
                    existing.isEditable = existing.isEditable && editable
                    existing.name = amPlaylist.name
                } else {
                    let row = Playlist(
                        name: amPlaylist.name,
                        displayOrder: nextOrder,
                        appleMusicPlaylistID: amPlaylist.id.rawValue,
                        isEditable: editable
                    )
                    modelContext.insert(row)
                    nextOrder += 1
                }
            }

            // Prune local rows whose Apple Music source no longer exists —
            // without this, playlists deleted from Apple Music stick around
            // forever in the picker and sidebar. SwiftData cascades the
            // delete to their SortedSong records, which is correct: that
            // history is meaningless once the destination playlist is gone.
            let liveAMIDs = Set(amPlaylists.map { $0.id.rawValue })
            for playlist in local {
                guard let amID = playlist.appleMusicPlaylistID else { continue }
                if !liveAMIDs.contains(amID) {
                    modelContext.delete(playlist)
                }
            }

            try? modelContext.save()
            playlists = fetchLocalPlaylists()
        } catch {
            playlists = fetchLocalPlaylists()
            print("Playlist sync failed: \(error)")
        }
    }

    private func fetchLocalPlaylists() -> [Playlist] {
        let descriptor = FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.displayOrder)])
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}

// MARK: - HomeView

struct HomeView: View {
    /// Starts a swipe session. `anchorSongs` is empty for the regular
    /// "Start Cullaing" path; when launched from `HomeArtCarouselView` it
    /// holds the centred song plus a small forward window so the swipe view
    /// can begin where the user was browsing (and the already-playing
    /// preview keeps going seamlessly).
    let onStart: (SwipeConfig, [Song]) -> Void
    /// Namespace for the Home → Swipe hero morph. The "Start Cullaing" button
    /// tags itself with `heroStart`; the current SongCard's artwork shares
    /// the same id so SwiftUI interpolates between them.
    var heroNamespace: Namespace.ID?
    /// Mode pile selection, owned by RootView so it survives Home ⇄ Swipe
    /// remounts but resets on a fresh app launch. See `RootView.selectedHomeMode`
    /// for the rationale; a local @State here would reset on every remount
    /// and desync the hero / carousel which both re-fetch off this mode.
    @Binding var selectedMode: ReviewMode

    @Environment(\.modelContext) private var modelContext
    @Environment(\.appAccent) private var appAccent
    @State private var homeVM: HomeViewModel?
    @State private var source: SourceScope?
    @State private var showSourcePicker = false
    @State private var showSettings = false
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
    @AppStorage("music.sortOrder") private var sortOrderRaw: String = SortOrder.newestFirst.rawValue
    @AppStorage("music.sourceTransferMode") private var sourceTransferModeRaw: String = SourceTransferMode.copy.rawValue
    /// Scoped-only opt-in: when on, dismissed tracks also surface inside
    /// playlist/artist sessions. Default off preserves prior behavior; the
    /// per-card "Dismissed Xmo ago" chip identifies them when they appear.
    @AppStorage("music.includeDismissedInScope") private var includeDismissedInScope: Bool = false

    var body: some View {
        ZStack {
            HomeAmbientBackground(tint: ambientTint)

            VStack(spacing: 0) {
                wordmark
                    .padding(.top, 22)

                Spacer(minLength: 8)

                HomeHeroArtStack(
                    mode: selectedMode,
                    source: source,
                    sortOrder: SortOrder(rawValue: sortOrderRaw) ?? .newestFirst,
                    modelContext: modelContext,
                    onPrimaryArtworkResolved: { heroArtwork = $0 },
                    onHeroTap: {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            showCarousel = true
                        }
                    },
                    preferredFrontSongID: lastCenteredCarouselSongID
                )
                .padding(.bottom, 22)

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
                if source == nil {
                    GlassStack(spacing: 10) {
                        ForEach(ReviewMode.allCases) { mode in
                            ModeTile(
                                mode: mode,
                                isSelected: selectedMode == mode,
                                isDisabled: false,
                                count: count(for: mode),
                                isLoadingCount: isLoadingCount(for: mode)
                            ) {
                                selectedMode = mode
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.94, anchor: .top)
                                .combined(with: .opacity),
                            removal: .scale(scale: 0.92, anchor: .bottom)
                                .combined(with: .opacity)
                        )
                    )
                }

                Spacer(minLength: 12)

                if selectedMode == .library {
                    sourceFilterButton
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if selectedMode == .library, case .playlist = source {
                    sourceTransferPicker
                        .padding(.bottom, 10)
                        .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
                }

                if selectedMode == .library, source != nil {
                    includeDismissedRow
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                        .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
                }

                orderRow
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)

                startButton
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
            }

            // Carousel overlay — covers Home while showing. Home stays
            // mounted underneath (its .task, ambient background, and source
            // state all persist), but the dim backdrop + covers visually
            // replace it. Tapping the CTA dismisses the carousel and lets
            // Home's startButton carry the matchedHero morph into the
            // swipe card; tapping the backdrop returns to Home as-is.
            if showCarousel {
                HomeArtCarouselView(
                    mode: $selectedMode,
                    sortOrder: SortOrder(rawValue: sortOrderRaw) ?? .newestFirst,
                    modelContext: modelContext,
                    totalCount: count(for: selectedMode),
                    onStart: { anchor in
                        let config = buildSwipeConfig()
                        // Dismiss the carousel synchronously so Home's
                        // startButton re-renders before RootView's startSession
                        // kicks off the Home → Swipe morph. The CTA's screen
                        // position is identical in both views, so the user
                        // doesn't see the swap — they see the CTA lift off.
                        showCarousel = false
                        onStart(config, anchor)
                    },
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.28)) {
                            showCarousel = false
                        }
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
            await vm.loadCounts()
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

    /// True when the user has picked a Sort From source that we can't remove
    /// songs from (Apple-curated, smart Favorites, shared-by-others, etc.).
    /// Forces the transfer mode to `.copy` so we never attempt a doomed write.
    private var selectedSourceIsReadOnly: Bool {
        if case .playlist(_, _, let isEditable) = source { return !isEditable }
        return false
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

    // MARK: - Wordmark

    /// Identity strip at the top: the Culla brand mark + the app name. Logo
    /// size scales with Dynamic Type via `@ScaledMetric` so the relationship
    /// to the 15pt wordmark text holds under accessibility text sizes. The
    /// glyph follows `.primary`, so the central "C" auto-adapts between
    /// light and dark while the five brand dots keep their fixed hues.
    private var wordmark: some View {
        HStack(spacing: 7) {
            CullaLogo()
                .frame(width: wordmarkLogoSize, height: wordmarkLogoSize)
            HStack(spacing: 4) {
                Text("culla")
                    .foregroundStyle(.primary)
                Text("music")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .tracking(0.5)
        }
    }

    // Sized a touch larger than the 15pt cap height so the logo reads as the
    // anchor of the strip — small enough to sit politely beside the wordmark,
    // large enough that the five accent dots remain individually visible.
    @ScaledMetric(relativeTo: .subheadline) private var wordmarkLogoSize: CGFloat = 22

    // MARK: - Source pill (promoted to full-width glass card)

    private var sourceFilterButton: some View {
        Button {
            showSourcePicker = true
        } label: {
            HStack(spacing: 12) {
                if let source {
                    sourceThumbnail(for: source)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("SORT FROM")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                        Text(source.displayName)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button {
                        self.source = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "music.note.list")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                    Text("All library — pick a scope")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .glassSurface(
                in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                interactive: true
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sourceThumbnail(for source: SourceScope) -> some View {
        switch source {
        case .playlist(let id, _, _):
            PlaylistCoverView(
                appleMusicPlaylistID: id,
                size: 36,
                cornerRadius: 8
            )
        case .artist(let id, let name):
            ArtistThumbnail(artistID: id, artistName: name, size: 36)
        }
    }

    // MARK: - Order toggle

    /// Compact pill that flips between newest-first and oldest-first on tap.
    /// Replaces the old segmented control — order is a 2-state choice, the
    /// segmented control was overkill and ate a full row of vertical space.
    private var orderRow: some View {
        HStack(spacing: 8) {
            Text("Order")
                .font(.system(.footnote, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                let current = SortOrder(rawValue: sortOrderRaw) ?? .newestFirst
                let next: SortOrder = current == .newestFirst ? .oldestFirst : .newestFirst
                withAnimation(.snappy(duration: 0.22)) {
                    sortOrderRaw = next.rawValue
                }
            } label: {
                let current = SortOrder(rawValue: sortOrderRaw) ?? .newestFirst
                HStack(spacing: 6) {
                    Image(systemName: current == .newestFirst ? "arrow.down" : "arrow.up")
                        .font(.caption.weight(.bold))
                        .contentTransition(.symbolEffect(.replace))
                    Text(current.label)
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .contentTransition(.opacity)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Capsule())
                .glassSurface(in: Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Start CTA

    /// Uses the shared `GradientCapsuleButton` so HomeView's CTA, AuthGate's
    /// "Continue", and EmptyState's "Refresh" all share one implementation —
    /// changes to the CTA vocabulary propagate to every screen at once.
    /// Holds the `heroStart` matchedGeometry tag for the Home→Swipe morph
    /// (see RootView.swift:14).
    private var startButton: some View {
        GradientCapsuleButton(
            title: "Start Cullaing",
            icon: "play.fill",
            iconEffect: .pulse
        ) {
            onStart(buildSwipeConfig(), [])
        }
        .matchedHero(id: "heroStart", in: heroNamespace)
    }

    /// Builds the `SwipeConfig` from the current Home selections. Extracted
    /// so the carousel CTA can reuse the exact same resolution (transfer mode
    /// gating, scope gating, read-only fallback) the regular Start button uses.
    private func buildSwipeConfig() -> SwipeConfig {
        let order = SortOrder(rawValue: sortOrderRaw) ?? .newestFirst
        let storedMode = SourceTransferMode(rawValue: sourceTransferModeRaw) ?? .copy
        let activeScope: SourceScope? = selectedMode == .library ? source : nil
        // Force `.copy` whenever the source can't accept removals:
        // read-only playlists (Apple-curated / smart Favorites / shared),
        // or artist scope (no "remove from artist" exists).
        let transferMode: SourceTransferMode = {
            switch activeScope {
            case .playlist(_, _, let isEditable): return isEditable ? storedMode : .copy
            case .artist:                          return .copy
            case .none:                            return storedMode
            }
        }()
        // The flag is only meaningful in scoped sessions — gate it here
        // so an unrelated stored value can't leak into an All-Library run.
        let includeDismissed = activeScope != nil && includeDismissedInScope
        return SwipeConfig(
            mode: selectedMode,
            order: order,
            source: activeScope,
            sourceTransferMode: transferMode,
            includeDismissedInScope: includeDismissed
        )
    }

    /// Opt-in toggle for scoped sessions to also surface dismissed tracks.
    /// Mirrors `orderRow`'s chip style so the two scope-time controls feel
    /// like one family.
    private var includeDismissedRow: some View {
        HStack(spacing: 8) {
            Text("Include dismissed")
                .font(.system(.footnote, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    includeDismissedInScope.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: includeDismissedInScope ? "checkmark" : "xmark")
                        .font(.caption.weight(.bold))
                        .contentTransition(.symbolEffect(.replace))
                    Text(includeDismissedInScope ? "On" : "Off")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .contentTransition(.opacity)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Capsule())
                .glassSurface(in: Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
        }
    }

    private var sourceTransferPicker: some View {
        // For read-only sources the picker is forced to Keep — Apple doesn't
        // let us remove songs from those, so Move would silently fail.
        let isReadOnly = selectedSourceIsReadOnly
        let storedMode = SourceTransferMode(rawValue: sourceTransferModeRaw) ?? .copy
        let displayMode: SourceTransferMode = isReadOnly ? .copy : storedMode

        return VStack(spacing: 6) {
            Picker("Source behavior", selection: Binding(
                get: { displayMode },
                set: { sourceTransferModeRaw = $0.rawValue }
            )) {
                ForEach(SourceTransferMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isReadOnly)

            Text(transferModeFooter(isReadOnly: isReadOnly, mode: displayMode))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
    }

    private func transferModeFooter(isReadOnly: Bool, mode: SourceTransferMode) -> String {
        if isReadOnly {
            return "This playlist is read-only — sorted songs stay where they are."
        }
        return mode == .copy
            ? "Sorted songs stay in the source playlist too."
            : "Sorted songs are removed from the source playlist."
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

// MARK: - ArtistThumbnail

/// Renders an artist's library artwork as a small circular thumbnail for the
/// source button. Reads the cached `Artist` from `MusicLibraryService` rather
/// than refetching — the picker sheet primes the cache when it lists artists.
/// Falls back to an initials placeholder when the library artist has no
/// catalog-matched artwork.
private struct ArtistThumbnail: View {
    let artistID: String
    let artistName: String
    let size: CGFloat

    var body: some View {
        Group {
            if let artwork = MusicLibraryService.shared.artwork(forArtistID: artistID) {
                ArtworkImage(artwork, width: size, height: size)
            } else {
                ArtistPlaceholder(name: artistName, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - ModeTile

/// One row in the mode selector. Glass surface on iOS 26 (via `glassSurface`),
/// `.thinMaterial` fallback elsewhere. Selected tile picks up an accent tint,
/// border, and trailing chevron to telegraph "this is the deck you open".
private struct ModeTile: View {
    let mode: ReviewMode
    let isSelected: Bool
    let isDisabled: Bool
    let count: Int?
    let isLoadingCount: Bool
    let onTap: () -> Void

    @Environment(\.appAccent) private var appAccent

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                iconBadge

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(mode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                countSlot

                if isSelected {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(appAccent)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .glassSurface(
                in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                tint: isSelected ? appAccent : nil,
                interactive: true
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isSelected ? appAccent.opacity(0.45) : .white.opacity(0.06),
                        lineWidth: isSelected ? 1.4 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: isSelected)
        .animation(.easeInOut(duration: 0.2), value: isDisabled)
    }

    private var iconBadge: some View {
        ZStack {
            Circle()
                .fill(isSelected ? appAccent.opacity(0.22) : Color.secondary.opacity(0.12))
                .frame(width: 40, height: 40)
            Image(systemName: mode.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isSelected ? appAccent : .secondary)
                .symbolEffect(.bounce, value: isSelected)
        }
    }

    @ViewBuilder
    private var countSlot: some View {
        Group {
            if isLoadingCount {
                LinearLoader()
            } else if let count {
                Text(count.formatted())
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(isSelected ? appAccent : .secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
            }
        }
        .frame(width: 52, alignment: .trailing)
        .animation(.snappy, value: count)
    }
}
