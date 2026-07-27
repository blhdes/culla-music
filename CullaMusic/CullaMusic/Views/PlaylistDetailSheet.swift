import SwiftUI
import MusicKit
import UIKit

/// Tracklist sheet for a membership pill: tap a playlist tag on the swipe card
/// to see everything inside that playlist. Same sleeve language as
/// `AlbumDetailSheet` — cover hero, small-print line, monospaced rows with
/// right-aligned durations, tap-to-preview — plus the artist under each title,
/// since a playlist mixes artists where an album doesn't.
struct PlaylistDetailSheet: View {
    let playlist: Playlist
    /// Title of the song the sheet was opened from — that row reads accented,
    /// "you are here in this playlist". Matched by title because the swipe
    /// card's song ID (often a *library* ID) lives in a different namespace
    /// than the playlist's track IDs.
    let currentTitle: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var songs: [Song] = []
    @State private var loadState: LoadState = .loading

    private enum LoadState { case loading, loaded, failed }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(playlist.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task(id: playlist.id) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            PlaylistLoadingView()
        case .loaded:
            PlaylistTracklistView(
                playlist: playlist,
                songs: songs,
                currentTitle: currentTitle
            )
            .transition(.opacity)
        case .failed:
            PlaylistUnavailableView(name: playlist.name)
        }
    }

    private func load() async {
        loadState = .loading
        // A pill only exists for playlists that already hold this song, so the
        // Apple Music ID should always be there — the guard is a safety net.
        guard let idString = playlist.appleMusicPlaylistID else {
            loadState = .failed
            return
        }
        do {
            songs = try await MusicLibraryService.shared.loadPlaylistSongs(
                playlistID: MusicItemID(idString)
            )
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
                loadState = .loaded
            }
        } catch {
            print("PlaylistDetailSheet.load failed: \(error)")
            loadState = .failed
        }
    }
}

// MARK: - Tracklist (resolved)

