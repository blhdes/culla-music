import AVFoundation
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
    private let clipPlayer = AVPlayer()
    private var clipEndObserver: NSObjectProtocol?

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
        let useHotPreview = UserDefaults.standard.bool(forKey: "useHotPreview")
        print("[hotpreview] play title=\"\(song.title)\" toggle=\(useHotPreview) previewAssets=\(song.previewAssets?.count ?? 0) isrc=\(song.isrc ?? "nil") id=\(song.id.rawValue)")
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
            print("[hotpreview] playing hot clip: \(url.lastPathComponent)")
            playHotClip(url: url, songID: song.id.rawValue)
        } else {
            print("[hotpreview] no preview URL resolved — falling back to full song")
            playFullSong(song)
        }
    }

    // Library songs from MusicLibraryRequest come back with empty
    // previewAssets and nil isrc, so we bridge by searching the Apple Music
    // catalog using title + artist and pick the best title/artist match.
    private func resolveHotClipURL(for song: Song) async -> URL? {
        if let url = song.previewAssets?.first?.url {
            print("[hotpreview] direct previewAssets URL on song")
            return url
        }

        if let isrc = song.isrc, !isrc.isEmpty {
            do {
                let request = MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc)
                let response = try await request.response()
                if let url = response.items.first?.previewAssets?.first?.url {
                    print("[hotpreview] isrc lookup matched")
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

            if let url = best?.previewAssets?.first?.url {
                print("[hotpreview] catalog search matched: \"\(best!.title)\" — \(best!.artistName)")
                return url
            }
            print("[hotpreview] catalog search returned \(candidates.count) results, no usable preview")
            return nil
        } catch {
            print("[hotpreview] catalog search failed: \(error)")
            return nil
        }
    }

    func stopPreview() {
        player.pause()
        stopClipPlayer()
        isPlayingPreview = false
        nowPlayingSongID = nil
    }

    private func playFullSong(_ song: Song) {
        stopClipPlayer()
        Task { @MainActor in
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

    private func playHotClip(url: URL, songID: String) {
        player.pause()
        stopClipPlayer()

        // AVPlayer doesn't auto-configure the audio session the way
        // ApplicationMusicPlayer does — without this the clip can be silent.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[hotpreview] audio session setup failed: \(error)")
        }

        let item = AVPlayerItem(url: url)
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
    }

    private func stopClipPlayer() {
        if let token = clipEndObserver {
            NotificationCenter.default.removeObserver(token)
            clipEndObserver = nil
        }
        clipPlayer.pause()
        clipPlayer.replaceCurrentItem(with: nil)
    }
}

enum MusicLibraryError: Error {
    case playlistNotFound
}
