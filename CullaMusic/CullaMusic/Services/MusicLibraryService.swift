import AVFoundation
import Foundation
import MusicKit

/// True if `amPlaylist` accepts programmatic writes via `MusicLibrary.shared.add(...)`.
/// Editorial / external / personalMix / replay are stamped by Apple as read-only.
/// The smart "Favorites" playlist (populated by the Apple Music heart button)
/// has `kind=nil` / `curatorName=nil` — identical to a user-made playlist — so
/// it can only be flagged by name. Add new locales below as we discover them;
/// callers also stickily downgrade any playlist that a write actually fails
/// against, so unknown locales heal themselves on first use.
func computeEditability(for amPlaylist: MusicKit.Playlist) -> Bool {
    switch amPlaylist.kind {
    case .editorial, .external, .personalMix, .replay:
        return false
    default:
        return !smartFavoritesNames.contains(amPlaylist.name)
    }
}

/// Localized names of Apple Music's system "Favorite Songs" playlist.
/// Detection is name-based because the playlist's metadata is identical to a
/// user-made one. New locales can be added here; missed ones self-heal via
/// the write-failure path in the up-swipe Loved action.
let smartFavoritesNames: Set<String> = [
    "Favorite Songs",         // en
    "Favorites",              // en (alt / older)
    "Favourites",             // en-GB
    "Favourite Songs",        // en-GB (alt)
    "Canciones favoritas",    // es
    "Favoritos",              // es (alt / iOS 18+)
    "Mis favoritos",          // es (alt)
    "Morceaux favoris",       // fr
    "Titres favoris",         // fr (alt)
    "Favoris",                // fr (alt / iOS 18+)
    "Lieblingstitel",         // de
    "Lieblingssongs",         // de (alt)
    "Brani preferiti",        // it
    "Canzoni preferite",      // it (alt)
    "Músicas favoritas",      // pt
    "お気に入りの曲",            // ja
    "좋아하는 노래",             // ko
    "喜爱的歌曲",                // zh-Hans
    "喜愛的歌曲",                // zh-Hant
    "Любимые песни",           // ru
    "Favoriete nummers",      // nl
]

@Observable
@MainActor
final class MusicLibraryService {
    static let shared = MusicLibraryService()

    // Observable state
    var authorizationStatus: MusicAuthorization.Status = MusicAuthorization.currentStatus
    var isPlayingPreview: Bool = false
    var nowPlayingSongID: String? = nil
    var playbackPosition: TimeInterval = 0
    var playbackDuration: TimeInterval = 0

    // Library paging cursor
    private var pageOffset: Int = 0
    private var libraryExhausted: Bool = false
    private var playlistSongIDs: [MusicItemID: [String]] = [:]
    private var playlistPageOffsets: [MusicItemID: Int] = [:]
    private var playlistExhausted: Set<MusicItemID> = []

    // Artist swipe-walk cursors (parallel to the playlist set above).
    // `artistSongCache` is the source of truth — `artistSongIDs` is a
    // derived view used by callers that only need IDs (e.g. counts).
    private var artistSongCache: [MusicItemID: [Song]] = [:]
    private var artistPageOffsets: [MusicItemID: Int] = [:]
    private var artistExhausted: Set<MusicItemID> = []

    // Cached MusicKit.Playlist refs
    private var playlistCache: [MusicItemID: MusicKit.Playlist] = [:]
    private var artistCache: [MusicItemID: Artist] = [:]
    private var playlistMutationTasks: [MusicItemID: PlaylistMutationTask] = [:]

    /// Per-playlist track-IDs cache. Survives launches; checked before each
    /// `.with([.tracks])` round-trip so unchanged playlists don't refetch.
    private let playlistTracksCache = PlaylistTracksCache()

    private let player = ApplicationMusicPlayer.shared
    private let clipPlayer = AVPlayer()
    private var clipEndObserver: NSObjectProtocol?
    private var clipTimeObserverToken: Any?
    private var fullSongPositionTimer: Timer?

    private init() {}

    // MARK: - Authorization

