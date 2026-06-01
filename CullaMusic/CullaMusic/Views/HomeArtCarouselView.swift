import SwiftUI
import SwiftData
import MusicKit

/// Fullscreen exploration view reached by tapping the centered cover on
/// `HomeHeroArtStack`. Shows the same mode's songs as a center-anchored
/// horizontal carousel — every cover in the current method (library /
/// unsorted / dismissed) is browsable, in the same sort order chosen on Home.
///
/// Interaction model:
/// - Tap a **side cover** → snap it to centre and start its preview.
/// - Tap the **centred cover** → toggle play/pause of its preview.
/// - Drag/scroll → snaps to the nearest cover; preview keeps playing.
/// - Tap the **identity strip** → opens a Menu to switch mode (Library /
///   Unsorted / Dismissed). The selection is bound to HomeView so the choice
///   syncs back to the Home screen.
/// - Tap **Start Cullaing** → opens `MusicSwipeView` seeded with the centred
///   song as its first card, so an already-playing preview keeps going.
/// - Tap the **dim backdrop** → returns to Home. The carousel band has a
///   vertical safe gutter so a near-miss release doesn't accidentally dismiss.
///
/// Scope (v1): only `.library`, `.unsorted`, `.dismissed`. Playlist/artist
/// sources are deferred — those screens have their own portrait vocabulary.
struct HomeArtCarouselView: View {
    @Binding var mode: ReviewMode
    let sortOrder: SortOrder
    let modelContext: ModelContext
    /// Real total for the current mode, sourced from `HomeView.count(for:)`.
    /// The carousel feed only loads ~100 songs initially, so the strip would
    /// otherwise show a misleading "99 songs" when the actual library has
    /// thousands. `nil` while Home's count cache is still computing — the
    /// strip falls back to the loaded count + a "+" indicator in that case.
    let totalCount: Int?
    let onStart: (_ anchorSongs: [Song]) -> Void
    let onDismiss: () -> Void
    /// Fires when the carousel exits, carrying the Apple Music song-id of
    /// whichever cover was last centred. HomeView holds this so the
    /// `HomeHeroArtStack` can prepend that artwork — the hero on Home
    /// reflects "where you left off." `nil` if the feed never landed.
    var onCenteredSongOnExit: ((String?) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let service = MusicLibraryService.shared

    @State private var feed: CarouselSongFeed?
    /// Apple Music song-id raw value of the currently-centred cover. Updated
    /// by `.scrollPosition(id:)` as the user drags, and written directly when
    /// the user taps a side cover to snap it.
    @State private var scrollPositionID: String?
    /// Drives the staggered entrance choreography (identity → carousel →
    /// metadata → CTA). Bumped from 0 to 4 across ~0.4s on first appear,
    /// or jumped straight to 4 when reduce-motion is on. Held as @State so
    /// each remount of the carousel plays a fresh entrance.
    @State private var revealStage: Int = 0
    /// Presents the date-jump picker sheet.
    @State private var showDatePicker = false
    /// Oldest/newest library-add dates, bounding the picker. Loaded once on
    /// appear; nil while loading or when the library exposes no add-dates (the
    /// date control stays hidden in that case).
    @State private var dateSpan: (oldest: Date, newest: Date)?
    /// True while `loadUntil` pages toward the picked date — drives the pill's
    /// spinner so a far jump reads as working rather than frozen.
    @State private var isJumping = false

    private let coverSize: CGFloat = 280
    private let coverSpacing: CGFloat = 18
    /// Vertical padding above/below the carousel band that absorbs taps
    /// without dismissing. Stops a near-miss release from kicking the user
    /// back to Home mid-explore. Trimmed from 36 → 18 so the metadata
    /// strip below the carousel sits visually close to the cover.
    private let bandGutter: CGFloat = 18

    var body: some View {
        ZStack {
            // Pure backdrop — flat `Color(.systemBackground)` so nothing
            // competes with the cover. An earlier draft used
            // `HomeAmbientBackground` here for continuity with Home, but its
            // tinted glow + grain read as a cropped silvery wash against the
            // surrounding system colour. Minimalism wins on this screen; the
            // cover IS the personality.
            Color(.systemBackground)
                .ignoresSafeArea()

            // Drag-to-step surface above the backdrop. Empty regions of the
            // screen (the slack around the cover, above the strip, below the
            // metadata) feed horizontal swipes into a one-song step so the
            // user can explore without aiming at the strict cover row. The
            // threshold is deliberately generous so an incidental finger
            // glide doesn't change the centred song. Dismiss is handled by
            // the X button now — backdrop-tap is gone so this real estate
            // can belong entirely to browsing.
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 40)
                        .onEnded { value in
                            handleBackgroundSwipe(translation: value.translation.width)
                        }
                )
                .accessibilityHidden(true)

            // Layered column: identity at the top, carousel centred, song
            // metadata below the cover, CTA closing the column. Each layer
            // reveals on a staggered timer (gated by reduce-motion) so the
            // screen settles in instead of flashing whole.
            VStack(spacing: 0) {
                identityStrip
                    .padding(.top, 8)
                    .opacity(revealStage >= 1 ? 1 : 0)
                    .offset(y: revealStage >= 1 ? 0 : -10)

                if showsDateControl, let displayDate = dateControlDate {
                    CarouselDateJumpControl(
                        displayDate: displayDate,
                        isJumping: isJumping,
                        onOpen: { showDatePicker = true }
                    )
                    .padding(.top, 8)
                    .opacity(revealStage >= 1 ? 1 : 0)
                    .offset(y: revealStage >= 1 ? 0 : -10)
                }

                Spacer(minLength: 16)

                carouselBand
                    .opacity(revealStage >= 2 ? 1 : 0)
                    .scaleEffect(revealStage >= 2 ? 1 : 0.94)

                centeredMetadata
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .opacity(revealStage >= 3 ? 1 : 0)
                    .offset(y: revealStage >= 3 ? 0 : 8)

                Spacer(minLength: 16)

                ctaBand
                    .opacity(revealStage >= 4 ? 1 : 0)
                    .offset(y: revealStage >= 4 ? 0 : 12)
            }
        }
        .overlay(alignment: .topLeading) {
            // Explicit dismiss affordance — backdrop-tap is also there but
            // most users will reach for a visible button. Sits at top-leading
            // so it doesn't fight Home's settings gear at top-trailing (the
            // gear stays visible because it lives on HomeView's outer overlay).
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
                    .glassSurface(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
            .padding(.top, 16)
            .accessibilityLabel("Back to Home")
            .opacity(revealStage >= 1 ? 1 : 0)
            .offset(y: revealStage >= 1 ? 0 : -8)
        }
        .task {
            await loadFeedIfNeeded()
        }
        .task {
            // Span is library-wide (independent of mode), so load it once.
            if dateSpan == nil {
                dateSpan = await service.libraryAddedDateSpan()
            }
        }
        .sheet(isPresented: $showDatePicker) {
            if let dateSpan {
                CarouselDateJumpSheet(
                    lowerBound: dateSpan.oldest,
                    upperBound: dateSpan.newest,
                    initialDate: currentCenteredSong?.libraryAddedDate ?? dateSpan.newest,
                    onConfirm: performDateJump(to:)
                )
            }
        }
        .onAppear { runEntranceChoreography() }
        .onChange(of: mode) { _, _ in
            // Mode swap via the Menu — reload the feed against the new
            // method. The brief loading placeholder while the new page
            // lands is intentional feedback that the swap took effect.
            Task { await reloadFeedForModeChange() }
        }
        // Stop preview on exit so audio doesn't keep playing once the user
        // returns to Home — Home has no transport to surface or stop it.
        .onDisappear {
            service.stopPreview()
        }
    }

