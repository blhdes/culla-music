import SwiftUI
import SwiftData
import MusicKit
import UIKit

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
///   syncs back to the Home screen. When a `source` is picked the strip is a
///   plain label naming the playlist/artist — there's no mode to switch.
/// - Tap **Start Cullaing** → opens `MusicSwipeView` seeded with the centred
///   song as its first card, so an already-playing preview keeps going.
/// - Tap the **dim backdrop** → returns to Home. The carousel band has a
///   vertical safe gutter so a near-miss release doesn't accidentally dismiss.
///
/// Source: unscoped (`source == nil`) browses the current mode's deck;
/// a picked playlist/artist browses that collection instead. The date-jump
/// control is unscoped-only — scoped sessions don't walk an add-date timeline.
struct HomeArtCarouselView: View {
    @Binding var mode: ReviewMode
    let sortOrder: SortOrder
    /// Picked playlist/artist scope, forwarded from Home. `nil` → browse the
    /// `mode` deck; non-nil → browse that collection's tracks.
    let source: SourceScope?
    /// Whether dismissed tracks surface inside a scoped browse. Forwarded to the
    /// feed; ignored when `source == nil`.
    let includeDismissedInScope: Bool
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
    /// Single-flight latch for the entrance: set synchronously so a second
    /// `.onAppear` firing inside the choreography's first sleep can't start a
    /// second run racing the same `revealStage`. Resets with @State on remount,
    /// so each fresh mount still plays the entrance.
    @State private var didRunEntrance = false
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
        // Resolve the centred cover once per body pass — both the metadata
        // strip and the date pill derive from it, and `feed.songs` grows as the
        // user pages, so a single linear scan here beats one per consumer.
        let centered = currentCenteredSong
        return ZStack {
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

                if showsDateControl, let displayDate = dateControlDate(for: centered) {
                    DateJumpControl(
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

                centeredMetadata(for: centered)
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
                DateJumpSheet(
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
    @ViewBuilder
    private var identityStrip: some View {
        let (count, isPartial) = displayCount
        if let source {
            // Scoped browse — the strip just names the collection. No Menu:
            // switching to "Unsorted" while inside a playlist is meaningless.
            CarouselIdentityStrip(
                mode: mode,
                count: count,
                isPartial: isPartial,
                titleOverride: source.displayName,
                iconOverride: scopeIcon(for: source),
                showsMenuAffordance: false
            )
        } else {
            Menu {
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
    }

    private func scopeIcon(for source: SourceScope) -> String {
        switch source {
        case .playlist: return "music.note.list"
        case .artist:   return "person.fill"
        }
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
    private func centeredMetadata(for song: Song?) -> some View {
        VStack(spacing: 4) {
            // Marquee (not lineLimit truncation) — the centred title is the
            // focal text on this screen, so a long one scrolls to reveal in
            // full rather than getting cut with "…". `isActive: true` because
            // there's only ever one centred title and it's always the subject;
            // `.center` keeps a short title centred under the cover (the shared
            // component left-aligns by default for the album track row).
            MarqueeText(
                text: song?.title ?? " ",
                uiFont: titleUIFont,
                color: .primary,
                isActive: true,
                alignment: .center
            )

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

    /// The carousel title's font as a `UIFont` so `MarqueeText` can measure its
    /// true width. Mirrors `.system(.title3, design: .rounded).weight(.semibold)`:
    /// the rounded variant of the semibold system font at the current Dynamic
    /// Type title3 size. Recomputed per read so it tracks text-size changes.
    private var titleUIFont: UIFont {
        let size = UIFont.preferredFont(forTextStyle: .title3).pointSize
        let base = UIFont.systemFont(ofSize: size, weight: .semibold)
        let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        return UIFont(descriptor: descriptor, size: size)
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
        guard !didRunEntrance else { return }
        didRunEntrance = true
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
            // Ids of the last `prefetchDistance` covers — the prefetch trigger.
            // A small set built once per body, instead of `enumerated()` rebuilding
            // a tuple array of every loaded song (hundreds) on each scroll tick.
            let tailIDs = Set(feed.songs.suffix(feed.prefetchDistance).map { $0.id.rawValue })
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: coverSpacing) {
                    ForEach(feed.songs, id: \.id.rawValue) { song in
                        let isCentered = scrollPositionID == song.id.rawValue
                        CoverCard(
                            song: song,
                            isCentered: isCentered,
                            coverSize: coverSize,
                            onTap: { handleCoverTap(song: song, isCentered: isCentered) }
                        )
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
                                // Prefetch when one of the tail covers appears.
                                if tailIDs.contains(song.id.rawValue) {
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

    // MARK: - CTA

    /// "Start Cullaing" — same vocabulary as Home's CTA, deliberately at the
    /// same screen position so visually nothing moves when the carousel opens
    /// or closes. The button reads as a stable anchor while the covers slide
    /// behind it; on dismiss-for-swipe, Home's own startButton re-renders at
    /// this exact spot before the Home → Swipe crossfade, so the swap is
    /// invisible.
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
        source == nil
            && (mode == .library || mode == .unsorted)
            && dateSpan != nil
            && !(feed?.songs.isEmpty ?? true)
    }

    /// Date shown on the control — the add-date of the cover currently centred
    /// in the carousel, so the pill tracks the scroll live (falling back to the
    /// newest add-date before the first cover settles). The centred cover is
    /// also where the session starts, so the pill always reads "where you'll
    /// begin." Takes the already-resolved centred song so `body` only scans
    /// `feed.songs` once.
    private func dateControlDate(for centered: Song?) -> Date? {
        centered?.libraryAddedDate ?? dateSpan?.newest
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
                source: source,
                includeDismissedInScope: includeDismissedInScope,
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

// MARK: - Cover

/// A single carousel cover. It's a leaf view (not a method on the carousel) so
/// the `@Observable` `MusicLibraryService` playback reads stay scoped here: only
/// the centred, playing cover reads `playbackPosition` (the property a timer
/// ticks every 0.1–0.2s), so a progress tick re-renders just that one cover
/// instead of the whole carousel column. Side/paused covers never touch
/// `playbackPosition`, so they don't re-render with the ring.
private struct CoverCard: View {
    let song: Song
    let isCentered: Bool
    let coverSize: CGFloat
    let onTap: () -> Void

    var body: some View {
        let service = MusicLibraryService.shared
        let isPlayingThis = service.isPlayingPreview
            && service.nowPlayingSongID == song.id.rawValue

        Button(action: onTap) {
            ZStack {
                coverArtwork

                if isCentered {
                    // Read the ticking `playbackPosition` here, in the leaf, so
                    // only the centred playing cover re-renders on a progress
                    // tick. The 76pt ring sits just outside the 62pt disc's rim;
                    // `smoothingValue` eases the trim between the 0.2s ticks.
                    if isPlayingThis, service.playbackDuration > 0 {
                        PlaybackProgressRing(
                            progress: service.playbackPosition / service.playbackDuration,
                            size: 76,
                            smoothingValue: service.playbackPosition
                        )
                    }
                    // Passive overlay — the cover's own Button owns the tap.
                    GlassPlayPauseDisc(isPlaying: isPlayingThis, iconSize: 26, discSize: 62)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: coverSize, height: coverSize)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var coverArtwork: some View {
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

}
