import SwiftUI
import MusicKit

struct SongCardView: View {
    let song: Song?
    let offset: CGSize
    let isPlaying: Bool
    let playbackPosition: TimeInterval
    let playbackDuration: TimeInterval
    let memberships: [Playlist]
    var isLoadingMemberships: Bool = false
    var dismissedAt: Date? = nil
    let onTogglePlay: () -> Void
    let onSeek: (TimeInterval) -> Void
    /// Optional — when set and the card is settled (no active drag), shows a
    /// small info button next to the artist name. Not wired on the next-card
    /// (underneath) instance so the button never appears on the obscured card.
    var onShowArtist: (() -> Void)? = nil
    /// Optional — when set and the card is settled, shows a small info button
    /// next to the inline album label that opens the album's liner-notes sheet.
    /// Like `onShowArtist`, only wired on the front card so it never appears on
    /// the obscured next card or while a drag is in flight.
    var onShowAlbum: (() -> Void)? = nil
    /// Fires `true` the moment the progress bar's scrub begins and `false` when
    /// it ends. MusicSwipeView uses it to freeze the card's drag-to-sort while
    /// the user moves through the song, so a horizontal scrub never doubles as
    /// a dismiss/assign swipe. Only wired on the front card.
    var onScrubbingChanged: ((Bool) -> Void)? = nil
    /// Gates the play-button reveal so it appears as a consequence of the
    /// session-entry crossfade landing (driven from `RootView` via
    /// `withAnimation(completion:)`) rather than popping in with the card.
    var chromeRevealed: Bool = true
    /// True while this card is being set aside — a double-tap skip or the
    /// session's back-button exit. Drives the artwork-tile recede: the cover —
    /// the one element with a visible boundary (rounded corners + shadow) —
    /// shrinks in place while the text and controls only fade, holding their
    /// standing positions. Whole-card geometry moves read as element drift on
    /// this full-screen layout, so the recede is scoped to the tile (see
    /// `MusicSwipeView.skipFadesOut`). Only wired on the front card; inert
    /// under Reduce Motion.
    var tileReceding: Bool = false
    /// True while the session's first card is arriving — the inverse of the
    /// recede. The tile opens slightly small (0.92) and settles forward to
    /// full size inside the same crossfade that brings the card in, so the
    /// deck reads as coming forward to meet you rather than switching on.
    /// Gentler than the recede's 0.88 because it rides a longer, quieter
    /// fade. Only wired on the front card; inert under Reduce Motion.
    var tileApproaching: Bool = false

    @State private var scrubOverride: TimeInterval?
    @AppStorage("useHotPreview") private var useHotPreview: Bool = false
    @AppStorage("showAlbumOnHero") private var showAlbumOnHero: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Namespace for the swipe arming chip: at the commit threshold a glass coin
    /// crystallizes behind the trash/heart inside its container. Inert < iOS 26.
    @Namespace private var armNS

    private let swipeThreshold: CGFloat = 100

    /// Vertical translation is shown at this fraction of the raw value so
    /// dragging up doesn't yank the card off-screen. `MusicSwipeView.flyOff`
    /// pre-divides by this when animating the up-swipe so the card still
    /// clears the screen during the Loved transition.
    static let yVisualDamping: CGFloat = 0.4

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(.systemBackground)

