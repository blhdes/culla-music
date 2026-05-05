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

    // Cached MusicKit.Playlist refs
    private var playlistCache: [MusicItemID: MusicKit.Playlist] = [:]

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

    func createPlaylist(name: String) async throws -> MusicKit.Playlist {
        let playlist = try await MusicLibrary.shared.createPlaylist(name: name)
        playlistCache[playlist.id] = playlist
        return playlist
    }

    func addSong(_ song: Song, toPlaylistID id: MusicItemID) async throws {
        guard let playlist = playlistCache[id] else {
            throw MusicLibraryError.playlistNotFound
        }
        let updated = try await MusicLibrary.shared.add(song, to: playlist)
        playlistCache[updated.id] = updated
    }

    func removeSong(_ song: Song, fromPlaylistID id: MusicItemID) async throws {
        throw MusicLibraryError.removeNotSupported
    }

    // MARK: - Unsorted Mode

    /// Returns song IDs that belong to at least one user-created (.personal) playlist.
    /// Non-editable playlists (editorial, algorithmic, saved) are excluded — songs
    /// only in those still count as "unsorted" since the user didn't actively organise them.
    /// Caller must have called refreshUserPlaylists() first so the cache is warm.
    func fetchEditablePlaylistSongIDs() async throws -> Set<String> {
        if playlistCache.isEmpty {
            try await refreshUserPlaylists()
        }

        var songIDs = Set<String>()

        for playlist in playlistCache.values {
            // User-owned playlists have no curator (Apple/other users set curatorName).
            // Songs only in foreign playlists still count as "unsorted" since the user
            // can't actively sort into them.
            guard playlist.curatorName == nil else { continue }

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
    case removeNotSupported
}
