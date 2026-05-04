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

    // Cached MusicKit.Playlist refs so add(songs:to:) doesn't re-fetch
    private var playlistCache: [MusicItemID: MusicKit.Playlist] = [:]

    // Apple Music's system player — handles full tracks for subscribers and
    // previews for non-subscribers automatically. Replaces our prior AVPlayer
    // approach, which only worked for catalog `previewAssets` URLs (library
    // tracks routinely 404'd or timed out).
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

    /// Pages through the user's Apple Music library, returning up to `desired`
    /// songs whose IDs are NOT in the exclusion set. Stops early when exhausted.
    func fetchNextLibrarySongs(excluding: Set<String>, desired: Int) async throws -> [Song] {
        var collected: [Song] = []
        let pageSize = 100

        while collected.count < desired && !libraryExhausted {
            var request = MusicLibraryRequest<Song>()
            request.limit = pageSize
            request.offset = pageOffset
            request.sort(by: \.libraryAddedDate, ascending: false)

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

    /// Returns the CDN artwork URL for a playlist from the in-memory cache.
    /// Returns nil if the playlist has no artwork or hasn't been fetched yet.
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

    /// MusicKit has no public single-song removal API as of iOS 17.
    /// Caller surfaces a "Removed locally" toast on undo.
    func removeSong(_ song: Song, fromPlaylistID id: MusicItemID) async throws {
        throw MusicLibraryError.removeNotSupported
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
