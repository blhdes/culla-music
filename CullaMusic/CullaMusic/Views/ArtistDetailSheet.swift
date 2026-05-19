import SwiftUI
import MusicKit

/// Hub sheet for an artist, opened from the info button on the swipe card.
///
/// Resolves `song.artistName` to a catalog `Artist` first (so library-only or
/// uploaded tracks still get rich data via name search), then hands off to
/// `ArtistDetailView` for rendering. Wrapped in a `NavigationStack` so
/// similar-artist taps can push deeper without dismissing back to the swipe
/// deck — drilling Artist A → B → C → back is the discovery flow.
struct ArtistDetailSheet: View {
    let song: Song

    @Environment(\.dismiss) private var dismiss
    @State private var resolvedArtist: Artist?
    @State private var resolutionState: ResolutionState = .loading

    private enum ResolutionState { case loading, resolved, failed }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(song.artistName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .navigationDestination(for: Artist.self) { artist in
                    ArtistDetailView(artist: artist)
                }
        }
        .task(id: song.id.rawValue) { await resolve() }
    }

    @ViewBuilder
    private var content: some View {
        switch resolutionState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .resolved:
            if let resolvedArtist {
                ArtistDetailView(artist: resolvedArtist)
            }
        case .failed:
            FallbackArtistView(name: song.artistName)
        }
    }

    private func resolve() async {
        resolutionState = .loading
        resolvedArtist = nil
        do {
            if let artist = try await MusicLibraryService.shared.resolveArtist(for: song) {
                resolvedArtist = artist
                resolutionState = .resolved
            } else {
                resolutionState = .failed
            }
        } catch {
            print("ArtistDetailSheet.resolve failed: \(error)")
            resolutionState = .failed
        }
    }
}

// MARK: - Detail (per-artist content, reusable for pushed similar artists)

/// Inner view that fetches `topSongs` and `similarArtists` for its seed
/// `Artist`. Used both as the root view (after song→artist resolution) and as
/// the destination view for similar-artist navigation pushes — so drilling
/// further re-runs the detail fetch for the newly-pushed artist.
private struct ArtistDetailView: View {
    let artist: Artist

    @State private var detail: Artist?
    @State private var isLoadingDetail = true
    @State private var showGoogle = false

    /// Falls back to the seed `artist` until `detail` (with relationships)
    /// arrives; that way the hero / genres render instantly while top songs
    /// and similar artists fade in.
    private var current: Artist { detail ?? artist }

    private var googleURL: URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: artist.name)]
        return components?.url
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                if !(current.genreNames ?? []).isEmpty { genreChips }
                topSongsSection
                similarArtistsSection
                googleButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: artist.id.rawValue) { await loadDetail() }
        .sheet(isPresented: $showGoogle) {
            if let googleURL {
                SafariView(url: googleURL)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: Sections

    private var hero: some View {
        VStack(spacing: 14) {
            Group {
                if let artwork = current.artwork {
                    ArtworkImage(artwork, width: 220, height: 220)
                } else {
                    Circle()
                        .fill(.quaternary)
                        .overlay(
                            Image(systemName: "music.mic")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(width: 220, height: 220)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)

            Text(current.name)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
        }
    }

    private var genreChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(current.genreNames ?? [], id: \.self) { genre in
                    Text(genre)
                        .font(.caption.weight(.medium))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var topSongsSection: some View {
        let songs = Array((current.topSongs ?? []).prefix(5))
        if isLoadingDetail && songs.isEmpty {
            sectionHeader("Top Songs")
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } else if !songs.isEmpty {
            sectionHeader("Top Songs")
            VStack(spacing: 0) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    Button {
                        MusicLibraryService.shared.playPreview(for: song)
                    } label: {
                        TopSongRow(song: song)
                    }
                    .buttonStyle(.plain)
                    if index < songs.count - 1 {
                        Divider().padding(.leading, 68)
                    }
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private var similarArtistsSection: some View {
        let similar = Array((current.similarArtists ?? []).prefix(10))
        if !similar.isEmpty {
            sectionHeader("Similar Artists")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(similar, id: \.id) { other in
                        NavigationLink(value: other) {
                            SimilarArtistTile(artist: other)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var googleButton: some View {
        GoogleSearchButton { showGoogle = true }
            .disabled(googleURL == nil)
            .frame(maxWidth: .infinity)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
        }
    }

    private func loadDetail() async {
        if detail?.id == artist.id { return }
        isLoadingDetail = true
        do {
            detail = try await MusicLibraryService.shared.loadArtistDetail(artist)
        } catch {
            print("ArtistDetailView.loadDetail failed: \(error)")
        }
        isLoadingDetail = false
    }
}

// MARK: - Subviews

private struct TopSongRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let artwork = song.artwork {
                    ArtworkImage(artwork, width: 44, height: 44)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let album = song.albumTitle {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "play.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

private struct SimilarArtistTile: View {
    let artist: Artist

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let artwork = artist.artwork {
                    ArtworkImage(artwork, width: 92, height: 92)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay(
                            Image(systemName: "music.mic")
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(width: 92, height: 92)
            .clipShape(Circle())

            Text(artist.name)
                .font(.caption)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 104)
        }
    }
}

private struct GoogleSearchButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image("google-g")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                Text("Search on Google")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 20)
            .background(
                Capsule().fill(Color(.secondarySystemBackground))
            )
            .overlay(
                Capsule().strokeBorder(.quaternary, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }
}

private struct FallbackArtistView: View {
    let name: String
    @State private var showGoogle = false

    private var googleURL: URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: name)]
        return components?.url
    }

    var body: some View {
        VStack(spacing: 22) {
            Circle()
                .fill(.quaternary)
                .frame(width: 180, height: 180)
                .overlay(
                    Image(systemName: "music.mic")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                )
            Text(name)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("No detailed info from Apple Music for this artist.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            GoogleSearchButton { showGoogle = true }
                .disabled(googleURL == nil)
        }
        .padding()
        .sheet(isPresented: $showGoogle) {
            if let googleURL {
                SafariView(url: googleURL)
                    .ignoresSafeArea()
            }
        }
    }
}
