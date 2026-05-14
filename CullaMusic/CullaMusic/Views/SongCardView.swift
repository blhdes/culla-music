import SwiftUI
import MusicKit

struct SongCardView: View {
    let song: Song?
    let offset: CGSize
    let isPlaying: Bool
    let playbackPosition: TimeInterval
    let playbackDuration: TimeInterval
    let memberships: [Playlist]
    var dismissedAt: Date? = nil
    let onTogglePlay: () -> Void
    let onSeek: (TimeInterval) -> Void

    @State private var scrubOverride: TimeInterval?
    @AppStorage("useHotPreview") private var useHotPreview: Bool = false

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
                            .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
                            .overlay(alignment: .center) { playButton }
                            .overlay(alignment: .bottom) { progressOverlay(width: artworkSize) }

                        timeLabels(width: artworkSize)
                            .opacity(progressOpacity)
                            .animation(.easeInOut(duration: 0.35), value: progressOpacity)

                        VStack(spacing: 6) {
                            Text(song.title)
                                .font(.title2.weight(.semibold))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)

                            Text(song.artistName)
                                .font(.headline.weight(.regular))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(1)

                            PlaylistMembershipChips(
                                playlists: memberships,
                                dismissedAt: dismissedAt
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

    @ViewBuilder
    private func artwork(for song: Song, size: CGFloat) -> some View {
        if let artwork = song.artwork {
            ArtworkImage(artwork, width: size, height: size)
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
                .frame(width: 72, height: 72)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
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
        .opacity(progressOpacity)
        .animation(.easeInOut(duration: 0.35), value: progressOpacity)
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
            ZStack {
                Color.red.opacity(0.25 * progress)
                Image(systemName: "trash.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.white.opacity(0.8 * progress))
            }
            .allowsHitTesting(false)
        } else if !horizontalDominant, offset.height < 0, offset.width < sidebarDeadzone {
            let progress = min(abs(offset.height) / swipeThreshold, 1.0)
            ZStack {
                Color.pink.opacity(0.25 * progress)
                Image(systemName: "heart.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.white.opacity(0.8 * progress))
            }
            .allowsHitTesting(false)
        }
    }
}
