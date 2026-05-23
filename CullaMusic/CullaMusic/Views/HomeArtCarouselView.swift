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
/// - Tap **Start Cullaing** → opens `MusicSwipeView` seeded with the centred
///   song as its first card, so an already-playing preview keeps going.
/// - Tap the **dim backdrop** → returns to Home. The carousel band has a
///   vertical safe gutter so a near-miss release doesn't accidentally dismiss.
///
/// Scope (v1): only `.library`, `.unsorted`, `.dismissed`. Playlist/artist
/// sources are deferred — those screens have their own portrait vocabulary.
struct HomeArtCarouselView: View {
    let mode: ReviewMode
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

    @Environment(\.appAccent) private var appAccent
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

    private let coverSize: CGFloat = 280
    private let coverSpacing: CGFloat = 18
    /// Vertical padding above/below the carousel band that absorbs taps
    /// without dismissing. Stops a near-miss release from kicking the user
    /// back to Home mid-explore. Trimmed from 36 → 18 so the metadata
    /// strip below the carousel sits visually close to the cover.
    private let bandGutter: CGFloat = 18

    var body: some View {
        ZStack {
            // Opaque ambient backdrop — `HomeAmbientBackground` covers Home
            // entirely (its base is `Color(.systemBackground)`) so the page
            // below stops bleeding through. The soft glow tracks the centred
            // cover's dominant color, so the page tone shifts with whichever
            // album the user is exploring.
            HomeAmbientBackground(tint: ambientTint)

            // Tap-to-dismiss surface above the backdrop. Separate from the
            // ambient view because `HomeAmbientBackground.allowsHitTesting`
            // is false — it ignores taps so it doesn't compete with the
            // grain/glow rendering. This invisible layer is what actually
            // catches the dismiss tap. Sits at z-level below the VStack so
            // the strip / band / metadata / CTA can swallow their own taps.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
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
        .onAppear { runEntranceChoreography() }
        // Stop preview on exit so audio doesn't keep playing once the user
        // returns to Home — Home has no transport to surface or stop it.
        .onDisappear {
            service.stopPreview()
        }
    }

    // MARK: - Identity strip

    /// Breadcrumb above the carousel: mode name + the real song count for
    /// the current mode (passed in from HomeView). Falls back to the loaded
    /// page count with a `+` suffix while Home's count is still computing,
    /// so the strip never shows a misleadingly small number.
    private var identityStrip: some View {
        let (count, isPartial) = displayCount
        return CarouselIdentityStrip(
            mode: mode,
            count: count,
            isPartial: isPartial
        )
        .contentShape(Capsule())
        .onTapGesture { /* swallow — strip is a label, not a dismiss target */ }
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
        .contentShape(Rectangle())
        .onTapGesture { /* swallow — metadata sits in the safe band */ }
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
                // backdrop tap still dismisses.
                emptyPlaceholder
            }
        }
        // Safe gutter — vertical band around the carousel that absorbs taps.
        // Without it, lifting off just above/below the covers (common on a
        // fast scroll release) would fall through to the backdrop and
        // dismiss the user out by accident.
        .padding(.vertical, bandGutter)
        .contentShape(Rectangle())
        .onTapGesture { /* swallow — keep us inside the carousel */ }
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
        .shadow(color: .black.opacity(0.5), radius: 24, y: 18)
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

    // MARK: - Ambient tint

    /// Color the `HomeAmbientBackground` glow is keyed to. Tracks the centred
    /// cover's dominant artwork color so the page tone shifts as the user
    /// scrolls; falls back to the app accent before the first cover lands or
    /// when the artwork didn't expose a usable color.
    private var ambientTint: Color {
        guard
            let id = scrollPositionID,
            let song = feed?.songs.first(where: { $0.id.rawValue == id }),
            let cg = song.artwork?.backgroundColor
        else { return appAccent }
        return Color(cgColor: cg)
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
}
