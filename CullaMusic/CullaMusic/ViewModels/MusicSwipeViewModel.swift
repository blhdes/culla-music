import Foundation
import SwiftUI
import SwiftData
import MusicKit

@Observable
final class MusicSwipeViewModel {

    // MARK: - State

    var currentSong: Song?
    var nextSong: Song?
    var isLoading: Bool = true
    var isEmpty: Bool = false
    var toastMessage: String?

    private(set) var playlists: [Playlist] = []

    static let maxSidebar: Int = 13

    var sidebarPlaylists: [Playlist] {
        playlists
            .filter { $0.isInSidebar && $0.isEditable }
            .sorted { $0.displayOrder < $1.displayOrder }
    }

    var sidebarCount: Int { sidebarPlaylists.count }
    var canAddToSidebar: Bool { sidebarCount < Self.maxSidebar }

    private(set) var sessionSortedCount: Int = 0
    private(set) var sessionDismissedCount: Int = 0
    private(set) var sessionSkippedCount: Int = 0

    private(set) var actionHistory: [SwipeAction] = []
    var canUndo: Bool { !actionHistory.isEmpty }

    // MARK: - Dependencies

    let config: SwipeConfig
    private let service: MusicLibraryService
    private let modelContext: ModelContext

    // MARK: - Queue

    private var songQueue: [Song] = []
    private let batchSize: Int = 50
    private let refillThreshold: Int = 10

    /// Exclusion set for the current session — grows as songs are acted on.
    private var sessionExclusionSet: Set<String> = []

    // MARK: - Init

    // Explicit @MainActor on the init (not the class) avoids the macro/isolation
    // conflict that occurs when @Observable and @MainActor are both on the class.
    // No default for config — callers always supply it; removes the nonisolated
    // default-expression evaluation issue with SwipeConfig().
    @MainActor
    init(config: SwipeConfig, modelContext: ModelContext) {
        self.config = config
        self.service = MusicLibraryService.shared
        self.modelContext = modelContext
    }

    // MARK: - Initial Load

    func loadInitial() async {
        guard service.authorizationStatus == .authorized else { return }
        isLoading = true
        actionHistory.removeAll()
        service.resetLibraryCursor()

        await syncPlaylistsFromAppleMusic()

        do {
            switch config.mode {
            case .library:
                sessionExclusionSet = fetchExcludedIdentifiers()
                let songs = try await service.fetchNextLibrarySongs(
                    excluding: sessionExclusionSet,
                    desired: batchSize,
                    ascending: config.order.ascending
                )
                populateQueue(with: songs)

            case .unsorted:
                let editableIDs = try await service.fetchEditablePlaylistSongIDs()
                let sortedIDs = fetchSortedSongIDs()
                sessionExclusionSet = editableIDs.union(sortedIDs)
                let songs = try await service.fetchNextLibrarySongs(
                    excluding: sessionExclusionSet,
                    desired: batchSize,
                    ascending: config.order.ascending
                )
                populateQueue(with: songs)

            case .dismissed:
                try await loadDismissedDeck()
            }
        } catch {
            print("loadInitial failed: \(error)")
        }

        isLoading = false
        if currentSong == nil { isEmpty = true }
    }

    func reload() async {
        currentSong = nil
        nextSong = nil
        songQueue.removeAll()
        sessionExclusionSet = []
        isEmpty = false
        await loadInitial()
    }

    // MARK: - Playlists Sync

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
                // Use Playlist.Kind to decide editability — curatorName is
                // unreliable (Apple sometimes attributes user-created playlists
                // to the user themselves, which would mark them read-only).
                // Editorial / auto-generated kinds are read-only; user-shared
                // and external kinds are user-controlled.
                let editable: Bool
                switch amPlaylist.kind {
                case .editorial, .personalMix, .replay:
                    editable = false
                default:
                    editable = true
                }

