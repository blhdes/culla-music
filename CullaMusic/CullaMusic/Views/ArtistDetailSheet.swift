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
            ArtistLoadingView(name: song.artistName)
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
    @State private var isReady = false
    @State private var showGoogle = false
    @State private var bioState: BioState = .loading
    @State private var showWikipedia = false
    @State private var bioExpanded = false
    @State private var bioIsTruncated = false

    /// True only while there's still hidden text to reveal. When the bio fits
    /// in the clamp (short bios) or is already expanded, the card's tap opens
    /// Wikipedia directly instead of doing a no-op "expand".
    private var bioCanExpand: Bool { bioIsTruncated && !bioExpanded }
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `empty` (no/likely-wrong Wikipedia page) hides the section silently;
    /// `failed` (network/decode error) is transient, so it shows a retry row.
    private enum BioState {
        case loading
        case loaded(ArtistBioService.ArtistBio)
        case empty
        case failed
    }

    /// Falls back to the seed `artist` until `detail` (with relationships)
    /// arrives; that way the hero / genres render instantly while top songs
    /// and similar artists fade in.
    private var current: Artist { detail ?? artist }

    private var googleURL: URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: artist.name)]
        return components?.url
    }

    /// Direct catalog page when we have one; otherwise an Apple Music search
    /// for the artist, so the button always resolves — library-only artists
    /// have no catalog `url`. Both are universal links that open Apple Music.
    private var appleMusicURL: URL {
        if let url = current.url { return url }
        var components = URLComponents(string: "https://music.apple.com/search")
        components?.queryItems = [URLQueryItem(name: "term", value: artist.name)]
        return components?.url ?? URL(string: "https://music.apple.com")!
    }

    var body: some View {
        Group {
            if isReady {
                content
                    .transition(.opacity)
            } else {
                // Same branded loading view the root sheet shows during
                // resolution — so the breathing hero + name stays put across
                // resolve → detail and on every similar-artist push, then
                // crossfades to the assembled sheet in one beat.
                ArtistLoadingView(name: artist.name)
                    .transition(.opacity)
            }
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: artist.id.rawValue) { await loadDetail() }
        .task(id: artist.id.rawValue) { await loadBio() }
        .sheet(isPresented: $showGoogle) {
            if let googleURL {
                SafariView(url: googleURL)
                    .ignoresSafeArea()
            }
        }
    }

    private var content: some View {
        ScrollView {
            // Horizontal padding is applied per-section instead of on this
            // outer VStack so the genre chips and similar-artists carousels
            // can bleed to the screen edges via `.contentMargins(.horizontal:)`.
            // The previous outer 20pt inset clipped both scrolls and made the
            // top-songs card float instead of feeling like a full surface.
            VStack(spacing: 28) {
                hero
                    .padding(.horizontal, 20)
                if !(current.genreNames ?? []).isEmpty { genreChips }
                bioSection
                topSongsSection
                similarArtistsSection
                HStack(spacing: 12) {
                    googleButton
                    appleMusicButton(url: appleMusicURL)
                }
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 20)
        }
    }

    // MARK: Sections

    private var hero: some View {
        VStack(spacing: 16) {
            Group {
                if let artwork = current.artwork {
                    ArtworkImage(artwork, width: 220, height: 220)
                } else {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.thinMaterial)
                        .overlay(
                            Image(systemName: "music.mic")
                                .font(.system(size: 56, weight: .light))
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(width: 220, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: heroShadow, radius: 24, y: 12)

            Text(current.name)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .multilineTextAlignment(.center)
        }
    }

    /// Neutral depth shadow — slightly deeper when we have artwork so the hero
    /// lifts off the page, lighter for the placeholder. No accent tint; the
    /// artwork carries its own colour.
    private var heroShadow: Color {
        current.artwork == nil ? .black.opacity(0.18) : .black.opacity(0.28)
    }

    private var genreChips: some View {
        // `.contentMargins(.horizontal: 20)` insets the *content* without
        // insetting the scroll bounds — that way chips scroll out to the
        // screen edge as the user pages through them, instead of getting
        // clipped at a 20pt inset. This was the root cause of the "white
        // margins breaking continuity" feedback.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(current.genreNames ?? [], id: \.self) { genre in
                    Text(genre)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .padding(.vertical, 7)
                        .padding(.horizontal, 14)
                        .glassSurface(in: Capsule())
                }
            }
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
    }

    @ViewBuilder
    private var bioSection: some View {
        switch bioState {
        case .empty, .loading:
            // No spinner. The bio is supplementary, so it stays absent while it
            // loads (the sheet already revealed on the music data) and fades in
            // when it lands. `.empty` (no page / likely-wrong match) stays
            // hidden for good.
            EmptyView()
        case .loaded(let bio):
            VStack(spacing: 12) {
                sectionHeader("About")
                Button {
                    // First tap expands (one-way — never collapses back);
                    // once fully shown, the next tap opens the article.
                    if bioCanExpand {
                        withAnimation(.easeInOut(duration: 0.25)) { bioExpanded = true }
                    } else {
                        showWikipedia = true
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(bio.extract)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(bioExpanded ? nil : 4)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                            .background {
                                // Render a hidden full-length copy behind the
                                // clamped text. ViewThatFits uses it when it
                                // fits; otherwise the clear fallback flags the
                                // bio as truncated so we show "More".
                                if !bioExpanded {
                                    ViewThatFits(in: .vertical) {
                                        Text(bio.extract).font(.callout).hidden()
                                        Color.clear.onAppear { bioIsTruncated = true }
                                    }
                                }
                            }
                        if let descriptor = bio.descriptor {
                            Text(descriptor)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Image(systemName: bioCanExpand ? "chevron.down" : "arrow.up.right")
                                .contentTransition(.symbolEffect(.replace))
                            Text(bioCanExpand ? "More" : "Read on Wikipedia")
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showWikipedia) {
                    SafariView(url: bio.pageURL).ignoresSafeArea()
                }
            }
            .padding(.horizontal, 20)
            .transition(.opacity)
        case .failed:
            VStack(spacing: 12) {
                sectionHeader("About")
                HStack {
                    Text("Couldn't load bio.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { Task { await loadBio() } }
                        .font(.footnote.weight(.semibold))
                }
            }
            .padding(.horizontal, 20)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var topSongsSection: some View {
        let songs = Array((current.topSongs ?? []).prefix(5))
        let service = MusicLibraryService.shared
        if !songs.isEmpty {
            VStack(spacing: 12) {
                sectionHeader("Top Songs")
                    .padding(.horizontal, 20)
                VStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        let isPlayingThis = service.isPlayingPreview &&
                                            service.nowPlayingSongID == song.id.rawValue
                        Button {
                            if isPlayingThis {
                                service.stopPreview()
                            } else {
                                service.playPreview(for: song)
                            }
                        } label: {
                            TopSongRow(song: song, isPlaying: isPlayingThis)
                        }
                        .buttonStyle(.plain)
                        if index < songs.count - 1 {
                            Divider().padding(.leading, 76)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var similarArtistsSection: some View {
        let similar = Array((current.similarArtists ?? []).prefix(10))
        if !similar.isEmpty {
            VStack(spacing: 12) {
                sectionHeader("Similar Artists")
                    .padding(.horizontal, 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(similar, id: \.id) { other in
                            NavigationLink(value: other) {
                                SimilarArtistTile(artist: other)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                // contentMargins (not outer padding) so the carousel scrolls
                // tiles out to the screen edge — the previous outer inset
                // clipped them and the row looked truncated on both sides.
                .contentMargins(.horizontal, 20, for: .scrollContent)
            }
        }
    }

    private var googleButton: some View {
        GoogleSearchButton { showGoogle = true }
            .disabled(googleURL == nil)
            .frame(maxWidth: .infinity)
    }

    private func appleMusicButton(url: URL) -> some View {
        AppleMusicLinkButton { openURL(url) }
            .frame(maxWidth: .infinity)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.bold))
            Spacer()
        }
    }

    private func loadDetail() async {
        if detail?.id == artist.id {
            isReady = true
            return
        }
        do {
            detail = try await MusicLibraryService.shared.loadArtistDetail(artist)
        } catch {
            // Reveal anyway: the seed artist still carries the hero, name, and
            // genres, so a failed relationship fetch degrades to a thinner
            // sheet rather than a permanent loading state.
            print("ArtistDetailView.loadDetail failed: \(error)")
        }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) {
            isReady = true
        }
    }

    private func loadBio() async {
        bioState = .loading
        do {
            if let bio = try await ArtistBioService.shared.bio(forName: artist.name) {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                    bioState = .loaded(bio)
                }
            } else {
                bioState = .empty
            }
        } catch {
            print("ArtistDetailView.loadBio failed: \(error)")
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                bioState = .failed
            }
        }
    }
}

// MARK: - Subviews
// `ArtistLoadingView` (the shared loading skeleton) now lives in
// `ArtistLoadingSkeleton.swift` — both this sheet and the inner detail view
// call `ArtistLoadingView(name:)` unchanged.

private struct TopSongRow: View {
    let song: Song
    let isPlaying: Bool

    @Environment(\.appAccent) private var appAccent

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
                    .foregroundStyle(isPlaying ? appAccent : .primary)
                    .lineLimit(1)
                if let album = song.albumTitle {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.footnote)
                .foregroundStyle(isPlaying ? appAccent : .secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 20)
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

/// Apple's official "Listen on Apple Music" lockup. Per identity guidelines
/// the artwork must not be modified, recolored, or combined with custom text,
/// so we render it as a single tappable image — no surrounding pill, no extra
/// label. Sits in an equal-width 48pt slot to pair with the Google button;
/// the badge scales to fit, staying above the 30px digital minimum.
private struct AppleMusicLinkButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image("apple-music-badge")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Listen on Apple Music")
    }
}

private struct GoogleSearchButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image("google-g")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                Text("Google")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                Capsule().fill(Color(.secondarySystemBackground))
            )
            .overlay(
                Capsule().strokeBorder(.quaternary, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct FallbackArtistView: View {
    let name: String
    @State private var showGoogle = false
    @Environment(\.openURL) private var openURL

    private var googleURL: URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: name)]
        return components?.url
    }

    /// Apple Music search for the artist — there's no catalog entity here, but
    /// the link still opens the app to the artist's results, so the action is
    /// always available (matches the resolved hub's footer).
    private var appleMusicURL: URL {
        var components = URLComponents(string: "https://music.apple.com/search")
        components?.queryItems = [URLQueryItem(name: "term", value: name)]
        return components?.url ?? URL(string: "https://music.apple.com")!
    }

    var body: some View {
        VStack(spacing: 22) {
            HeroIconTile(
                systemName: "music.mic",
                size: 168,
                foreground: .secondary
            )
            Text(name)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .multilineTextAlignment(.center)
            Text("No detailed info from Apple Music for this artist.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                GoogleSearchButton { showGoogle = true }
                    .disabled(googleURL == nil)
                AppleMusicLinkButton { openURL(appleMusicURL) }
            }
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
