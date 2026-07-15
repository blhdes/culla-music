import AVFoundation
import Foundation
import MusicKit
import SwiftData

/// Apple-generated playlist kinds that are never the user's own content.
///
/// `.external` is deliberately ABSENT: it spans both catalog playlists the user
/// saved (truly read-only) AND the user's own playlists imported or synced from
/// iTunes / another device (fully writable), and MusicKit exposes no flag to tell
/// them apart. We optimistically treat `.external` as the user's own — a genuine
/// write failure just surfaces a toast (we no longer brand a playlist read-only
/// off one failed write). Shared by `computeEditability` (write / read-only badge)
/// and `isUserControlled` (membership-index scope) so the two can't drift apart.
func isAppleGeneratedKind(_ kind: MusicKit.Playlist.Kind?) -> Bool {
    switch kind {
    case .editorial, .personalMix, .replay: return true
    default: return false
    }
}

/// True if `amPlaylist` accepts programmatic writes via `MusicLibrary.shared.add(...)`.
/// The smart "Favorites" playlist (Apple Music heart button) has `kind=nil` /
/// `curatorName=nil` — identical to a user-made playlist — so it's flagged by
/// name. Add new locales to `smartFavoritesNames` as we discover them.
func computeEditability(for amPlaylist: MusicKit.Playlist) -> Bool {
    !isAppleGeneratedKind(amPlaylist.kind)
        && !smartFavoritesNames.contains(amPlaylist.name)
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

/// True when a song added on `added` falls *before* the picked `day` in the
/// given sort direction — i.e. it belongs to the pre-date "prefix" that a
/// date-anchored walk skips (and that the carousel scrubs past). Newest-first
/// (`ascending == false`) treats songs added AFTER the picked day as prefix;
/// oldest-first treats songs added BEFORE its start as prefix. The whole
/// picked day is inclusive on both ends. A `nil` date is never prefix — undated
/// songs are kept in their sort position rather than silently dropped.
///
/// Shared by `MusicLibraryService.fetchNextLibrarySongs` (the swipe session's
/// skip-prefix) and `CarouselSongFeed.loadUntil` (the carousel's scrub target)
/// so the two surfaces agree on exactly where a date lands.
func libraryAddDateIsPrefix(_ added: Date?, day: Date, ascending: Bool) -> Bool {
    guard let added else { return false }
    let cal = Calendar.current
    let startOfDay = cal.startOfDay(for: day)
    if ascending {
        return added < startOfDay
    }
    // End of the picked day == start of the next day; "added after" means >=.
    guard let nextDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else {
        return false
    }
    return added >= nextDay
}

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
    private var playlistSongs: [MusicItemID: [Song]] = [:]
    private var playlistPageOffsets: [MusicItemID: Int] = [:]
    private var playlistExhausted: Set<MusicItemID> = []

    // Artist swipe-walk cursors (parallel to the playlist set above).
    // `artistSongCache` is the source of truth — `artistSongIDs` is a
    // derived view used by callers that only need IDs (e.g. counts).
    private var artistSongCache: [MusicItemID: [Song]] = [:]
    private var artistPageOffsets: [MusicItemID: Int] = [:]
    private var artistExhausted: Set<MusicItemID> = []

    /// Oldest & newest library-add dates, memoized for the carousel's date
    /// picker bounds. Only shifts when the library grows; the picker reads it
    /// on every open, so a cache avoids two round-trips each time.
    private var cachedAddedDateSpan: (oldest: Date, newest: Date)?

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
    /// In-flight volume ramp for the clip player. Cancelled before starting a
    /// new one so a rapid pause→resume doesn't leave two ramps fighting over
    /// `clipPlayer.volume`.
    private var clipVolumeRampTask: Task<Void, Never>?

    /// Bumped on every `playPreview`/`stopPreview` call. `ApplicationMusicPlayer.play()`
    /// can take a while to resolve (cold-start latency); an in-flight play task
    /// checks its captured generation against the current one before committing
    /// `isPlayingPreview`/`nowPlayingSongID`, so a stop that lands first (e.g. the
    /// user backing out of a swipe session before autoplay's first `play()` even
    /// returns) isn't silently ignored by a later, now-stale success.
    private var playGeneration: Int = 0

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
        playlistSongs.removeAll(keepingCapacity: true)
        playlistPageOffsets.removeAll(keepingCapacity: true)
        playlistExhausted.removeAll(keepingCapacity: true)
        artistPageOffsets.removeAll(keepingCapacity: true)
        artistExhausted.removeAll(keepingCapacity: true)
        // Keep `artistSongCache` — the list of an artist's tracks doesn't
        // change mid-session, so a re-enter shouldn't pay another round-trip.
    }

    /// Pages through the user's library, returning up to `desired` songs not in `excluding`.
    /// Pass `ascending: true` for oldest-first order.
    ///
    /// `startFromDate` anchors the walk to a point in the add-date timeline:
    /// songs in the pre-date "prefix" (added after the picked day in newest-first,
    /// before it in oldest-first — see `libraryAddDateIsPrefix`) are skipped so
    /// the whole session reviews from that date onward. The skip cost is paid
    /// once: `pageOffset` advances past the prefix on the first call, so later
    /// paging starts already beyond it and the check is a no-op.
    func fetchNextLibrarySongs(
        excluding: Set<String>,
        desired: Int,
        ascending: Bool = false,
        startFromDate: Date? = nil
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

            // Track items actually examined so the cursor advances by what we
            // consumed — NOT the full page. Breaking early on `desired` and then
            // adding `page.count` would skip the page's unseen tail forever
            // (with desired < pageSize that drops roughly half the library).
            var consumed = 0
            for song in page {
                consumed += 1
                if let startFromDate,
                   libraryAddDateIsPrefix(song.libraryAddedDate, day: startFromDate, ascending: ascending) {
                    continue   // still in the pre-date prefix — skip past it
                }
                if !excluding.contains(song.id.rawValue) {
                    collected.append(song)
                    if collected.count >= desired { break }
                }
            }

            pageOffset += consumed
            // Only the genuinely-final page (fully walked AND short) ends the
            // walk. An early break leaves a tail to resume from next call.
            if consumed == page.count && page.count < pageSize { libraryExhausted = true }
        }

        return collected
    }

    /// Oldest & newest library-addition dates, for bounding the carousel's
    /// date-jump picker. Two single-item requests (cheap) run concurrently;
    /// cached after the first read. Returns nil when the library exposes no
    /// add-dates at all (no songs, or `libraryAddedDate` unavailable) — the
    /// caller hides the date control in that case.
    func libraryAddedDateSpan() async -> (oldest: Date, newest: Date)? {
        if let cachedAddedDateSpan { return cachedAddedDateSpan }
        do {
            // Configure each request, then snapshot into a `let` — the
            // concurrent `async let .response()` closures capture by reference,
            // and capturing the mutable `var` is an error in Swift 6 mode.
            var oldestReq = MusicLibraryRequest<Song>()
            oldestReq.limit = 1
            oldestReq.sort(by: \.libraryAddedDate, ascending: true)
            let oldestRequest = oldestReq
            var newestReq = MusicLibraryRequest<Song>()
            newestReq.limit = 1
            newestReq.sort(by: \.libraryAddedDate, ascending: false)
            let newestRequest = newestReq

            async let oldestResp = oldestRequest.response()
            async let newestResp = newestRequest.response()
            let oldest = (try await oldestResp).items.first?.libraryAddedDate
            let newest = (try await newestResp).items.first?.libraryAddedDate

            guard let oldest, let newest else { return nil }
            let span = (oldest: oldest, newest: newest)
            cachedAddedDateSpan = span
            return span
        } catch {
            print("libraryAddedDateSpan failed: \(error)")
            return nil
        }
    }

    func fetchNextPlaylistSongs(
        playlistID id: MusicItemID,
        excluding: Set<String>,
        desired: Int,
        ascending: Bool = false
    ) async throws -> [Song] {
        if playlistExhausted.contains(id) { return [] }

        if playlistSongs[id] == nil {
            playlistSongs[id] = try await fetchPlaylistSongs(inPlaylistID: id)
        }

        // MusicKit returns tracks in playlist position (oldest-added at the
        // top, newly-added at the bottom). For "newest first" we walk the
        // array in reverse so freshly-added songs surface first instead of
        // being buried 100+ pages deep.
        let rawSongs = playlistSongs[id] ?? []
        let songs = ascending ? rawSongs : Array(rawSongs.reversed())
        var offset = playlistPageOffsets[id] ?? 0
        var selected: [Song] = []

        while offset < songs.count && selected.count < desired {
            let song = songs[offset]
            offset += 1
            if !excluding.contains(song.id.rawValue) {
                selected.append(song)
            }
        }

        playlistPageOffsets[id] = offset
        if offset >= songs.count {
            playlistExhausted.insert(id)
        }

        return selected
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
        ascending: Bool = false,
        startFromDate: Date? = nil
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
            // Date-jump anchors an artist session to a point in its add-date
            // timeline: songs in the pre-date prefix are skipped so the deck
            // resumes from there. These are library songs with real add-dates,
            // so the same shared helper the library walk uses applies; the rough
            // ordering is fine because we scan the whole list and keep every
            // non-prefix song regardless of its exact position.
            if let startFromDate,
               libraryAddDateIsPrefix(song.libraryAddedDate, day: startFromDate, ascending: ascending) {
                continue
            }
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

    /// Renames a playlist via `MusicLibrary.shared.edit`. Same Apple constraint
    /// as `removeSong`'s `edit`: it only succeeds on playlists THIS app created.
    /// Every other library playlist — including the user's own Music-app ones —
    /// is rejected with `ICPlaylistUpdateErrorDomain`, so callers attempt this
    /// optimistically and surface a toast on failure (we don't pre-gate it,
    /// matching the app's no-sticky-read-only stance).
    func renamePlaylist(id: MusicItemID, to newName: String) async throws {
        try await performPlaylistMutation(for: id) { [self] in
            guard let playlist = try await freshPlaylist(id: id) else {
                throw MusicLibraryError.playlistNotFound
            }
            // Use the metadata-only `edit` overload (no `items:`) so the track
            // list is left untouched — the `items:` overload would require us to
            // hand back the full track sequence just to keep it.
            let updated = try await MusicLibrary.shared.edit(playlist, name: newName)
            playlistCache[updated.id] = updated
        }
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

            // NOTE: `MusicLibrary.shared.edit` only succeeds on playlists THIS
            // app created — Apple rejects edits to any other library playlist
            // with `ICPlaylistUpdateErrorDomain` "Updating playlists are only
            // allowed when updating a playlist that your app has created." There
            // is no public API to remove a track from a user's own Music-app
            // playlist, so callers must treat removal failure as expected for
            // non-app-created sources (see `removeFromSourceIfNeeded`).
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

    /// Reads a playlist's tracks as `Song` objects straight from the `.tracks`
    /// relationship. Pulling the songs out directly (instead of mapping to ID
    /// strings and re-resolving them) is what makes playlist scope work for
    /// Apple curated playlists: their tracks aren't in the user's library, and
    /// their IDs live in a different namespace than catalog IDs — so trying to
    /// re-resolve those IDs landed on unrelated songs. The Track relationship
    /// already hands us the correct, playable songs. `MusicKit.Track` is an
    /// enum, so we keep the `.song` cases and drop any `.musicVideo` entries.
    private func fetchPlaylistSongs(inPlaylistID id: MusicItemID) async throws -> [Song] {
        guard let playlist = try await freshPlaylist(id: id) else {
            throw MusicLibraryError.playlistNotFound
        }

        let populated: MusicKit.Playlist = try await playlist.with([.tracks])
        return (populated.tracks ?? []).compactMap { track in
            if case .song(let song) = track { return song }
            return nil
        }
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

    // MARK: - Deck Filtering

    /// Set of song IDs to exclude from a deck for the given mode. The single
    /// source of truth shared by `CarouselSongFeed` and `HomeHeroArtStack` so
    /// both surfaces agree on "what counts as the next song." Before this
    /// existed, the hero ran an unfiltered library request and could surface a
    /// song the carousel had already excluded — first-cover mismatch.
    ///
    /// - `.library`:   sorted ∪ dismissed ∪ playlistFiltered ∪ artistFiltered
    ///                 (already acted on, plus the user's two optional exclude
    ///                 lists — see `QueueFilterStore` and the rules below)
    /// - `.unsorted`:  playlists ∪ sorted ∪ dismissed  (everything that "has a home")
    /// - `.dismissed`: empty (dismissed mode *shows* dismissed songs, doesn't filter them)
    ///
    /// `.library` playlist filter — lenient policy: a song is added to the
    /// exclusion set only when *every* playlist it belongs to is in the user's
    /// excluded set. Songs in zero playlists are never filtered. This preserves
    /// the ability to encounter a song from a non-excluded playlist even if it
    /// also lives in an excluded one.
    ///
    /// `.library` artist filter — hard policy: every library track crediting a
    /// filtered artist is excluded outright (collabs included — that's the
    /// natural meaning of "don't show me this artist"). The two filters union,
    /// so each independently hides its matches.
    ///
    /// On a playlist-fetch failure in `.unsorted`, returns `[]` to match
    /// `CarouselSongFeed.buildExclusionSet`'s prior behavior — without this,
    /// the hero and the carousel would diverge in the failure path. The
    /// `.library` membership fetch follows the same pattern: on failure we
    /// fall back to the unfiltered sorted ∪ dismissed set rather than empty,
    /// because losing sort/dismiss filtering would be worse than losing the
    /// user's optional playlist filter.
    func deckExclusionSet(
        for mode: ReviewMode,
        modelContext: ModelContext
    ) async -> Set<String> {
        let sortedIDs = Set(
            (try? modelContext.fetch(FetchDescriptor<SortedSong>()))?.map(\.songID) ?? []
        )
        let dismissedIDs = Set(
            (try? modelContext.fetch(FetchDescriptor<DismissedSong>()))?.map(\.songID) ?? []
        )
        switch mode {
        case .library:
            let base = sortedIDs.union(dismissedIDs)
            let excludedPlaylists = QueueFilterStore.read()
            let excludedArtists = QueueFilterStore.readArtists()
            guard !excludedPlaylists.isEmpty || !excludedArtists.isEmpty else { return base }

            var filtered = base

            // Playlist filter (lenient: only when ALL of a song's playlists are
            // excluded). On a membership-fetch failure we keep what we have
            // rather than dropping sort/dismiss — losing the optional filter is
            // the lesser harm.
            if !excludedPlaylists.isEmpty {
                do {
                    let membership = try await fetchPlaylistMembershipIndex(includeCurated: true)
                    for (songID, playlistAMIDs) in membership where !playlistAMIDs.isEmpty {
                        if playlistAMIDs.allSatisfy({ excludedPlaylists.contains($0.rawValue) }) {
                            filtered.insert(songID)
                        }
                    }
                } catch {
                    print("deckExclusionSet library playlist filter failed: \(error)")
                }
            }

            // Artist filter (hard: any track by a filtered artist). Each lookup
            // is cached per-artist, so re-walks are cheap; a single artist
            // failure is logged and skipped so the rest still apply.
            for artistID in excludedArtists {
                do {
                    let ids = try await artistLibrarySongIDs(artistID: MusicItemID(artistID))
                    filtered.formUnion(ids)
                } catch {
                    print("deckExclusionSet library artist filter failed for \(artistID): \(error)")
                }
            }

            return filtered
        case .unsorted:
            do {
                let playlistIDs = try await fetchPlaylistSongIDs(includeCurated: true)
                return playlistIDs.union(sortedIDs).union(dismissedIDs)
            } catch {
                print("deckExclusionSet unsorted failed: \(error)")
                return []
            }
        case .dismissed:
            return []
        }
    }

    /// Ordered songs for a picked playlist/artist scope, matching the ordering
    /// the scoped swipe walk uses so the hero deck, the expanded carousel, and
    /// the session itself agree on "what's in this collection" and in what
    /// order. Playlists read tracks in playlist position (reversed for
    /// newest-first, so freshly-added tracks lead); artists read their library
    /// tracks (roughly add-date order, same reversal). Both reuse the per-scope
    /// caches the swipe session fills, so picking a source on Home warms the
    /// session that follows.
    func scopeSongs(for source: SourceScope, sortOrder: SortOrder) async throws -> [Song] {
        let ascending = sortOrder.ascending
        switch source {
        case .playlist(let id, _, _):
            let mid = MusicItemID(id)
            if playlistSongs[mid] == nil {
                playlistSongs[mid] = try await fetchPlaylistSongs(inPlaylistID: mid)
            }
            let raw = playlistSongs[mid] ?? []
            return ascending ? raw : Array(raw.reversed())
        case .artist(let id, _):
            let raw = try await artistLibrarySongs(artistID: MusicItemID(id))
            return ascending ? raw : Array(raw.reversed())
        }
    }

    /// Exclusion set for a scoped (playlist/artist) deck. Mirrors the scope
    /// branch of `MusicSwipeViewModel.fetchExcludedIdentifiers`: sorted songs
    /// stay visible (a scoped session is "re-categorize this collection from
    /// scratch"), and only previously-dismissed songs are hidden — unless the
    /// user opted into `includeDismissed`, which surfaces those too. Lives next
    /// to `deckExclusionSet` so the unscoped and scoped rules sit side by side
    /// and can't quietly diverge.
    func scopeExclusionSet(includeDismissed: Bool, modelContext: ModelContext) -> Set<String> {
        guard !includeDismissed else { return [] }
        let dismissed = (try? modelContext.fetch(FetchDescriptor<DismissedSong>()))?.map(\.songID) ?? []
        return Set(dismissed)
    }

    // Editorial / auto-generated kinds aren't the user's content; everything else
    // (including `.external` imports) is. Mirrors `computeEditability` via the
    // shared `isAppleGeneratedKind` so write-eligibility and membership scope
    // stay in lockstep.
    private func isUserControlled(_ kind: MusicKit.Playlist.Kind?) -> Bool {
        !isAppleGeneratedKind(kind)
    }

    // MARK: - Artist Hub

    /// Resolves the catalog `Artist` for a song so we can present a rich detail
    /// sheet. Tries the song's `.artists` relationship first (works for catalog
    /// songs), then falls back to a catalog search by `artistName` for
    /// library-only or uploaded tracks. Returns nil only when both paths miss —
    /// the caller degrades to a name-only view in that case.
    func resolveArtist(for song: Song) async throws -> Artist? {
        // Lead with the track's own `artistName`, resolved against the catalog.
        // The song's `.artists` relationship returns the *album* artist on
        // compilation tracks ("Various Artists") and, worse, a library artist
        // whose ID 404s on the topSongs/similarArtists catalog request the hub
        // then makes. Searching the catalog by the track artist name avoids
        // both: we get the concrete per-track artist as a catalog entity.
        let term = song.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty, !Self.isVariousArtists(term) {
            var request = MusicCatalogSearchRequest(term: term, types: [Artist.self])
            request.limit = 5
            let response = try await request.response()

            // Only accept an exact (case-insensitive) name match. Without this
            // guard a library track by "Tyler" would resolve to whichever
            // Tyler the catalog returned first.
            let lower = term.lowercased()
            if let match = response.artists.first(where: { $0.name.lowercased() == lower }) {
                return match
            }
        }

        // Fallback for names the catalog search misses (uploaded / local
        // tracks, unusual spellings): the song's own artist relationship.
        // Nil → caller renders FallbackArtistView with a Google search.
        let populated = try await song.with([.artists])
        return populated.artists?.first
    }

    /// Compilation albums tag tracks with an album artist of "Various Artists"
    /// (and localized equivalents). That's never a real artist to look up, so
    /// we skip the catalog search and fall through to the per-track relationship.
    private static func isVariousArtists(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "various artists" || lower.contains("various artist")
    }

    /// Hydrates an `Artist` with the relationships the hub renders.
    /// `topSongs` and `similarArtists` are nil until fetched; we always need
    /// both for the sheet, so pull them in one round-trip.
    func loadArtistDetail(_ artist: Artist) async throws -> Artist {
        try await artist.with([.topSongs, .similarArtists])
    }

    /// Apple Music's editorial blurb for an artist (the long "standard" note,
    /// falling back to the shorter one) — shown in the hub just above the
    /// Wikipedia "About". Uses the note already on the artist when present;
    /// otherwise re-fetches the artist from the catalog to pull it in.
    ///
    /// Title-guarded exactly like `loadAlbumEditorial`: a library artist's ID
    /// lives in a different namespace than catalog IDs, so a catalog request
    /// could resolve to an unrelated artist. We only trust a name-matching
    /// result, so a mismatched collision is discarded rather than shown.
    func loadArtistEditorial(for artist: Artist) async -> AttributedString? {
        if let notes = artist.editorialNotes, let text = Self.preferredEditorial(notes) {
            return text
        }
        do {
            let request = MusicCatalogResourceRequest<Artist>(matching: \.id, equalTo: artist.id)
            let response = try await request.response()
            if let fetched = response.items.first,
               fetched.name.lowercased() == artist.name.lowercased(),
               let notes = fetched.editorialNotes,
               let text = Self.preferredEditorial(notes) {
                return text
            }
        } catch {
            print("loadArtistEditorial fetch failed: \(error)")
        }
        return nil
    }

    // MARK: - Album Liner Notes

    /// Resolves the catalog `Album` for a song so the liner-notes sheet can show
    /// the *complete* tracklist — not just the tracks the user happens to have
    /// in their library. Leads with a catalog search by "artist + album" (the
    /// full pressing), then falls back to the song's own `.albums` relationship
    /// for uploaded / library-only tracks the catalog can't match. Returns nil
    /// only when both paths miss; the caller degrades to a "no notes" view.
    func resolveAlbum(for song: Song) async throws -> Album? {
        let title = (song.albumTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            let artist = song.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
            let term = artist.isEmpty ? title : "\(artist) \(title)"
            var request = MusicCatalogSearchRequest(term: term, types: [Album.self])
            request.limit = 10
            let response = try await request.response()

            // Only accept an exact (case-insensitive) album-title match so a
            // search for, say, "1989" can't resolve to a same-named different
            // record the term happened to surface first.
            let lower = title.lowercased()
            if let match = response.albums.first(where: { $0.title.lowercased() == lower }) {
                return match
            }
        }

        // Fallback: the song's own album relationship. For library-only tracks
        // this is whatever pressing the user has (sometimes a partial one), but
        // it's the exact record the track belongs to — better than nothing.
        let populated = try await song.with([.albums])
        return populated.albums?.first
    }

    /// Hydrates an `Album` with its `.tracks` relationship. Tracks come back as
    /// the `Track` enum (songs plus the occasional music video); we keep them
    /// all so the sleeve lists every entry in order, and pull the `.song` out
    /// only when a row is tapped to preview.
    func loadAlbumTracks(_ album: Album) async throws -> [MusicKit.Track] {
        let populated = try await album.with([.tracks])
        return Array(populated.tracks ?? [])
    }

    /// Apple Music's editorial blurb for an album (the long "standard" note,
    /// falling back to the shorter one) — shown in the sleeve sheet between the
    /// cover and the tracklist. Uses the note already on the album when present;
    /// otherwise re-fetches the album from the catalog to pull it in.
    ///
    /// The re-fetch is title-guarded: a library album's ID lives in a different
    /// namespace than catalog IDs, so feeding it to a catalog request could
    /// resolve to an *unrelated* album. We only trust a result whose title
    /// matches, so a mismatched collision is discarded rather than shown.
    func loadAlbumEditorial(for album: Album) async -> AttributedString? {
        if let notes = album.editorialNotes, let text = Self.preferredEditorial(notes) {
            return text
        }
        do {
            let request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: album.id)
            let response = try await request.response()
            if let fetched = response.items.first,
               fetched.title.lowercased() == album.title.lowercased(),
               let notes = fetched.editorialNotes,
               let text = Self.preferredEditorial(notes) {
                return text
            }
        } catch {
            print("loadAlbumEditorial fetch failed: \(error)")
        }
        return nil
    }

    /// Prefers the full "standard" editorial note, falling back to the short
    /// one; returns nil when both are empty so the caller can hide the section.
    /// Notes arrive with embedded HTML (`<b>`, `<i>`, entities…), so the pick
    /// is parsed through `EditorialHTML` — callers get render-ready rich text,
    /// never raw tags.
    private static func preferredEditorial(_ notes: EditorialNotes) -> AttributedString? {
        for candidate in [notes.standard, notes.short] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty,
               let parsed = EditorialHTML.attributedString(from: text) {
                return parsed
            }
        }
        return nil
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

    /// A targeted library lookup for one song ID. Used to classify a dismissed
    /// track: if its ID isn't in the library it's a catalog-only track (e.g. a
    /// not-yet-added editorial song). Safe by construction — a library request
    /// only ever returns an exact match or nothing, so it can never confuse a
    /// library ID for an unrelated catalog song.
    func isInLibrary(songID id: MusicItemID) async -> Bool {
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.id, equalTo: id)
        let response = try? await request.response()
        return response?.items.isEmpty == false
    }

    /// Resolves an ordered list of IDs split across both stores: IDs in
    /// `catalogIDs` resolve from the Apple Music catalog, the rest from the
    /// library. The caller must know the split (we persist it on
    /// `DismissedSong.isCatalogTrack`) — guessing it from the ID string is
    /// unsafe because library and catalog IDs share the numeric namespace.
    /// Order follows `orderedIDs` so the caller's sort survives.
    func resolveSongs(orderedIDs: [String], catalogIDs: Set<String>) async throws -> [Song] {
        guard !orderedIDs.isEmpty else { return [] }
        let libraryIDs = orderedIDs.filter { !catalogIDs.contains($0) }
        let catalogOnly = orderedIDs.filter { catalogIDs.contains($0) }

        var found: [String: Song] = [:]
        if !libraryIDs.isEmpty {
            for song in try await resolveSongs(ids: libraryIDs) {
                found[song.id.rawValue] = song
            }
        }
        if !catalogOnly.isEmpty {
            for song in await resolveCatalogSongs(ids: catalogOnly) {
                found[song.id.rawValue] = song
            }
        }
        return orderedIDs.compactMap { found[$0] }
    }

    /// Batched catalog lookup by song ID, chunked to stay under Apple Music's
    /// per-request id cap. Non-throwing: a failed chunk is logged and skipped
    /// so one bad ID can't sink the whole deck. Only ever called with genuine
    /// catalog IDs (see `resolveSongs(orderedIDs:catalogIDs:)`).
    private func resolveCatalogSongs(ids: [String]) async -> [Song] {
        let chunkSize = 25
        var resolved: [Song] = []
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + chunkSize, ids.count)])
            index += chunkSize
            let itemIDs = chunk.map { MusicItemID($0) }
            do {
                let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: itemIDs)
                let response = try await request.response()
                resolved.append(contentsOf: response.items)
            } catch {
                print("resolveCatalogSongs chunk failed: \(error)")
            }
        }
        return resolved
    }

    // MARK: - Playback

    func playPreview(for song: Song) {
        playGeneration += 1
        let generation = playGeneration
        let useHotPreview = UserDefaults.standard.bool(forKey: "useHotPreview")
        if useHotPreview {
            Task { @MainActor in
                await playWithHotClipIfPossible(song, generation: generation)
            }
            return
        }
        playFullSong(song, generation: generation)
    }

    private func playWithHotClipIfPossible(_ song: Song, generation: Int) async {
        if let url = await resolveHotClipURL(for: song) {
            guard generation == playGeneration else { return }
            await playHotClip(url: url, songID: song.id.rawValue, generation: generation)
        } else {
            guard generation == playGeneration else { return }
            playFullSong(song, generation: generation)
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
        // No-op only when nothing is loaded at all. The swipe path calls this on
        // every `advance()`; without the guard we'd fire spurious @Observable
        // writes that re-render every playback-watching view once per swipe.
        // A *paused* preview still has a song + clip loaded (isPlayingPreview is
        // false but nowPlayingSongID is set), so swiping away must still tear it
        // down — hence the second clause.
        // Invalidate any in-flight play() first, unconditionally — autoplay may
        // still be cold-starting (isPlayingPreview/nowPlayingSongID not written
        // yet), and without this the guard below would no-op while that call
        // later lands and starts audio on whatever screen is showing next.
        playGeneration += 1

        guard isPlayingPreview || nowPlayingSongID != nil else { return }
        clipVolumeRampTask?.cancel()
        clipVolumeRampTask = nil
        player.pause()
        stopClipPlayer()
        stopPositionObservers()
        clipPlayer.volume = 1
        isPlayingPreview = false
        nowPlayingSongID = nil
        playbackPosition = 0
        playbackDuration = 0
    }

    /// Pauses the active preview while keeping the song, position and duration
    /// intact so `resumePreview()` continues from the same spot. In Hot Preview
    /// mode the clip audio ramps down first so the pause doesn't click; the
    /// default ApplicationMusicPlayer path has no volume API, so it pauses
    /// instantly.
    func pausePreview() {
        guard isPlayingPreview else { return }
        isPlayingPreview = false

        if clipTimeObserverToken != nil {
            // Clip path — keep the observer (so seek still routes here and resume
            // knows it's the clip), fade the audio out, then pause once silent.
            rampClipVolume(to: 0, duration: 0.22) { [weak self] in
                self?.clipPlayer.pause()
            }
        } else {
            // Full-song path — snapshot the exact time, pause, stop polling.
            playbackPosition = player.playbackTime
            player.pause()
            fullSongPositionTimer?.invalidate()
            fullSongPositionTimer = nil
        }
    }

    /// Resumes a paused preview from its kept position. Mirrors `pausePreview`:
    /// the clip path fades audio back in, the full-song path plays and restarts
    /// its position poll. No-op unless a song is loaded and currently paused.
    func resumePreview() {
        guard !isPlayingPreview, nowPlayingSongID != nil else { return }

        if clipTimeObserverToken != nil {
            isPlayingPreview = true
            clipPlayer.volume = 0
            clipPlayer.play()
            rampClipVolume(to: 1, duration: 0.22)
        } else {
            let generation = playGeneration
            Task { @MainActor in
                do {
                    try await player.play()
                    guard generation == playGeneration else {
                        player.pause()
                        return
                    }
                    isPlayingPreview = true
                    startFullSongPositionTimer()
                } catch {
                    print("[playback] resume failed: \(error)")
                    if generation == playGeneration {
                        isPlayingPreview = false
                    }
                }
            }
        }
    }

    /// Linearly ramps `clipPlayer.volume` to `target` over `duration`, then runs
    /// `completion`. AVPlayer has no built-in fade, so we step it ~60×/s. A new
    /// ramp cancels any in-flight one so rapid pause↔resume can't leave two
    /// fighting over the volume.
    private func rampClipVolume(
        to target: Float,
        duration: TimeInterval,
        completion: (() -> Void)? = nil
    ) {
        clipVolumeRampTask?.cancel()
        let start = clipPlayer.volume
        let steps = max(1, Int(duration * 60))
        let stepDelay = duration / Double(steps)
        clipVolumeRampTask = Task { @MainActor in
            for step in 1...steps {
                if Task.isCancelled { return }
                let t = Float(step) / Float(steps)
                clipPlayer.volume = start + (target - start) * t
                try? await Task.sleep(for: .seconds(stepDelay))
            }
            guard !Task.isCancelled else { return }
            clipPlayer.volume = target
            completion?()
        }
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

    private func playFullSong(_ song: Song, generation: Int) {
        stopClipPlayer()
        stopPositionObservers()
        Task { @MainActor in
            do {
                player.queue = ApplicationMusicPlayer.Queue(for: [song])
                try await player.play()
                guard generation == playGeneration else {
                    // Superseded by a newer play or a stop before this landed —
                    // e.g. the user backed out of the swipe session while
                    // MusicKit was still cold-starting. Silence it rather than
                    // let it surface on a screen with no transport to stop it.
                    player.pause()
                    return
                }
                isPlayingPreview = true
                nowPlayingSongID = song.id.rawValue
                playbackPosition = 0
                playbackDuration = song.duration ?? 0
                startFullSongPositionTimer()
            } catch {
                print("Playback failed: \(error)")
                if generation == playGeneration {
                    isPlayingPreview = false
                    nowPlayingSongID = nil
                }
            }
        }
    }

    private func playHotClip(url: URL, songID: String, generation: Int) async {
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
        guard generation == playGeneration else { return }
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

        // A prior pause may have left the master volume at 0; reset it so this
        // fresh clip is audible (its own start/end fade lives in the audioMix).
        clipVolumeRampTask?.cancel()
        clipPlayer.volume = 1
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