                if let existing = localByAMID[amID] {
                    // Preserve isEditable=true; only re-apply the signal to
                    // records that were previously read-only. This auto-repairs
                    // playlists that were wrongly downgraded by the old
                    // curatorName-based check.
                    if !existing.isEditable {
                        existing.isEditable = editable
                    }
                    existing.name = amPlaylist.name
                } else {
                    let row = Playlist(
                        name: amPlaylist.name,
                        displayOrder: nextOrder,
                        appleMusicPlaylistID: amID,
                        isEditable: editable
                    )
                    modelContext.insert(row)
                    nextOrder += 1
                }
            }
            try? modelContext.save()

            let refreshed = fetchLocalPlaylists()
            // First-launch: auto-select the first few editable playlists for the sidebar.
            if refreshed.allSatisfy({ !$0.isInSidebar }), !refreshed.isEmpty {
                for p in refreshed.filter(\.isEditable).prefix(Self.maxSidebar) {
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

    func setSidebar(_ playlist: Playlist, included: Bool) {
        guard playlist.isEditable || !included else { return }
        playlist.isInSidebar = included
        try? modelContext.save()
        playlists = fetchLocalPlaylists()
    }

    // MARK: - Swipe Actions

    func dismissCurrent() {
        guard let song = currentSong else { return }

        if config.mode == .dismissed {
            // In dismissed mode: skip the song in this session without changing its record.
            advance()
            return
        }

        let record = DismissedSong(songID: song.id.rawValue)
        modelContext.insert(record)
        try? modelContext.save()
        actionHistory.append(.dismissed(song: song, record: record))
        sessionExclusionSet.insert(song.id.rawValue)
        sessionDismissedCount += 1
        toastMessage = "Dismissed"
        advance()
    }

    /// Skip is in-session only: no SwiftData record, no Apple Music side effect.
    /// The song stays out of the deck for this run but reappears next session.
    func skipCurrent() {
        guard let song = currentSong else { return }
        sessionExclusionSet.insert(song.id.rawValue)
        sessionSkippedCount += 1
        actionHistory.append(.skipped(song: song))
        toastMessage = "Skipped"
        advance()
    }

    func assignToPlaylist(_ playlist: Playlist) {
        guard let song = currentSong else { return }
        guard let amIDString = playlist.appleMusicPlaylistID else {
            toastMessage = "Playlist not synced — try again"
            return
        }
        let amID = MusicItemID(amIDString)

        if config.mode == .dismissed {
            // Assign from dismissed: also un-dismiss by deleting the DismissedSong record.
            let descriptor = FetchDescriptor<DismissedSong>(
                predicate: #Predicate { $0.songID == song.id.rawValue }
            )
            let dismissedRecord = (try? modelContext.fetch(descriptor))?.first
            let originalDismissedAt = dismissedRecord?.dismissedAt ?? .now
            if let dismissedRecord { modelContext.delete(dismissedRecord) }

            let sortedRecord = SortedSong(songID: song.id.rawValue, playlist: playlist)
            modelContext.insert(sortedRecord)
            try? modelContext.save()
            actionHistory.append(.sortedFromDismissed(
                song: song,
                playlist: playlist,
                sortedRecord: sortedRecord,
                originalDismissedAt: originalDismissedAt
            ))
            sessionSortedCount += 1
            toastMessage = "Added to \(playlist.name)"
            advance()

            Task { @MainActor in
                do { try await service.addSong(song, toPlaylistID: amID) }
                catch { toastMessage = "Couldn't add to \(playlist.name)" }
            }
            return
        }

        // Normal mode: just sort.
        let record = SortedSong(songID: song.id.rawValue, playlist: playlist)
        modelContext.insert(record)
        try? modelContext.save()
        actionHistory.append(.sorted(song: song, playlist: playlist, record: record))
        sessionExclusionSet.insert(song.id.rawValue)
        sessionSortedCount += 1
        toastMessage = "Added to \(playlist.name)"
        advance()

        Task { @MainActor in
            do { try await service.addSong(song, toPlaylistID: amID) }
            catch { toastMessage = "Couldn't add to \(playlist.name)" }
        }
    }

    func createPlaylist(name: String, addToSidebar: Bool) async {
        do {
            let amPlaylist = try await service.createPlaylist(name: name)
            let nextOrder = (playlists.map(\.displayOrder).max() ?? -1) + 1
            let local = Playlist(
                name: name,
                displayOrder: nextOrder,
                appleMusicPlaylistID: amPlaylist.id.rawValue,
                isInSidebar: addToSidebar,
                isEditable: true
            )
            modelContext.insert(local)
            try? modelContext.save()
            playlists = fetchLocalPlaylists()
            toastMessage = "Created \(name)"
        } catch {
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
            sessionExclusionSet.remove(song.id.rawValue)
            sessionDismissedCount = max(sessionDismissedCount - 1, 0)
            pushBackToFront(song: song)

        case .skipped(let song):
            sessionExclusionSet.remove(song.id.rawValue)
            sessionSkippedCount = max(sessionSkippedCount - 1, 0)
            pushBackToFront(song: song)

        case .sorted(let song, let playlist, let record):
            modelContext.delete(record)
            try? modelContext.save()
            sessionExclusionSet.remove(song.id.rawValue)
            sessionSortedCount = max(sessionSortedCount - 1, 0)
            pushBackToFront(song: song)
            remoteRemove(song: song, fromPlaylist: playlist)

        case .sortedFromDismissed(let song, let playlist, let sortedRecord, let originalDismissedAt):
            modelContext.delete(sortedRecord)
            let restored = DismissedSong(songID: song.id.rawValue)
            restored.dismissedAt = originalDismissedAt
            modelContext.insert(restored)
            try? modelContext.save()
            sessionSortedCount = max(sessionSortedCount - 1, 0)
            pushBackToFront(song: song)
            remoteRemove(song: song, fromPlaylist: playlist)
        }
    }

    private func remoteRemove(song: Song, fromPlaylist playlist: Playlist) {
        guard let amIDString = playlist.appleMusicPlaylistID else { return }
        let amID = MusicItemID(amIDString)
        Task { @MainActor in
            do {
                try await service.removeSong(song, fromPlaylistID: amID)
                toastMessage = "Removed from \(playlist.name)"
            } catch {
                toastMessage = "Couldn't remove from \(playlist.name)"
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

    private func loadDismissedDeck() async throws {
        let ascending = config.order.ascending
        let sortDescriptor = ascending
            ? SortDescriptor<DismissedSong>(\.dismissedAt, order: .forward)
            : SortDescriptor<DismissedSong>(\.dismissedAt, order: .reverse)
        let descriptor = FetchDescriptor<DismissedSong>(sortBy: [sortDescriptor])
        let dismissed = (try? modelContext.fetch(descriptor)) ?? []

        guard !dismissed.isEmpty else {
            isEmpty = true
            return
        }

        let orderedIDs = dismissed.map(\.songID)
        let songs = try await service.resolveSongs(ids: orderedIDs)
        populateQueue(with: songs)
    }

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

        // Dismissed mode: the deck is finite, no background refill.
        guard config.mode != .dismissed else { return }

        if songQueue.count < refillThreshold {
            Task { @MainActor in
                if let more = try? await service.fetchNextLibrarySongs(
                    excluding: sessionExclusionSet,
                    desired: batchSize,
                    ascending: config.order.ascending
                ) {
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
        if let sorted = try? modelContext.fetch(FetchDescriptor<SortedSong>()) {
            excluded.formUnion(sorted.map(\.songID))
        }
        if let dismissed = try? modelContext.fetch(FetchDescriptor<DismissedSong>()) {
            excluded.formUnion(dismissed.map(\.songID))
        }
        return excluded
    }

    private func fetchSortedSongIDs() -> Set<String> {
        Set((try? modelContext.fetch(FetchDescriptor<SortedSong>()))?.map(\.songID) ?? [])
    }
}

// MARK: - Supporting Types

enum SwipeAction {
    case dismissed(song: Song, record: DismissedSong)
    case sorted(song: Song, playlist: Playlist, record: SortedSong)
    /// Right-swipe in dismissed mode: un-dismisses + adds to playlist.
    case sortedFromDismissed(song: Song, playlist: Playlist, sortedRecord: SortedSong, originalDismissedAt: Date)
    /// Down-swipe: in-session only, song reappears next launch.
    case skipped(song: Song)
}