    @discardableResult
    func requestAuthorization() async -> MusicAuthorization.Status {
        let status = await MusicAuthorization.request()
        authorizationStatus = status
        return status
    }

    // MARK: - Library Songs (paged)

    func resetLibraryCursor() {
        pageOffset = 0
        libraryExhausted = false
        playlistSongIDs.removeAll(keepingCapacity: true)
        playlistPageOffsets.removeAll(keepingCapacity: true)
        playlistExhausted.removeAll(keepingCapacity: true)
        artistPageOffsets.removeAll(keepingCapacity: true)
        artistExhausted.removeAll(keepingCapacity: true)
        // Keep `artistSongCache` — the list of an artist's tracks doesn't
        // change mid-session, so a re-enter shouldn't pay another round-trip.
    }

    /// Pages through the user's library, returning up to `desired` songs not in `excluding`.
    /// Pass `ascending: true` for oldest-first order.
    func fetchNextLibrarySongs(
        excluding: Set<String>,
        desired: Int,
        ascending: Bool = false
    ) async throws -> [Song] {
        var collected: [Song] = []
        let pageSize = 100

        while collected.count < desired && !libraryExhausted {
            var request = MusicLibraryRequest<Song>()
            request.limit = pageSize
            request.offset = pageOffset
            request.sort(by: \.libraryAddedDate, ascending: ascending)

            let response = try await request.response()
            let page = response.items

            if page.isEmpty {
                libraryExhausted = true
                break
            }

            for song in page {
                if !excluding.contains(song.id.rawValue) {
                    collected.append(song)
                    if collected.count >= desired { break }
                }
            }

            pageOffset += page.count
            if page.count < pageSize { libraryExhausted = true }
        }

        return collected
    }

    func fetchNextPlaylistSongs(
        playlistID id: MusicItemID,
        excluding: Set<String>,
        desired: Int,
        ascending: Bool = false
    ) async throws -> [Song] {
        if playlistExhausted.contains(id) { return [] }

        if playlistSongIDs[id] == nil {
            playlistSongIDs[id] = try await fetchSongIDs(inPlaylistID: id)
        }

        // MusicKit returns tracks in playlist position (oldest-added at the
        // top, newly-added at the bottom). For "newest first" we walk the
        // array in reverse so freshly-loved songs surface first instead of
        // being buried 100+ pages deep. The previous libraryAddedDate sort
        // only reshuffled within the 50-song slice — and used the wrong field
        // (library-add date, not playlist-add date) — so it could never lift
        // newer playlist entries past older ones.
        let rawIDs = playlistSongIDs[id] ?? []
        let ids = ascending ? rawIDs : Array(rawIDs.reversed())
        var offset = playlistPageOffsets[id] ?? 0
        var selectedIDs: [String] = []

        while offset < ids.count && selectedIDs.count < desired {
            let songID = ids[offset]
            offset += 1
            if !excluding.contains(songID) {
                selectedIDs.append(songID)
            }
        }

        playlistPageOffsets[id] = offset
        if offset >= ids.count {
            playlistExhausted.insert(id)
        }

        return try await resolveSongs(ids: selectedIDs)
    }

    // MARK: - Library Artists

    /// Returns every artist with at least one track in the user's library.
    /// Sorted alphabetically by the caller; this just hydrates the cache.
    /// Pages through the library because `MusicLibraryRequest` caps each
    /// response at ~100 — without the loop a power user only ever sees the
    /// first alphabetical page.
    @discardableResult
    func refreshLibraryArtists() async throws -> [Artist] {
        let pageSize = 100
        var collected: [Artist] = []
        var offset = 0
        // Build a fresh cache in a temp dict and atomically replace at the
        // end. Previously we cleared `artistCache` upfront, so any concurrent
        // `artwork(forArtistID:)` reader (e.g. Home's ArtistThumbnail) saw
        // nil mid-fetch and briefly flickered to the initials placeholder.
        // On error the old cache stays put — staler beats empty.
        var newCache: [MusicItemID: Artist] = [:]
        while true {
            var request = MusicLibraryRequest<Artist>()
            request.limit = pageSize
            request.offset = offset
            let response = try await request.response()
            let page = Array(response.items)
            if page.isEmpty { break }
            collected.append(contentsOf: page)
            for a in page { newCache[a.id] = a }
            if page.count < pageSize { break }
            offset += page.count
        }
        artistCache = newCache
        return collected
    }

