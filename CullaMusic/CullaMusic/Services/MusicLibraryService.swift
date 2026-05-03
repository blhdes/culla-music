import Foundation
import SwiftUI
import MusicKit
import AVFoundation

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

    // Single shared preview player
    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?

    private init() {
        configureAudioSession()
    }

    // MARK: - Authorization

    @discardableResult
    func requestAuthorization() async -> MusicAuthorization.Status {
        let status = await MusicAuthorization.request()
        authorizationStatus = status
        return status
    }

    // MARK: - Library Songs (paged)

    /// Resets the paging cursor — call when the user explicitly refreshes,
    /// or when the deck signals "all caught up" and the user taps Refresh.
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
    /// We surface this so the caller can show a "Removed locally" toast on undo.
    func removeSong(_ song: Song, fromPlaylistID id: MusicItemID) async throws {
        throw MusicLibraryError.removeNotSupported
    }

    // MARK: - Preview Playback (30s)

    func playPreview(for song: Song) {
        guard let url = song.previewAssets?.first?.url else { return }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }

        let item = AVPlayerItem(url: url)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlayingPreview = false
                self?.nowPlayingSongID = nil
            }
        }

        player.replaceCurrentItem(with: item)
        player.play()
        isPlayingPreview = true
        nowPlayingSongID = song.id.rawValue
    }

    func stopPreview() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlayingPreview = false
        nowPlayingSongID = nil
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AudioSession config failed: \(error)")
        }
    }
}

enum MusicLibraryError: Error {
    case playlistNotFound
    case removeNotSupported
}
