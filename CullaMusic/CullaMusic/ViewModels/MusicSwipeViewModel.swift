import Foundation
import SwiftUI
import SwiftData
import MusicKit

@Observable
@MainActor
final class MusicSwipeViewModel {

    // MARK: - State (observable)

    var currentSong: Song?
    var nextSong: Song?
    var isLoading: Bool = false
    var isEmpty: Bool = false
    var toastMessage: String?

    /// Snapshot of all local Playlist rows (kept in sync with Apple Music).
    private(set) var playlists: [Playlist] = []

    /// Hard cap on how many playlists can appear in the right-swipe sidebar at once.
    static let maxSidebar: Int = 5

    /// Subset of `playlists` actually shown in the sidebar.
    var sidebarPlaylists: [Playlist] {
        playlists.filter(\.isInSidebar).sorted { $0.displayOrder < $1.displayOrder }
    }

    var sidebarCount: Int { sidebarPlaylists.count }
    var canAddToSidebar: Bool { sidebarCount < Self.maxSidebar }

    // Session counters (informational)
    private(set) var sessionSortedCount: Int = 0
    private(set) var sessionDismissedCount: Int = 0

    // Undo
    private(set) var actionHistory: [SwipeAction] = []
    var canUndo: Bool { !actionHistory.isEmpty }

    // MARK: - Dependencies

    private let service: MusicLibraryService
    private let modelContext: ModelContext

    // MARK: - Queue

    private var songQueue: [Song] = []
    private let batchSize: Int = 50
    private let refillThreshold: Int = 10

    // MARK: - Init

    init(service: MusicLibraryService = .shared, modelContext: ModelContext) {
        self.service = service
        self.modelContext = modelContext
    }

    // MARK: - Initial Load

    func loadInitial() async {
        guard service.authorizationStatus == .authorized else { return }
        isLoading = true
        actionHistory.removeAll()
        service.resetLibraryCursor()

        await syncPlaylistsFromAppleMusic()

        let excluded = fetchExcludedIdentifiers()
        do {
            let songs = try await service.fetchNextLibrarySongs(excluding: excluded, desired: batchSize)
            populateQueue(with: songs)
        } catch {
            print("loadInitial fetch failed: \(error)")
        }

        isLoading = false
        if currentSong == nil { isEmpty = true }
    }

    func reload() async {
        currentSong = nil
        nextSong = nil
        songQueue.removeAll()
        isEmpty = false
        await loadInitial()
    }

    // MARK: - Playlists Sync

    /// Pulls user's Apple Music playlists and inserts a local Playlist row
    /// for every Apple Music playlist not yet tracked locally. On the first
    /// successful sync, auto-selects the first N for the sidebar so the user
    /// isn't presented with an empty sidebar on launch.
    func syncPlaylistsFromAppleMusic() async {
        do {
            let amPlaylists = try await service.refreshUserPlaylists()
            let local = fetchLocalPlaylists()
            let localByAMID = Dictionary(
                uniqueKeysWithValues: local.compactMap { p -> (String, Playlist)? in
                    guard let amID = p.appleMusicPlaylistID else { return nil }
                    return (amID, p)
                }
            )
            var nextOrder = (local.map(\.displayOrder).max() ?? -1) + 1

            for amPlaylist in amPlaylists {
                let amID = amPlaylist.id.rawValue
                if localByAMID[amID] == nil {
                    let row = Playlist(
                        name: amPlaylist.name,
                        displayOrder: nextOrder,
                        appleMusicPlaylistID: amID
                    )
                    modelContext.insert(row)
                    nextOrder += 1
                }
            }
            try? modelContext.save()

            let refreshed = fetchLocalPlaylists()
            // First-launch convenience: pre-fill sidebar with the first few playlists
            // so the user can immediately swipe-to-sort without a Manage detour.
            if refreshed.allSatisfy({ !$0.isInSidebar }), !refreshed.isEmpty {
                for p in refreshed.prefix(Self.maxSidebar) {
                    p.isInSidebar = true
                }
                try? modelContext.save()
            }

            playlists = fetchLocalPlaylists()
        } catch {
            print("syncPlaylistsFromAppleMusic failed: \(error)")
        }
    }

