import SwiftUI
import MusicKit

struct SongCardView: View {
    let song: Song?
    let offset: CGSize
    let isPlaying: Bool
    let onTogglePlay: () -> Void

    private let swipeThreshold: CGFloat = 100

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(.systemBackground)

                if let song {
                    VStack(spacing: 28) {
                        artwork(for: song, size: min(geo.size.width * 0.78, 360))
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                            .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
                            .overlay(alignment: .center) { playButton }

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
            .offset(x: offset.width, y: offset.height * 0.4)
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

    private var cardOpacity: CGFloat {
        guard offset.width > 0 else { return 1.0 }
        return 1.0 - 0.3 * min(offset.width / swipeThreshold, 1.0)
    }

    @ViewBuilder
    private var swipeOverlay: some View {
        if offset.width < 0 {
            let progress = min(abs(offset.width) / swipeThreshold, 1.0)
            ZStack {
                Color.red.opacity(0.25 * progress)
                Image(systemName: "trash.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.white.opacity(0.8 * progress))
            }
            .allowsHitTesting(false)
        }
    }
}
