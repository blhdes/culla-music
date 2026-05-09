import Foundation
import MusicKit

@Observable
@MainActor
final class MusicLibraryService {
    static let shared = MusicLibraryService()

    // Observable state
    var authorizationStatus: MusicAuthorization.Status = MusicAuthorization.currentStatus
    var isPlayingPreview: Bool = false
    var nowPlayingSongID: String? = nil

    // Library paging cursor
    private var pageOffset: Int = 0
    private var libraryExhausted: Bool = false
    private var playlistSongIDs: [MusicItemID: [String]] = [:]
    private var playlistPageOffsets: [MusicItemID: Int] = [:]
    private var playlistExhausted: Set<MusicItemID> = []

    // Cached MusicKit.Playlist refs
    private var playlistCache: [MusicItemID: MusicKit.Playlist] = [:]
    private var playlistMutationTasks: [MusicItemID: PlaylistMutationTask] = [:]

    private let player = ApplicationMusicPlayer.shared

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

        let ids = playlistSongIDs[id] ?? []
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

        let songs = try await resolveSongs(ids: selectedIDs)
        return songs.sorted {
            let lhs = $0.libraryAddedDate ?? .distantPast
            let rhs = $1.libraryAddedDate ?? .distantPast
            return ascending ? lhs < rhs : lhs > rhs
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

    func createPlaylist(name: String) async throws -> MusicKit.Playlist {
        let playlist = try await MusicLibrary.shared.createPlaylist(name: name)
        playlistCache[playlist.id] = playlist
        return playlist
    }

    func addSong(_ song: Song, toPlaylistID id: MusicItemID) async throws {
        try await performPlaylistMutation(for: id) { [self] in
            guard let playlist = try await freshPlaylist(id: id) else {
                throw MusicLibraryError.playlistNotFound
            }

            let populated: MusicKit.Playlist = try await playlist.with([.tracks])
            if populated.tracks?.contains(where: { $0.id == song.id }) == true {
                return
            }

            _ = try await MusicLibrary.shared.add(song, to: populated)
            // Re-fetch from the library so the cached reference reflects Apple's
            // aggregated cover art (generated from track artworks once songs exist).
            if let refreshed = try? await fetchPlaylist(id: id) {
                playlistCache[refreshed.id] = refreshed
            }
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

    /// Returns song IDs that belong to at least one user-controlled playlist.
    /// Editorial / auto-generated kinds are excluded (songs only in those still
    /// count as "unsorted" since the user didn't actively organise them).
    /// Caller must have called refreshUserPlaylists() first so the cache is warm.
    func fetchEditablePlaylistSongIDs() async throws -> Set<String> {
        if playlistCache.isEmpty {
            try await refreshUserPlaylists()
        }

        var songIDs = Set<String>()

        for playlist in playlistCache.values {
            // Use Playlist.Kind instead of curatorName — Apple stamps the
            // creating app's name into curatorName for third-party-created
            // playlists, which would otherwise exclude Culla-created lists.
            let isUserControlled: Bool
            switch playlist.kind {
            case .editorial, .personalMix, .replay:
                isUserControlled = false
            default:
                isUserControlled = true
            }
            guard isUserControlled else { continue }

            // Explicit type annotation gives the compiler the context it needs to
            // resolve .tracks as PartialMusicAsyncProperty<MusicKit.Playlist>.
            let populated: MusicKit.Playlist = try await playlist.with([.tracks])
            for track in (populated.tracks ?? []) {
                songIDs.insert(track.id.rawValue)
            }
        }

        return songIDs
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
        Task {
            do {
                player.queue = ApplicationMusicPlayer.Queue(for: [song])
                try await player.play()
                isPlayingPreview = true
                nowPlayingSongID = song.id.rawValue
            } catch {
                print("Playback failed: \(error)")
                isPlayingPreview = false
                nowPlayingSongID = nil
            }
        }
    }

    func stopPreview() {
        player.pause()
        isPlayingPreview = false
        nowPlayingSongID = nil
    }
}

enum MusicLibraryError: Error {
    case playlistNotFound
}