private struct PlaylistTracklistView: View {
    let playlist: Playlist
    let songs: [Song]
    let currentTitle: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                    .padding(.horizontal, 20)
                tracklist
            }
            .padding(.vertical, 24)
        }
        .softScrollEdge()
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 14) {
            Group {
                if let idString = playlist.appleMusicPlaylistID,
                   let artwork = MusicLibraryService.shared.artwork(forPlaylistID: idString) {
                    ArtworkImage(artwork, width: 160, height: 160)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.thinMaterial)
                        .overlay(
                            Image(systemName: "music.note.list")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(width: 160, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            // Neutral depth shadow, no accent bloom — matches the album hero.
            .shadow(color: .black.opacity(0.22), radius: 18, y: 10)

            VStack(spacing: 6) {
                Text(playlist.name)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                Text(smallPrintLine)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "12 songs  ·  48:21" — count plus total runtime, runtime omitted while
    /// durations are unknown.
    private var smallPrintLine: String {
        var parts: [String] = [String(localized: "\(songs.count) songs")]
        let runtime = songs.reduce(0.0) { $0 + ($1.duration ?? 0) }
        if runtime > 0 { parts.append(Self.formatRuntime(runtime)) }
        return parts.joined(separator: "  ·  ")
    }

    private static func formatRuntime(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: Rows

    @ViewBuilder
    private var tracklist: some View {
        if songs.isEmpty {
            Text("No songs in this playlist yet.")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
        } else {
            // Rows sit flush edge-to-edge with inset hairline dividers — the
            // same flat sleeve treatment as the album sheet's tracklist.
            VStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { pair in
                    PlaylistTrackRow(
                        song: pair.element,
                        position: pair.offset + 1,
                        isCurrent: isCurrent(pair.element)
                    )
                    if pair.offset < songs.count - 1 {
                        Divider().padding(.leading, 58)
                    }
                }
            }
        }
    }

    private func isCurrent(_ song: Song) -> Bool {
        guard let currentTitle else { return false }
        let a = song.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !a.isEmpty && a == b
    }
}

// MARK: - Track row

/// One monospaced sleeve line: position, title with the artist beneath, an
/// optional playing indicator, and the duration right-aligned. Tapping toggles
/// a 30s preview through the shared player, so starting a row automatically
/// replaces whatever was playing — on this sheet or on the card behind it.
private struct PlaylistTrackRow: View {
    let song: Song
    let position: Int
    let isCurrent: Bool

    @Environment(\.appAccent) private var appAccent

    private var isPlaying: Bool {
        let service = MusicLibraryService.shared
        return service.isPlayingPreview && service.nowPlayingSongID == song.id.rawValue
    }

    var body: some View {
        Button {
            let service = MusicLibraryService.shared
            if isPlaying {
                service.stopPreview()
            } else {
                service.playPreview(for: song)
            }
        } label: {
            rowBody
        }
        .buttonStyle(.plain)
    }

    private var rowBody: some View {
        let accented = isCurrent || isPlaying
        return HStack(spacing: 14) {
            Text(String(format: "%02d", position))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(accented ? appAccent : .secondary)
                .frame(width: 24, alignment: .leading)

            // Title takes all the space the fixed columns leave (no competing
            // Spacer), so overflow measurement is exact and only the playing
            // row's title scrolls — same layout rule as the album rows.
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(
                    text: song.title,
                    uiFont: .monospacedSystemFont(
                        ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                        weight: .regular
                    ),
                    color: accented ? appAccent : .primary,
                    isActive: isPlaying
                )
                // Same marquee as the title: truncates at rest, scrolls to
                // reveal its full length while this row is previewing.
                MarqueeText(
                    text: song.artistName,
                    uiFont: .monospacedSystemFont(
                        ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
                        weight: .regular
                    ),
                    color: .secondary,
                    isActive: isPlaying
                )
            }

            // Fixed-width slot so the duration column never shifts when the
            // pause glyph appears on the playing row.
            ZStack {
                if isPlaying {
                    Image(systemName: "pause.fill")
                        .font(.caption2)
                        .foregroundStyle(appAccent)
                }
            }
            .frame(width: 12)

            Text(durationText)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var durationText: String {
        guard let duration = song.duration, duration > 0 else { return "--:--" }
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Loading / unavailable states

/// Content-shaped skeleton mirroring `PlaylistTracklistView`'s geometry — a
/// cover bone plus shimmering two-line rows — so the real sheet reveals in
/// place instead of sliding around a centered spinner.
private struct PlaylistLoadingView: View {
    private let titleWidths: [CGFloat] = [180, 132, 156, 120, 168, 110]

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                SkeletonShape(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .frame(width: 160, height: 160)
                SkeletonShape(shape: Capsule())
                    .frame(width: 150, height: 13)
                SkeletonShape(shape: Capsule())
                    .frame(width: 110, height: 9)
            }
            .padding(.horizontal, 20)

            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { index in
                    row(index: index)
                    if index < 5 {
                        Divider().padding(.leading, 58)
                    }
                }
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(index: Int) -> some View {
        HStack(spacing: 14) {
            SkeletonShape(shape: Capsule())
                .frame(width: 16, height: 11)
                .frame(width: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonShape(shape: Capsule())
                    .frame(width: titleWidths[index % titleWidths.count], height: 11)
                SkeletonShape(shape: Capsule())
                    .frame(width: titleWidths[(index + 3) % titleWidths.count] * 0.6, height: 8)
            }
            Spacer(minLength: 8)
            SkeletonShape(shape: Capsule())
                .frame(width: 30, height: 11)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }
}

private struct PlaylistUnavailableView: View {
    let name: String

    var body: some View {
        VStack(spacing: 16) {
            HeroIconTile(systemName: "music.note.list", size: 140, foreground: .secondary)
            Text(name)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .multilineTextAlignment(.center)
            Text("Couldn't load this playlist's songs.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