    func artwork(forArtistID id: String) -> Artwork? {
        artistCache[MusicItemID(id)]?.artwork
    }

    /// Resolves the library Songs by a given artist and caches them. Shared
    /// between the Home count preview ("you're about to swipe N songs by X")
    /// and the swipe walk — picking an artist on Home warms the cache for the
    /// session that follows.
    ///
    /// Implementation note: `Artist` has no `.tracks` property in MusicKit,
    /// so we can't go `artist.with([.tracks])` like we do for playlists.
    /// Instead, we filter the library's Songs by the `.artists` relationship.
    func artistLibrarySongs(artistID id: MusicItemID) async throws -> [Song] {
        if let cached = artistSongCache[id] { return cached }
        let artist = try await freshArtist(id: id)
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.artists, contains: artist)
        request.limit = 100

        var collected: [Song] = []
        var offset = 0
        while true {
            request.offset = offset
            let response = try await request.response()
            let page = response.items
            if page.isEmpty { break }
            collected.append(contentsOf: page)
            offset += page.count
            if page.count < 100 { break }
        }
        artistSongCache[id] = collected
        return collected
    }

    func artistLibrarySongIDs(artistID id: MusicItemID) async throws -> [String] {
        try await artistLibrarySongs(artistID: id).map { $0.id.rawValue }
    }

    func fetchNextArtistSongs(
        artistID id: MusicItemID,
        excluding: Set<String>,
        desired: Int,
        ascending: Bool = false
    ) async throws -> [Song] {
        if artistExhausted.contains(id) { return [] }

        let raw = try await artistLibrarySongs(artistID: id)
        // The library filter returns songs roughly oldest-added first.
        // Reverse for "newest first" so freshly-added entries surface up top,
        // mirroring the playlist walk's ordering choice.
        let ordered = ascending ? raw : Array(raw.reversed())
        var offset = artistPageOffsets[id] ?? 0
        var selected: [Song] = []

        while offset < ordered.count && selected.count < desired {
            let song = ordered[offset]
            offset += 1
            if !excluding.contains(song.id.rawValue) {
                selected.append(song)
            }
        }

        artistPageOffsets[id] = offset
        if offset >= ordered.count {
            artistExhausted.insert(id)
        }

        return selected
    }

    private func freshArtist(id: MusicItemID) async throws -> Artist {
        if let cached = artistCache[id] { return cached }
        var request = MusicLibraryRequest<Artist>()
        request.filter(matching: \.id, equalTo: id)
        guard let artist = try await request.response().items.first else {
            throw MusicLibraryError.artistNotFound
        }
        artistCache[id] = artist
        return artist
    }

    /// Computes per-artist library track counts in one batch. One filtered
    /// request per artist (`.artists, contains:`), running 8 at a time so a
    /// power user with 500+ artists doesn't fire 500 simultaneous requests at
    /// MusicKit. Individual artist failures are logged and skipped — partial
    /// results are more useful than a wholesale failure.
    ///
    /// Returns both the counts AND the list of artist IDs we attempted, so
    /// callers can persist a snapshot that survives "this artist has uploaded-
    /// only tracks and reports 0" without forcing a refetch on the next open.
    ///
    /// Callers that already hold a fresh artist list (e.g. the picker right
    /// after `refreshLibraryArtists`) should pass it in via `artists:` to
    /// skip the second full library walk this function would otherwise do.
    func fetchAllArtistTrackCounts(
        artists providedArtists: [Artist]? = nil
    ) async throws -> MembershipIndex.ArtistCountsSnapshot {
        let artists: [Artist]
        if let providedArtists {
            artists = providedArtists
        } else {
            artists = try await refreshLibraryArtists()
        }
        guard !artists.isEmpty else {
            return MembershipIndex.ArtistCountsSnapshot(counts: [:], attemptedIDs: [])
        }
        let maxConcurrent = 8
        let attemptedIDs = artists.map { $0.id.rawValue }

        return await withTaskGroup(of: (String, Int)?.self) { group in
            var counts: [String: Int] = [:]
            counts.reserveCapacity(artists.count)
            var nextIndex = 0

            let seed = min(maxConcurrent, artists.count)
            while nextIndex < seed {
                let artist = artists[nextIndex]
                nextIndex += 1
                group.addTask { await Self.safeCountLibrarySongs(for: artist) }
            }

            while let result = await group.next() {
                if let (id, count) = result {
                    counts[id] = count
                }
                if nextIndex < artists.count {
                    let artist = artists[nextIndex]
                    nextIndex += 1
                    group.addTask { await Self.safeCountLibrarySongs(for: artist) }
                }
            }
            return MembershipIndex.ArtistCountsSnapshot(
                counts: counts,
                attemptedIDs: attemptedIDs
            )
        }
    }

    // `nonisolated` so the task-group children don't all serialize on the
    // main actor — we want real parallelism for the batch fetch.
    nonisolated private static func safeCountLibrarySongs(
        for artist: Artist
    ) async -> (String, Int)? {
        do {
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.artists, contains: artist)
            request.limit = 100
            var total = 0
            var offset = 0
            while true {
                request.offset = offset
                let response = try await request.response()
                let page = response.items
                total += page.count
                if page.count < 100 { break }
                offset += page.count
            }
            // MusicKit's `\.artists, contains:` filter returns empty for some
            // library artists (uploaded tracks, fuzzy metadata, featured-only
            // credits). Reporting "0" would lie — return nil so the picker row
            // drops the badge instead of showing a misleading zero.
            guard total > 0 else { return nil }
            return (artist.id.rawValue, total)
        } catch {
            print("Artist count failed for \(artist.name): \(error)")
            return nil
        }
    }

    // MARK: - Playlists

    @discardableResult
    func refreshUserPlaylists() async throws -> [MusicKit.Playlist] {
        var request = MusicLibraryRequest<MusicKit.Playlist>()
        request.limit = 100
        let response = try await request.response()
        let playlists = Array(response.items)
        playlistCache.removeAll(keepingCapacity: true)
        for p in playlists { playlistCache[p.id] = p }
        return playlists
    }

    func artworkURL(forPlaylistID id: String, size: Int = 88) -> URL? {
        playlistCache[MusicItemID(id)]?.artwork?.url(width: size, height: size)
    }

    func artwork(forPlaylistID id: String) -> Artwork? {
        playlistCache[MusicItemID(id)]?.artwork
    }

    func lastModifiedDate(forPlaylistID id: String) -> Date? {
        playlistCache[MusicItemID(id)]?.lastModifiedDate
    }

    func createPlaylist(name: String) async throws -> MusicKit.Playlist {
        let stored = (UserDefaults.standard.string(forKey: "authorDisplayName") ?? "")
            .trimmingCharacters(in: .whitespaces)
        let author: String? = stored.isEmpty ? nil : stored
        let playlist = try await MusicLibrary.shared.createPlaylist(
            name: name,
            description: nil,
            authorDisplayName: author
        )
        playlistCache[playlist.id] = playlist
        return playlist
    }

    func addSong(_ song: Song, toPlaylistID id: MusicItemID) async throws {
        try await performPlaylistMutation(for: id) { [self] in
            try await addSongAttempt(song, toPlaylistID: id, allowRetry: true)
            // Re-fetch from the library so the cached reference reflects Apple's
            // aggregated cover art (generated from track artworks once songs exist).
            if let refreshed = try? await fetchPlaylist(id: id) {
                playlistCache[refreshed.id] = refreshed
            }
        }
    }

    // Apple Music's playlist index is eventually consistent — right after a
    // remove, an immediate re-add of the same song can fail even though the
    // backend would accept it a moment later. On error, wait briefly and try
    // once more; the dedupe check covers the case where it actually did go
    // through and we just got a stale error.
    private func addSongAttempt(
        _ song: Song,
        toPlaylistID id: MusicItemID,
        allowRetry: Bool
    ) async throws {
        guard let playlist = try await freshPlaylist(id: id) else {
            throw MusicLibraryError.playlistNotFound
        }

        let populated: MusicKit.Playlist = try await playlist.with([.tracks])
        if populated.tracks?.contains(where: { $0.id == song.id }) == true {
            return
        }

        do {
            _ = try await MusicLibrary.shared.add(song, to: populated)
        } catch {
            guard allowRetry else { throw error }
            try? await Task.sleep(for: .milliseconds(450))
            try await addSongAttempt(song, toPlaylistID: id, allowRetry: false)
        }
    }

    private func fetchPlaylist(id: MusicItemID) async throws -> MusicKit.Playlist? {
        var request = MusicLibraryRequest<MusicKit.Playlist>()
        request.filter(matching: \.id, equalTo: id)
        return try await request.response().items.first
    }

    func removeSong(_ song: Song, fromPlaylistID id: MusicItemID) async throws {
        try await performPlaylistMutation(for: id) { [self] in
            guard let playlist = try await freshPlaylist(id: id) else {
                throw MusicLibraryError.playlistNotFound
            }

            let populated: MusicKit.Playlist = try await playlist.with([.tracks])
            guard let currentTracks = populated.tracks else { return }

            let filtered = currentTracks.filter { $0.id != song.id }
            guard filtered.count != currentTracks.count else { return }

            let updated = try await MusicLibrary.shared.edit(populated, items: Array(filtered))
            playlistCache[updated.id] = updated
        }
    }

    private func freshPlaylist(id: MusicItemID) async throws -> MusicKit.Playlist? {
        if let fetched = try await fetchPlaylist(id: id) {
            playlistCache[fetched.id] = fetched
            return fetched
        }
        return playlistCache[id]
    }

    private func fetchSongIDs(inPlaylistID id: MusicItemID) async throws -> [String] {
        guard let playlist = try await freshPlaylist(id: id) else {
            throw MusicLibraryError.playlistNotFound
        }

        let populated: MusicKit.Playlist = try await playlist.with([.tracks])
        return (populated.tracks ?? []).map { $0.id.rawValue }
    }

    private func performPlaylistMutation(
        for id: MusicItemID,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        let previousTask = playlistMutationTasks[id]?.task
        let task = Task { @MainActor in
            _ = await previousTask?.result
            try await operation()
        }
        let mutationTask = PlaylistMutationTask(task: task)
        playlistMutationTasks[id] = mutationTask

        do {
            try await task.value
        } catch {
            if playlistMutationTasks[id] === mutationTask {
                playlistMutationTasks[id] = nil
            }
            throw error
        }

        if playlistMutationTasks[id] === mutationTask {
            playlistMutationTasks[id] = nil
        }
    }

    private final class PlaylistMutationTask {
        let task: Task<Void, Error>

        init(task: Task<Void, Error>) {
            self.task = task
        }
    }

    // MARK: - Unsorted Mode

    /// Fetches every selected playlist's tracks concurrently and returns BOTH
    /// the per-song membership index and the flat set of song IDs in one pass.
    /// Replaces the older sequential walks — with N playlists this used to be
    /// N round-trips on the main actor, now they run in parallel as a single
    /// `withThrowingTaskGroup` batch.
    ///
    /// The `includeCurated` toggle drives scope: when on, editorial / replay /
    /// personalMix playlists are walked too; when off they're skipped (chips
    /// hide them, unsorted excludes only editable-playlist songs).
    func fetchAllPlaylistData(
        includeCurated: Bool
    ) async throws -> (membershipIndex: [String: [MusicItemID]], songIDs: Set<String>) {
        if playlistCache.isEmpty {
            try await refreshUserPlaylists()
        }

        let candidates: [MusicKit.Playlist] = playlistCache.values.filter {
            includeCurated || isUserControlled($0.kind)
        }
        let tracksCache = playlistTracksCache

        // TaskGroup child closures are @Sendable and don't capture self —
        // each captures its own `playlist` value, so MusicKit's `.with(...)`
        // round-trips run truly concurrently rather than serialized.
        //
        // Each child first asks `tracksCache` whether the playlist's
        // `lastModifiedDate` matches what we last fetched. On hit, we skip
        // the round-trip entirely (the expensive bit). On miss/refetch,
        // we upsert the fresh result back for next launch.
        let perPlaylist: [(MusicItemID, [String])] = try await withThrowingTaskGroup(
            of: (MusicItemID, [String]).self
        ) { group in
            for playlist in candidates {
                group.addTask {
                    let amID = playlist.id.rawValue
                    let modifiedAt = playlist.lastModifiedDate
                    if let cached = await tracksCache.tracks(
                        forPlaylist: amID,
                        modifiedAt: modifiedAt
                    ) {
                        return (playlist.id, cached)
                    }
                    let populated: MusicKit.Playlist = try await playlist.with([.tracks])
                    let ids = (populated.tracks ?? []).map { $0.id.rawValue }
                    await tracksCache.upsert(
                        playlistAMID: amID,
                        modifiedAt: modifiedAt,
                        trackIDs: ids
                    )
                    return (playlist.id, ids)
                }
            }
            var results: [(MusicItemID, [String])] = []
            results.reserveCapacity(candidates.count)
            for try await pair in group {
                results.append(pair)
            }
            return results
        }

        // Drop entries for playlists no longer in the library. Pruning
        // against the FULL playlistCache (not just `candidates`) so toggling
        // the curated filter doesn't drop cached entries we'll want back
        // when the toggle flips.
        let validIDs = Set(playlistCache.values.map { $0.id.rawValue })
        await playlistTracksCache.prune(keepingIDs: validIDs)

        var index: [String: [MusicItemID]] = [:]
        var songIDs = Set<String>()
        for (playlistID, ids) in perPlaylist {
            for id in ids {
                index[id, default: []].append(playlistID)
                songIDs.insert(id)
            }
        }
        return (index, songIDs)
    }

    /// Returns the set of song IDs that belong to at least one playlist. Used
    /// to compute the unsorted-mode exclusion set. Now a thin wrapper over the
    /// parallel `fetchAllPlaylistData` — same scope toggle semantics.
    func fetchPlaylistSongIDs(includeCurated: Bool) async throws -> Set<String> {
        try await fetchAllPlaylistData(includeCurated: includeCurated).songIDs
    }

    /// Builds a per-song index of playlist memberships. Used by the swipe card
    /// to show which playlist(s) a song already belongs to. Now a thin wrapper
    /// over `fetchAllPlaylistData`.
    func fetchPlaylistMembershipIndex(includeCurated: Bool) async throws -> [String: [MusicItemID]] {
        try await fetchAllPlaylistData(includeCurated: includeCurated).membershipIndex
    }

    // Apple stamps the creating app's name into curatorName for third-party-
    // created playlists, so we rely on Playlist.Kind. Editorial / auto-generated
    // / externally-shared kinds are read-only; everything else is user-controlled.
    private func isUserControlled(_ kind: MusicKit.Playlist.Kind?) -> Bool {
        switch kind {
        case .editorial, .external, .personalMix, .replay:
            return false
        default:
            return true
        }
    }

    // MARK: - Artist Hub

    /// Resolves the catalog `Artist` for a song so we can present a rich detail
    /// sheet. Tries the song's `.artists` relationship first (works for catalog
    /// songs), then falls back to a catalog search by `artistName` for
    /// library-only or uploaded tracks. Returns nil only when both paths miss —
    /// the caller degrades to a name-only view in that case.
    func resolveArtist(for song: Song) async throws -> Artist? {
        let populated = try await song.with([.artists])
        if let direct = populated.artists?.first {
            return direct
        }

        let term = song.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }

        var request = MusicCatalogSearchRequest(term: term, types: [Artist.self])
        request.limit = 5
        let response = try await request.response()

        // Prefer an exact (case-insensitive) name match so common-name
        // collisions don't surface the wrong artist; fall back to the first
        // result when no exact hit exists.
        let lower = term.lowercased()
        return response.artists.first(where: { $0.name.lowercased() == lower })
            ?? response.artists.first
    }

    /// Hydrates an `Artist` with the relationships the hub renders.
    /// `topSongs` and `similarArtists` are nil until fetched; we always need
    /// both for the sheet, so pull them in one round-trip.
    func loadArtistDetail(_ artist: Artist) async throws -> Artist {
        try await artist.with([.topSongs, .similarArtists])
    }

    // MARK: - Dismissed Mode

    /// Resolves a list of song IDs to Song objects by paging through the library.
    /// Returns songs in the same order as `ids` (so the caller's sort order is preserved).
    func resolveSongs(ids: [String]) async throws -> [Song] {
        guard !ids.isEmpty else { return [] }
        let targetSet = Set(ids)
        var found: [String: Song] = [:]
        let pageSize = 100
        var offset = 0

        while found.count < targetSet.count {
            var request = MusicLibraryRequest<Song>()
            request.limit = pageSize
            request.offset = offset
            let response = try await request.response()
            let page = response.items

            if page.isEmpty { break }

            for song in page where targetSet.contains(song.id.rawValue) {
                found[song.id.rawValue] = song
            }

            offset += page.count
            if page.count < pageSize { break }
        }

        return ids.compactMap { found[$0] }
    }

    // MARK: - Playback

    func playPreview(for song: Song) {
        let useHotPreview = UserDefaults.standard.bool(forKey: "useHotPreview")
        if useHotPreview {
            Task { @MainActor in
                await playWithHotClipIfPossible(song)
            }
            return
        }
        playFullSong(song)
    }

    private func playWithHotClipIfPossible(_ song: Song) async {
        if let url = await resolveHotClipURL(for: song) {
            await playHotClip(url: url, songID: song.id.rawValue)
        } else {
            playFullSong(song)
        }
    }

    // Library songs from MusicLibraryRequest come back with empty
    // previewAssets and nil isrc, so we bridge by searching the Apple Music
    // catalog using title + artist and pick the best title/artist match.
    private func resolveHotClipURL(for song: Song) async -> URL? {
        if let url = song.previewAssets?.first?.url {
            return url
        }

        if let isrc = song.isrc, !isrc.isEmpty {
            do {
                let request = MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc)
                let response = try await request.response()
                if let url = response.items.first?.previewAssets?.first?.url {
                    return url
                }
            } catch {
                print("[hotpreview] isrc lookup failed: \(error)")
            }
        }

        let term = "\(song.title) \(song.artistName)"
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = 10
            let response = try await request.response()
            let candidates = response.songs

            let titleLower = song.title.lowercased()
            let artistLower = song.artistName.lowercased()
            let albumLower = song.albumTitle?.lowercased()

            // Prefer an exact title+artist+album hit, then title+artist, then
            // anything we can play a preview for.
            let best = candidates.first(where: {
                $0.title.lowercased() == titleLower &&
                $0.artistName.lowercased() == artistLower &&
                albumLower != nil &&
                $0.albumTitle?.lowercased() == albumLower
            }) ?? candidates.first(where: {
                $0.title.lowercased() == titleLower &&
                $0.artistName.lowercased() == artistLower
            }) ?? candidates.first(where: { $0.previewAssets?.first?.url != nil })

            return best?.previewAssets?.first?.url
        } catch {
            print("[hotpreview] catalog search failed: \(error)")
            return nil
        }
    }

    func stopPreview() {
        // The swipe path calls this on every `advance()`, even when nothing's
        // actually playing. Without this guard we'd run the pause/observer
        // teardown AND fire spurious @Observable writes that re-render every
        // view watching playback state — once per swipe.
        guard isPlayingPreview else { return }
        player.pause()
        stopClipPlayer()
        stopPositionObservers()
        isPlayingPreview = false
        nowPlayingSongID = nil
        playbackPosition = 0
        playbackDuration = 0
    }

    /// Routes to whichever player is active. The clip player path is identified
    /// by an active periodic-time observer; otherwise we assume full-song mode.
    func seek(to time: TimeInterval) {
        let target = max(0, playbackDuration > 0 ? min(time, playbackDuration) : time)
        if clipTimeObserverToken != nil {
            clipPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        } else {
            player.playbackTime = target
        }
        playbackPosition = target
    }

    private func playFullSong(_ song: Song) {
        stopClipPlayer()
        stopPositionObservers()
        Task { @MainActor in
            do {
                player.queue = ApplicationMusicPlayer.Queue(for: [song])
                try await player.play()
                isPlayingPreview = true
                nowPlayingSongID = song.id.rawValue
                playbackPosition = 0
                playbackDuration = song.duration ?? 0
                startFullSongPositionTimer()
            } catch {
                print("Playback failed: \(error)")
                isPlayingPreview = false
                nowPlayingSongID = nil
            }
        }
    }

    private func playHotClip(url: URL, songID: String) async {
        player.pause()
        stopClipPlayer()
        stopPositionObservers()

        // AVPlayer doesn't auto-configure the audio session the way
        // ApplicationMusicPlayer does — without this the clip can be silent.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[hotpreview] audio session setup failed: \(error)")
        }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        await applyFadeEnvelope(to: item, asset: asset)
        clipPlayer.replaceCurrentItem(with: item)

        // The 30s preview is a finite clip — when it reaches the end, treat it
        // the same as a manual stop so UI state stays consistent.
        clipEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [self] in
                self.stopPreview()
            }
        }

        clipPlayer.play()
        isPlayingPreview = true
        nowPlayingSongID = songID
        playbackPosition = 0
        playbackDuration = 0
        startClipPositionObserver()
    }

    // Volume ramps on the player item so the preview doesn't click at the
    // boundaries. Must be applied before play() so the first frames ramp from 0.
    private func applyFadeEnvelope(to item: AVPlayerItem, asset: AVURLAsset) async {
        let fade = CMTime(seconds: 0.6, preferredTimescale: 600)
        do {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first,
                  duration.isNumeric,
                  duration.seconds > fade.seconds * 2 else { return }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolumeRamp(
                fromStartVolume: 0.0,
                toEndVolume: 1.0,
                timeRange: CMTimeRange(start: .zero, duration: fade)
            )
            params.setVolumeRamp(
                fromStartVolume: 1.0,
                toEndVolume: 0.0,
                timeRange: CMTimeRange(start: CMTimeSubtract(duration, fade), duration: fade)
            )
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
        } catch {
            print("[hotpreview] fade envelope setup failed: \(error)")
        }
    }

    private func stopClipPlayer() {
        if let token = clipEndObserver {
            NotificationCenter.default.removeObserver(token)
            clipEndObserver = nil
        }
        clipPlayer.pause()
        clipPlayer.replaceCurrentItem(with: nil)
    }

    private func startClipPositionObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        clipTimeObserverToken = clipPlayer.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            // queue: .main guarantees this runs on the main thread, but the
            // closure type is @Sendable so the compiler can't infer it.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.playbackPosition = time.seconds
                if let dur = self.clipPlayer.currentItem?.duration,
                   dur.isNumeric, dur.seconds > 0 {
                    self.playbackDuration = dur.seconds
                }
            }
        }
    }

    // ApplicationMusicPlayer has no built-in periodic time observer, so we poll.
    // 0.2s is fine for a hairline progress bar — the eye won't see finer.
    private func startFullSongPositionTimer() {
        fullSongPositionTimer = Timer.scheduledTimer(
            withTimeInterval: 0.2,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playbackPosition = self.player.playbackTime
            }
        }
    }

    private func stopPositionObservers() {
        if let token = clipTimeObserverToken {
            clipPlayer.removeTimeObserver(token)
            clipTimeObserverToken = nil
        }
        fullSongPositionTimer?.invalidate()
        fullSongPositionTimer = nil
    }
}

enum MusicLibraryError: Error {
    case playlistNotFound
    case artistNotFound
}