    private func fetchLocalPlaylists() -> [Playlist] {
        let descriptor = FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.displayOrder)])
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Toggles a playlist's sidebar membership. Caller is responsible for
    /// enforcing the `maxSidebar` cap before calling with `included: true`.
    func setSidebar(_ playlist: Playlist, included: Bool) {
        playlist.isInSidebar = included
        try? modelContext.save()
        playlists = fetchLocalPlaylists()
    }

    // MARK: - Swipe Actions

    /// Left swipe: dismiss current song. Persists so it never reappears.
    func dismissCurrent() {
        guard let song = currentSong else { return }
        let record = DismissedSong(songID: song.id.rawValue)
        modelContext.insert(record)
        try? modelContext.save()
        actionHistory.append(.dismissed(song: song, record: record))
        sessionDismissedCount += 1
        toastMessage = "Dismissed"
        advance()
    }

    /// Right swipe drop: add current song to the chosen playlist.
    func assignToPlaylist(_ playlist: Playlist) {
        guard let song = currentSong else { return }
        guard let amIDString = playlist.appleMusicPlaylistID else {
            toastMessage = "Playlist not synced — try again"
            return
        }
        let amID = MusicItemID(amIDString)

        let record = SortedSong(songID: song.id.rawValue, playlist: playlist)
        modelContext.insert(record)
        try? modelContext.save()
        actionHistory.append(.sorted(song: song, playlist: playlist, record: record))
        sessionSortedCount += 1
        toastMessage = "Added to \(playlist.name)"
        advance()

        Task { @MainActor in
            do {
                try await service.addSong(song, toPlaylistID: amID)
            } catch {
                print("addSong failed: \(error)")
                toastMessage = "Couldn't add to \(playlist.name)"
            }
        }
    }

    /// Creates a new playlist (in Apple Music + locally), optionally adding
    /// it to the sidebar. Used by the Manage sheet's "+ New playlist" flow.
    func createPlaylist(name: String, addToSidebar: Bool) async {
        do {
            let amPlaylist = try await service.createPlaylist(name: name)
            let nextOrder = (playlists.map(\.displayOrder).max() ?? -1) + 1
            let local = Playlist(
                name: name,
                displayOrder: nextOrder,
                appleMusicPlaylistID: amPlaylist.id.rawValue,
                isInSidebar: addToSidebar
            )
            modelContext.insert(local)
            try? modelContext.save()
            playlists = fetchLocalPlaylists()
            toastMessage = "Created \(name)"
        } catch {
            print("createPlaylist failed: \(error)")
            toastMessage = "Couldn't create playlist"
        }
    }

    // MARK: - Undo

    func undo() {
        guard let action = actionHistory.popLast() else { return }
        switch action {
        case .dismissed(let song, let record):
            modelContext.delete(record)
            try? modelContext.save()
            sessionDismissedCount = max(sessionDismissedCount - 1, 0)
            pushBackToFront(song: song)

        case .sorted(let song, let playlist, let record):
            modelContext.delete(record)
            try? modelContext.save()
            sessionSortedCount = max(sessionSortedCount - 1, 0)
            pushBackToFront(song: song)

            // Best-effort remote remove (currently unsupported by MusicKit — we surface a toast).
            if let amIDString = playlist.appleMusicPlaylistID {
                let amID = MusicItemID(amIDString)
                Task { @MainActor in
                    do {
                        try await service.removeSong(song, fromPlaylistID: amID)
                    } catch MusicLibraryError.removeNotSupported {
                        toastMessage = "Removed locally — open Apple Music to remove from \(playlist.name)"
                    } catch {
                        toastMessage = "Couldn't remove from \(playlist.name)"
                    }
                }
            }
        }
    }

    // MARK: - Playback

    func togglePreview() {
        guard let song = currentSong else { return }
        if service.isPlayingPreview && service.nowPlayingSongID == song.id.rawValue {
            service.stopPreview()
        } else {
            service.playPreview(for: song)
        }
    }

    // MARK: - Private

    private func populateQueue(with songs: [Song]) {
        var queue = songs
        if currentSong == nil, !queue.isEmpty {
            currentSong = queue.removeFirst()
        }
        if nextSong == nil, !queue.isEmpty {
            nextSong = queue.removeFirst()
        }
        songQueue.append(contentsOf: queue)
    }

    private func advance() {
        currentSong = nextSong
        service.stopPreview()

        if !songQueue.isEmpty {
            nextSong = songQueue.removeFirst()
        } else {
            nextSong = nil
        }

        if currentSong == nil {
            isEmpty = true
            return
        }

        // Refill in background if running low.
        if songQueue.count < refillThreshold {
            Task { @MainActor in
                let excluded = fetchExcludedIdentifiers()
                if let more = try? await service.fetchNextLibrarySongs(excluding: excluded, desired: batchSize) {
                    songQueue.append(contentsOf: more)
                    if currentSong == nil, !songQueue.isEmpty {
                        currentSong = songQueue.removeFirst()
                        isEmpty = false
                    }
                    if nextSong == nil, !songQueue.isEmpty {
                        nextSong = songQueue.removeFirst()
                    }
                }
            }
        }
    }

    private func pushBackToFront(song: Song) {
        if let next = nextSong {
            songQueue.insert(next, at: 0)
        }
        nextSong = currentSong
        currentSong = song
        isEmpty = false
    }

    private func fetchExcludedIdentifiers() -> Set<String> {
        var excluded = Set<String>()
        let sortedDescriptor = FetchDescriptor<SortedSong>()
        if let sorted = try? modelContext.fetch(sortedDescriptor) {
            excluded.formUnion(sorted.map(\.songID))
        }
        let dismissedDescriptor = FetchDescriptor<DismissedSong>()
        if let dismissed = try? modelContext.fetch(dismissedDescriptor) {
            excluded.formUnion(dismissed.map(\.songID))
        }
        return excluded
    }
}

// MARK: - Supporting Types

enum SwipeAction {
    case dismissed(song: Song, record: DismissedSong)
    case sorted(song: Song, playlist: Playlist, record: SortedSong)
}