                if let song {
                    let artworkSize = min(geo.size.width * 0.78, 360)

                    VStack(spacing: 18) {
                        // The artwork and its centred controls share one ZStack,
                        // but the controls are a *sibling* of the artwork — never
                        // an `.overlay` on it. The artwork hosts the progress
                        // overlay, and when that chrome fades (play↔pause), an
                        // overlay-based disc had its centre re-resolved inside the
                        // same animation transaction and slid bottom-right. As a
                        // sibling the disc is positioned by this ZStack on its own,
                        // so the bar can now fade gracefully without moving it.
                        ZStack {
                            artwork(for: song, size: artworkSize)
                                .clipShape(RoundedRectangle(cornerRadius: 24))
                                .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
                                .overlay(alignment: .bottom) { progressOverlay(width: artworkSize) }

                            ZStack {
                                if showHotProgressRing {
                                    hotProgressRing
                                }
                                playButton
                            }
                            // Pin to the ring's size (matches hotProgressRing's
                            // 86×86 frame) so this box never resizes when the ring
                            // is added or removed — a resizing box re-resolved the
                            // centred disc's position (the old "disc drifts on
                            // pause" bug).
                            .frame(width: 86, height: 86)
                            .opacity(chromeRevealed ? 1 : 0)
                            .scaleEffect(chromeRevealed ? 1 : 0.85)
                        }
                        // Pin the ZStack to the artwork's size so the disc always
                        // centres on the cover and the box can't be stretched by a
                        // child.
                        .frame(width: artworkSize, height: artworkSize)
                        // Tile choreography: the cover (plus its riding disc/
                        // progress chrome) scales about its own centre while
                        // the card fades — receding when set aside (skip, back
                        // exit), settling forward on session entry. The tile's
                        // visible boundary is what makes this read as motion
                        // of a *thing*, not element drift. A rendering
                        // transform only, so the disc's centred position is
                        // never re-resolved (the old drift bug).
                        .scaleEffect(tileScale)

                        timeLabels(width: artworkSize)
                            .opacity(progressOpacity)
                            // Safe to fade now that the disc is a ZStack sibling
                            // (see the note above) — this transaction no longer
                            // re-resolves the disc's centre. 0→0.55→1 covers
                            // hidden → paused-dim → playing.
                            .animation(.easeInOut(duration: 0.3), value: progressOpacity)

                        VStack(spacing: 6) {
                            Text(song.title)
                                .font(.title2.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)

                            albumRow(for: song)

                            artistRow(for: song)

                            PlaylistMembershipChips(
                                playlists: memberships,
                                dismissedAt: dismissedAt,
                                isLoading: isLoadingMemberships
                            )
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 40)
                }

                swipeOverlay
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .opacity(cardOpacity)
            .rotationEffect(.degrees(Double(offset.width / 40)))
            .offset(x: offset.width, y: offset.height * Self.yVisualDamping)
            .clipped()
        }
        .ignoresSafeArea()
        // scrubOverride is non-nil only while a scrub drag is live, so this
        // mirrors the bar's gesture without ProgressBarView needing to know
        // about the card stack above it.
        .onChange(of: scrubOverride != nil) { _, scrubbing in
            onScrubbingChanged?(scrubbing)
        }
    }

    /// Inline album line (`@Album (Year)`) with an optional info button that
    /// opens the album's liner-notes sheet. Mirrors `artistRow`: the button only
    /// shows on the top, settled card so it can't fight the swipe gesture, and
    /// the whole row is hidden unless "Show album on cards" is on.
    @ViewBuilder
    private func albumRow(for song: Song) -> some View {
        if showAlbumOnHero, let album = song.albumTitle, !album.isEmpty {
            let year = song.releaseDate.map { Calendar.current.component(.year, from: $0) }
            let canShowInfo = (onShowAlbum != nil) && offset == .zero

            HStack(spacing: 6) {
                Text(year.map { "@\(album) (\($0))" } ?? "@\(album)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if canShowInfo {
                    Button {
                        onShowAlbum?()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(4)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Album info")
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: canShowInfo)
        }
    }

    /// Artist name + an optional info button to open the artist hub. The info
    /// button only appears on the top, settled card (no active drag) so it
    /// can't fight the swipe gesture and never shows on the obscured next card.
    @ViewBuilder
    private func artistRow(for song: Song) -> some View {
        let canShowInfo = (onShowArtist != nil) && offset == .zero

        HStack(spacing: 6) {
            Text(song.artistName)
                .font(.headline.weight(.regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if canShowInfo {
                Button {
                    onShowArtist?()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Artist info")
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: canShowInfo)
    }

    @ViewBuilder
    private func artwork(for song: Song, size: CGFloat) -> some View {
        if let artwork = song.artwork {
            ArtworkImage(artwork, width: size, height: size)
                .frame(width: size, height: size)
        } else {
            artworkFallback
                .frame(width: size, height: size)
        }
    }

    private var artworkFallback: some View {
        Rectangle()
            .fill(.gray.opacity(0.2))
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 60))
                    .foregroundStyle(.secondary)
            )
    }

    private var playButton: some View {
        // Shared visual; the swipe card owns the tap via this Button. See
        // `GlassPlayPauseDisc` for the load-bearing black → glass → icon order.
        Button(action: onTogglePlay) {
            GlassPlayPauseDisc(isPlaying: isPlaying, iconSize: 30, discSize: 72)
        }
        .buttonStyle(.plain)
    }

    private var showHotProgressRing: Bool {
        useHotPreview && isPlaying && playbackDuration > 0
    }

    /// Circular progress trace around the play disc — only shown for the 30s
    /// hot-clip path, where the horizontal bar is intentionally hidden. Shares
    /// `PlaybackProgressRing` with the carousel; `smoothingValue: nil` keeps the
    /// trim un-animated here (it already updates ~10×/s from the clip observer,
    /// and an implicit animation would only add a transaction next to the disc).
    private var hotProgressRing: some View {
        PlaybackProgressRing(
            progress: playbackPosition / playbackDuration,
            size: 86
        )
    }

    // Gradient scrim → bar reads against any artwork. Clipped to the artwork's
    // bottom corners so it doesn't poke out as a square block.
    @ViewBuilder
    private func progressOverlay(width: CGFloat) -> some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.28)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: width, height: 44)
        .clipShape(
            UnevenRoundedRectangle(
                cornerRadii: .init(bottomLeading: 24, bottomTrailing: 24)
            )
        )
        .allowsHitTesting(false)
        .overlay(alignment: .bottom) {
            ProgressBarView(
                position: playbackPosition,
                duration: playbackDuration,
                scrubOverride: $scrubOverride,
                onSeek: onSeek
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        // Fades with the same envelope as the time labels. Safe now that the
        // disc is a ZStack sibling rather than an overlay on this artwork.
        .opacity(progressOpacity)
        .animation(.easeInOut(duration: 0.3), value: progressOpacity)
        // Only claim touches while the bar is actually shown (loaded: playing or
        // paused). Opacity 0 still receives hits in SwiftUI, so without this the
        // invisible bar's scrub region would hijack card swipes that start in
        // the bottom strip of the cover when nothing is loaded.
        .allowsHitTesting(progressOpacity > 0)
    }

    private func timeLabels(width: CGFloat) -> some View {
        let displayed = scrubOverride ?? playbackPosition
        let remaining = max(playbackDuration - displayed, 0)
        return HStack {
            Text(format(displayed))
            Spacer()
            Text("-\(format(remaining))")
        }
        .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: width)
        .padding(.horizontal, 4)
    }

    private func format(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "0:00" }
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var progressOpacity: Double {
        // 30s hot-clip previews speak for themselves — no bar needed.
        // `playbackDuration > 0` means this song is loaded (the parent only
        // feeds a non-zero duration for the loaded card), so the bar stays
        // visible while paused — just dimmed — letting the user see and scrub
        // the saved position. Full opacity only while actually playing.
        guard !useHotPreview, playbackDuration > 0 else { return 0 }
        return isPlaying ? 1.0 : 0.55
    }

    /// Scale for the artwork tile's set-aside / arrival choreography. Recede
    /// wins when both flags are up (backing out mid-entry keeps receding
    /// instead of snapping forward). Reduce Motion pins it to 1.0 — the
    /// crossfades alone carry the transition.
    private var tileScale: CGFloat {
        guard !reduceMotion else { return 1.0 }
        if tileReceding { return 0.88 }
        if tileApproaching { return 0.92 }
        return 1.0
    }

    private var cardOpacity: CGFloat {
        guard offset.width > 0 else { return 1.0 }
        return 1.0 - 0.3 * min(offset.width / swipeThreshold, 1.0)
    }

    @ViewBuilder
    private var swipeOverlay: some View {
        // Dominant-axis gating mirrors the gesture's direction lock so the
        // overlays don't double up on diagonal drags.
        let horizontalDominant = abs(offset.width) >= abs(offset.height)

        // Sidebar deadzone — once the card has moved right past this, the
        // user is engaging the sidebar and neither the trash nor the heart
        // overlay should fire even if vertical motion later dominates.
        let sidebarDeadzone: CGFloat = 35

        if horizontalDominant, offset.width < 0 {
            let progress = min(abs(offset.width) / swipeThreshold, 1.0)
            armingIcon(systemName: "trash.fill", progress: progress)
        } else if !horizontalDominant, offset.height < 0, offset.width < sidebarDeadzone {
            let progress = min(abs(offset.height) / swipeThreshold, 1.0)
            armingIcon(systemName: "heart.fill", progress: progress)
        }
    }

    /// Swipe-action overlay icon that scales up as the gesture approaches the
    /// commit threshold and fires a one-shot bounce the instant it crosses.
    /// The bounce is the moment the user feels the action "arm" — past this
    /// point the gesture's release commits the swipe. At that instant a glass
    /// coin crystallizes behind the glyph (iOS 26) so "armed" reads as a
    /// material forming, not just a bigger icon.
    @ViewBuilder
    private func armingIcon(systemName: String, progress: CGFloat) -> some View {
        let isArmed = progress >= 1.0
        // GlassStack supplies the stable GlassEffectContainer the coin
        // materializes inside; one ZStack child, so the layout is unchanged.
        GlassStack(spacing: 0) {
            ZStack {
                if isArmed {
                    Color.clear
                        .frame(width: 112, height: 112)
                        .glassSurface(in: Circle())
                        .glassMorphID("arm.disc", in: armNS)
                        .glassMorphTransition(.materialize, reduceMotion: reduceMotion)
                }
                Image(systemName: systemName)
                    .font(.system(size: 60))
                    .foregroundStyle(.white.opacity(0.85 * progress))
                    // Dark disc keyed to the swipe's progress so the white
                    // glyph stays readable on a light cover — mirrors the play
                    // button's scrim. Padding gives the circle room around the
                    // glyph; ramped (not constant) so there's no dark blob
                    // behind the near-invisible icon early in the drag.
                    .padding(22)
                    .background(.black.opacity(0.35 * progress), in: Circle())
                    .scaleEffect(0.7 + 0.4 * progress)
                    .symbolEffect(.bounce, value: isArmed)
            }
        }
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.15), value: progress)
    }
}