    // MARK: - Identity strip

    /// Breadcrumb above the carousel, wrapped in a Menu that switches mode.
    /// The selection is bound up to HomeView via `$mode`, so picking
    /// "Dismissed" here also flips the Home screen's selected mode tile.
    /// Falls back to the loaded page count with a `+` suffix while Home's
    /// real count is still computing, so the strip never shows a
    /// misleadingly small number.
    private var identityStrip: some View {
        let (count, isPartial) = displayCount
        return Menu {
            Picker("Mode", selection: $mode) {
                ForEach(ReviewMode.allCases) { reviewMode in
                    Label(reviewMode.title, systemImage: reviewMode.icon)
                        .tag(reviewMode)
                }
            }
        } label: {
            CarouselIdentityStrip(
                mode: mode,
                count: count,
                isPartial: isPartial
            )
        }
        .buttonStyle(.plain)
    }

    /// Resolves what to show in the strip's count slot.
    ///
    /// - Returns Home's real total when available — that's the authoritative
    ///   number, matching the Library card the user just tapped.
    /// - Falls back to `(loadedCount, isPartial: true)` while Home's count
    ///   is still computing, so the strip reads e.g. "100+ songs" instead
    ///   of pretending we know the total.
    /// - Returns `(nil, false)` only when neither value exists yet (very
    ///   first cold-start frame) — the strip shows "Loading…" instead.
    private var displayCount: (Int?, Bool) {
        if let totalCount {
            return (totalCount, false)
        }
        if let loaded = feed?.songs.count, loaded > 0 {
            return (loaded, true)
        }
        return (nil, false)
    }

