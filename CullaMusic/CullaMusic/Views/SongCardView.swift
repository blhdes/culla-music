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
    /// Hero-morph namespace shared with Home's "Start Cullaing" button. Only
    /// the front (current) card receives it; the preloaded next card omits it
    /// so SwiftUI never sees two simultaneous sources for `heroStart`.
    var heroNamespace: Namespace.ID? = nil
    /// Gates the play-button overlay so it only appears once the artwork has
    /// finished its hero morph from "Start Cullaing". `.overlay` aligns to the
    /// view's *layout* frame, so without this the play button snaps to the
    /// final center position immediately while the cover is still morphing
    /// — making the button look unanchored from the cover during entry.
    var chromeRevealed: Bool = true

    @State private var scrubOverride: TimeInterval?
    @AppStorage("useHotPreview") private var useHotPreview: Bool = false
    @AppStorage("showAlbumOnHero") private var showAlbumOnHero: Bool = false

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
                        artwork(for: song, size: artworkSize)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                            // Only carry the matched-geometry hero while the
                            // morph is still running. Once it lands
                            // (`chromeRevealed`), drop it — a matched effect left
                            // active outlives its purpose and re-resolves the
                            // artwork's frame on every later re-render (e.g. a
                            // play/pause toggle opens an animation transaction via
                            // `progressOpacity`), which made the overlaid play
                            // button jump and snap back. On exit RootView flips
                            // `chromeRevealed` false again, re-arming it for the
                            // dismiss morph.
                            .matchedHero(id: "heroStart", in: chromeRevealed ? nil : heroNamespace)
                            .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
                            .overlay(alignment: .center) {
                                ZStack {
                                    if showHotProgressRing {
                                        hotProgressRing
                                    }
                                    playButton
                                }
                                // Pin to the ring's size (matches
                                // hotProgressRing's 86×86 frame) so this box
                                // never resizes when the ring is added or
                                // removed. Without it the box shrank 86→72 on
                                // pause (ring gone), and the centred play disc
                                // got re-resolved to a new position as it
                                // shrank — the long-unsolved "disc drifts
                                // bottom-right on pause" bug. It only repro'd
                                // with hot preview AND a preview that had played
                                // long enough for the ring to appear (the clip's
                                // duration loads a beat after play starts), so a
                                // quick manual play/pause never showed it —
                                // which is why it looked "autoplay-only".
                                .frame(width: 86, height: 86)
                                .opacity(chromeRevealed ? 1 : 0)
                                .scaleEffect(chromeRevealed ? 1 : 0.85)
                            }
                            .overlay(alignment: .bottom) { progressOverlay(width: artworkSize) }

                        timeLabels(width: artworkSize)
                            .opacity(progressOpacity)
                            // No implicit `.animation(value: progressOpacity)` here
                            // or on `progressOverlay`. When auto-play is on, the
                            // preview is playing, so pausing flips progressOpacity
                            // 1→0 and that fade was the ONLY animation transaction
                            // open during the toggle re-render — and the centred
                            // play disc's overlay position got re-resolved inside
                            // it, sliding the whole disc right+down before settling.
                            // (Confirmed: auto-play off = no playing preview = no
                            // fade = no jump.) Letting the show/hide be instant
                            // keeps the disc dead-still.

                        VStack(spacing: 6) {
                            Text(song.title)
                                .font(.title2.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)

                            if showAlbumOnHero, let album = song.albumTitle, !album.isEmpty {
                                let year = song.releaseDate.map { Calendar.current.component(.year, from: $0) }
                                Text(year.map { "@\(album) (\($0))" } ?? "@\(album)")
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

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
        Button(action: onTogglePlay) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 72, height: 72)
                // Order matters: glassSurface applied first sits closer to the
                // icon; the black scrim applied second lands further back.
                // Net stack: black → frosted glass → icon, giving a darkened
                // frosted disk that keeps the white icon readable on any
                // artwork (bright or dark).
                .glassSurface(in: Circle(), interactive: true)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var showHotProgressRing: Bool {
        useHotPreview && isPlaying && playbackDuration > 0
    }

    /// Circular progress trace around the play disc — only shown for the
    /// 30s hot-clip path, where the horizontal bar is intentionally hidden.
    /// Mirrors `HomeArtCarouselView.progressRing` so the swipe screen and
    /// the carousel feel like one family.
    private var hotProgressRing: some View {
        let progress = min(1.0, max(0, playbackPosition / playbackDuration))
        return Circle()
            .trim(from: 0, to: progress)
            .stroke(
                .white.opacity(0.92),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            // No implicit `.animation(value: playbackPosition)`. This ring is a
            // ZStack sibling of the play disc, so when pausing fires this 0.2s
            // transaction (playbackPosition → 0) the disc rode its layout pass
            // and slid before settling — the "only with auto-play / hot preview"
            // drift. The trim already updates ~10×/s from the clip observer, so
            // stepping it un-animated is imperceptible on a hairline ring.
            .frame(width: 86, height: 86)
            .allowsHitTesting(false)
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
        // Instant show/hide — see the note on `timeLabels`. The fade's
        // animation transaction was sliding the play disc on pause.
        .opacity(progressOpacity)
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
        !useHotPreview && isPlaying && playbackDuration > 0 ? 1 : 0
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
    /// point the gesture's release commits the swipe.
    @ViewBuilder
    private func armingIcon(systemName: String, progress: CGFloat) -> some View {
        let isArmed = progress >= 1.0
        Image(systemName: systemName)
            .font(.system(size: 60))
            .foregroundStyle(.white.opacity(0.85 * progress))
            .scaleEffect(0.7 + 0.4 * progress)
            .symbolEffect(.bounce, value: isArmed)
            .allowsHitTesting(false)
            .animation(.snappy(duration: 0.15), value: progress)
    }
}