    // MARK: - Centered song metadata

    /// Title + artist · album for whichever cover is currently centred.
    /// Mirrors `SongCardView`'s metadata vocabulary so the carousel and the
    /// swipe screen feel like one family — when the user starts cullaing,
    /// the title they were just reading carries over visually.
    ///
    /// `.contentTransition(.opacity)` keyed off `scrollPositionID` cross-
    /// fades the strings as the user scrubs, instead of hard-cutting.
    /// Reduce-motion drops the animation so the swap is instant.
    @ViewBuilder
    private var centeredMetadata: some View {
        let song = currentCenteredSong
        VStack(spacing: 4) {
            Text(song?.title ?? " ")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(1)

            Text(metadataSubtitle(for: song))
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
        }
        .contentTransition(.opacity)
        .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: scrollPositionID)
        .frame(maxWidth: .infinity)
    }

    private var currentCenteredSong: Song? {
        guard let id = scrollPositionID, let feed else { return nil }
        return feed.songs.first(where: { $0.id.rawValue == id })
    }

    private func metadataSubtitle(for song: Song?) -> String {
        guard let song else { return " " }
        let artist = song.artistName
        if let album = song.albumTitle, !album.isEmpty {
            return "\(artist) • \(album)"
        }
        return artist
    }

    // MARK: - Entrance choreography

    /// Staggered reveal on first appear — identity strip drops in, carousel
    /// scales up, metadata fades in, CTA pops up. Each phase ~0.42s on a
    /// `.smooth` curve, with ~80ms offsets so the eye reads the screen as
    /// one settling motion. Reduce-motion jumps straight to the final
    /// state with no animation.
    private func runEntranceChoreography() {
        guard revealStage == 0 else { return }
        guard !reduceMotion else { revealStage = 4; return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            withAnimation(.smooth(duration: 0.42)) { revealStage = 1 }
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.smooth(duration: 0.42)) { revealStage = 2 }
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.smooth(duration: 0.42)) { revealStage = 3 }
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) { revealStage = 4 }
        }
    }

    // MARK: - Carousel band

    @ViewBuilder
    private var carouselBand: some View {
        Group {
            if let feed, !feed.songs.isEmpty {
                loadedCarousel(feed: feed)
            } else if feed?.isInitialLoading ?? true {
                loadingPlaceholder
            } else {
                // Race fallback — the user opened the carousel just as the
                // last song was sorted/dismissed. Show a gentle prompt; the
                // X button dismisses.
                emptyPlaceholder
            }
        }
        // Vertical breathing room around the cover. Was previously a
        // tap-swallowing gutter; with backdrop dismiss gone, it's pure
        // layout padding — hits on it fall through to the background
        // drag-step surface like every other empty region.
        .padding(.vertical, bandGutter)
    }

    private func loadedCarousel(feed: CarouselSongFeed) -> some View {
        GeometryReader { geo in
            let sidePadding = max(0, (geo.size.width - coverSize) / 2)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: coverSpacing) {
                    ForEach(Array(feed.songs.enumerated()), id: \.element.id.rawValue) { idx, song in
                        coverCard(song: song)
                            .id(song.id.rawValue)
                            // Side covers shrink + fade; centred cover stays
                            // at full size. `.scrollTransition(.interactive)`
                            // animates the change continuously as the user
                            // drags, so the focus visibly shifts to whatever
                            // cover is nearest centre.
                            .scrollTransition(.interactive(timingCurve: .easeInOut)) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity ? 1.0 : 0.82)
                                    .opacity(phase.isIdentity ? 1.0 : 0.55)
                            }
                            .onAppear {
                                // Prefetch when we're near the loaded tail.
                                if feed.songs.count - idx <= feed.prefetchDistance {
                                    feed.loadMoreIfNeeded()
                                }
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, sidePadding, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrollPositionID, anchor: .center)
            .frame(width: geo.size.width)
        }
        .frame(height: coverSize)
    }

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(.thinMaterial)
            .frame(width: coverSize, height: coverSize)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, options: .repeating)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: mode.icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
            Text("Nothing to explore here yet")
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(width: coverSize, height: coverSize)
    }

    // MARK: - Cover

    private func coverCard(song: Song) -> some View {
        let isCentered = scrollPositionID == song.id.rawValue
        let isPlayingThis = service.isPlayingPreview
            && service.nowPlayingSongID == song.id.rawValue

        return Button {
            handleCoverTap(song: song, isCentered: isCentered)
        } label: {
            ZStack {
                coverArtwork(song: song)

                if isCentered {
                    if isPlayingThis, service.playbackDuration > 0 {
                        progressRing
                    }
                    playPauseButton(isPlaying: isPlayingThis)
                }
            }
            .frame(width: coverSize, height: coverSize)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func coverArtwork(song: Song) -> some View {
        Group {
            if let artwork = song.artwork {
                ArtworkImage(artwork, width: coverSize, height: coverSize)
                    .frame(width: coverSize, height: coverSize)
            } else {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.thinMaterial)
                    .frame(width: coverSize, height: coverSize)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
    }

    /// Tight progress ring traced around the play/pause button as the preview
    /// plays. Originally a rounded-rectangle hugging the album's outline, but
    /// that stroke fell outside the carousel band's frame and got clipped
    /// top/bottom by the parent. A circle around just the play button stays
    /// well inside the artwork bounds, reads as part of the control rather
    /// than a separate decoration, and matches the simpler vocabulary of
    /// SongCardView's playback chrome.
    private var progressRing: some View {
        let progress = min(1.0, max(0, service.playbackPosition / service.playbackDuration))
        return Circle()
            .trim(from: 0, to: progress)
            .stroke(
                .white.opacity(0.92),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            // -90° puts the start of the trim at 12 o'clock so the ring fills
            // clockwise from the top — the universal "playback progress" idiom.
            .rotationEffect(.degrees(-90))
            // Mirrors `playFullSong`'s 0.2s position timer — a hairline
            // smoothing animation, not a full spring.
            .animation(.linear(duration: 0.2), value: service.playbackPosition)
            // Slightly larger than the 62pt play button so the ring sits just
            // outside its rim with a clean breathing gap.
            .frame(width: 76, height: 76)
            .allowsHitTesting(false)
    }

    /// Frosted glass play/pause disc. Same vocabulary as `SongCardView`'s
    /// playButton so the carousel and swipe screen feel like one family.
    private func playPauseButton(isPlaying: Bool) -> some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 62, height: 62)
            .glassSurface(in: Circle(), interactive: true)
            .background(.black.opacity(0.45), in: Circle())
            .allowsHitTesting(false)
    }

    // MARK: - CTA

    /// "Start Cullaing" — same vocabulary as Home's CTA, deliberately at the
    /// same screen position so visually nothing moves when the carousel opens
    /// or closes. The button reads as a stable anchor while the covers slide
    /// behind it. No `matchedHero` here — when the carousel dismisses for the
    /// swipe view, Home's own startButton briefly re-renders and IT carries
    /// the morph into the swipe card (same screen position, so the user
    /// perceives the CTA lifting off from where it always was).
    private var ctaBand: some View {
        GradientCapsuleButton(
            title: "Start Cullaing",
            icon: "play.fill",
            iconEffect: .pulse
        ) {
            startFromCentered()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    // MARK: - Tap behavior

    /// Translates a horizontal swipe on the empty background area into a
    /// one-song step. The 70pt threshold means a casual finger drift won't
    /// scrub the carousel — it takes a deliberate flick. No auto-play on
    /// step: the user is exploring visually; tapping the centred cover
    /// engages audio. Matches the in-band ScrollView's snap feel.
    private func handleBackgroundSwipe(translation: CGFloat) {
        let threshold: CGFloat = 70
        guard abs(translation) > threshold else { return }

        guard
            let feed,
            let currentID = scrollPositionID,
            let currentIdx = feed.songs.firstIndex(where: { $0.id.rawValue == currentID })
        else { return }

        // Drag right → previous song (revealing what was off to the left);
        // drag left → next song. Matches the natural "pull the strip"
        // mental model of a horizontal carousel.
        let newIdx = translation > 0 ? currentIdx - 1 : currentIdx + 1
        guard feed.songs.indices.contains(newIdx) else { return }

        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            scrollPositionID = feed.songs[newIdx].id.rawValue
        }
    }

    private func handleCoverTap(song: Song, isCentered: Bool) {
        if isCentered {
            // Centred cover — toggle preview.
            if service.isPlayingPreview && service.nowPlayingSongID == song.id.rawValue {
                service.stopPreview()
            } else {
                service.playPreview(for: song)
            }
        } else {
            // Side cover — snap to centre AND start its preview. The two
            // animations run in parallel: the scroll snap is visual, the
            // preview start is audio. Both feel like a single beat.
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                scrollPositionID = song.id.rawValue
            }
            service.playPreview(for: song)
        }
    }

    private func startFromCentered() {
        guard
            let feed,
            let id = scrollPositionID,
            let centeredIdx = feed.songs.firstIndex(where: { $0.id.rawValue == id })
        else {
            onStart([])
            return
        }
        // Hand off the centred song plus a small forward window so the first
        // ~20 swipes flow in carousel order. After that the swipe VM's
        // natural paging kicks in (with these IDs in its exclusion set, so
        // they don't reappear).
        let windowEnd = min(feed.songs.count, centeredIdx + 20)
        let anchor = Array(feed.songs[centeredIdx..<windowEnd])
        onStart(anchor)
    }

    // MARK: - Date jump

    /// The date control only makes sense for the add-date-sorted timelines
    /// (Library / Unsorted), once we know the library's date span and have
    /// covers to scrub. Dismissed is sorted by dismissal date, so a
    /// library-add-date jump doesn't map — hide it there.
    private var showsDateControl: Bool {
        (mode == .library || mode == .unsorted)
            && dateSpan != nil
            && !(feed?.songs.isEmpty ?? true)
    }

    /// Date shown on the control — the add-date of the cover currently centred
    /// in the carousel, so the pill tracks the scroll live (falling back to the
    /// newest add-date before the first cover settles). The centred cover is
    /// also where the session starts, so the pill always reads "where you'll
    /// begin."
    private var dateControlDate: Date? {
        currentCenteredSong?.libraryAddedDate ?? dateSpan?.newest
    }

    /// Scrubs the carousel to the first cover added on/around `date`. The
    /// timeline isn't re-seeded — `loadUntil` only pages far enough forward to
    /// reach the boundary cover, then we snap the scroll there (the rest of the
    /// strip stays browsable). Snapping the scroll moves the centred cover,
    /// which is what the pill reads and what the session starts from — so the
    /// jump, the pill, and the eventual start point all stay in lockstep.
    private func performDateJump(to date: Date) {
        guard let feed else { return }
        isJumping = true
        Task {
            let id = await feed.loadUntil(date: date)
            isJumping = false
            guard let id else { return }
            if reduceMotion {
                scrollPositionID = id
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
                    scrollPositionID = id
                }
            }
        }
    }

    private func dismiss() {
        // Stop any preview in-flight before returning to Home — see
        // `.onDisappear` above; this just guarantees the fade happens
        // immediately rather than waiting on the transition.
        service.stopPreview()
        // Report the last-centred song to HomeView BEFORE handing off the
        // dismiss — so by the time HomeView re-renders, the hero stack's
        // preferred id is already set and the new front cover paints in
        // one frame instead of two.
        onCenteredSongOnExit?(scrollPositionID)
        onDismiss()
    }

    // MARK: - Loading

    private func loadFeedIfNeeded() async {
        if feed == nil {
            let f = CarouselSongFeed(
                mode: mode,
                sortOrder: sortOrder,
                modelContext: modelContext
            )
            feed = f
            await f.loadInitial()
            if scrollPositionID == nil {
                scrollPositionID = f.songs.first?.id.rawValue
            }
        }
    }

    /// Tears down the current feed and reloads against the new mode. Stops
    /// any in-flight preview first so we don't keep an old song playing
    /// against a new deck, and clears `scrollPositionID` so the new feed
    /// settles on its own first song instead of trying to find an id that
    /// belongs to the previous mode's library.
    private func reloadFeedForModeChange() async {
        service.stopPreview()
        scrollPositionID = nil
        feed = nil
        await loadFeedIfNeeded()
    }
}
