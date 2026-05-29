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

    /// When true, the toast renders as a snackbar with an inline Undo button
    /// and a longer auto-dismiss window. Set by destructive actions like
    /// remove-from-all-playlists where regret is more costly than a swipe.
    var toastUndoable: Bool = false

    /// In-flight Apple Music removal task spawned by `removeFromPlaylists`.
    /// Held so undo can cancel it before issuing the re-adds — otherwise the
    /// removes and re-adds race on Apple's side.
    private var pendingPlaylistRemovalTask: Task<Void, Never>?

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

    /// Per-song Apple Music playlist memberships + memoized local-Playlist
    /// resolution. Updated optimistically on sort/love/remove so chips reflect
    /// the action immediately.
    let membershipIndex: MembershipIndex

    /// Per-song dismissal timestamps + the SwiftData queries that read
    /// `DismissedSong` rows. Kept in lockstep with VM-owned inserts/deletes
    /// via `set` / `remove`.
    let dismissedStore: DismissedDateStore

    /// Resolves the up-swipe target — the user's picked playlist, an existing
    /// "Culla Loves", or a freshly-created one. Owns the eventual-consistency
    /// self-heal that runs when a write to the loved target fails.
    let lovedResolver: LovedPlaylistResolver

    let undoCoordinator = UndoCoordinator()
    var canUndo: Bool { undoCoordinator.canUndo }
    var actionCount: Int { undoCoordinator.count }

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

    /// Optional pre-loaded songs to lead the deck — set when the swipe is
    /// launched from `HomeArtCarouselView` so the user starts on the cover
    /// they were exploring (and the already-playing preview keeps going).
    /// These are consumed by `loadInitial()`; subsequent paging continues
    /// normally with these songs added to the exclusion set so they don't
    /// reappear.
    private var anchorSongs: [Song] = []

    // MARK: - Init

    // Explicit @MainActor on the init (not the class) avoids the macro/isolation
    // conflict that occurs when @Observable and @MainActor are both on the class.
    // No default for config — callers always supply it; removes the nonisolated
    // default-expression evaluation issue with SwipeConfig().
    @MainActor
    init(config: SwipeConfig, modelContext: ModelContext, anchorSongs: [Song] = []) {
        self.config = config
        self.anchorSongs = anchorSongs
        let service = MusicLibraryService.shared
        self.service = service
        self.modelContext = modelContext
        self.membershipIndex = MembershipIndex(service: service)
        self.lovedResolver = LovedPlaylistResolver(service: service, modelContext: modelContext)
        self.dismissedStore = DismissedDateStore(modelContext: modelContext)
        // Wire post-init closures: capturing `self` inside the property
        // initializers above isn't allowed yet (self isn't fully constructed).
        // Weak captures so the coordinators don't outlive the VM.
        self.membershipIndex.setPlaylistsProvider { [weak self] in
            self?.playlists ?? []
        }
        self.lovedResolver.setPlaylistsProvider { [weak self] in
            self?.playlists ?? []
        }
        self.lovedResolver.setOnPlaylistsChanged { [weak self] in
            self?.refreshLocalPlaylists()
        }
    }

    // MARK: - Initial Load

    func loadInitial() async {
        guard service.authorizationStatus == .authorized else { return }
        isLoading = true
        undoCoordinator.clear()
        service.resetLibraryCursor()

        // Sync is one round-trip and needed for sidebar + chips; keep it
        // blocking. The membership index is the slow step — defer it where we
        // can so the first card paints sooner.
        await syncPlaylistsFromAppleMusic()

        // Pre-seed the exclusion set with anchor IDs so the subsequent page
        // fetches don't double-list a song that's already at the head of the
        // queue. The anchors themselves come from `HomeArtCarouselView`, which
        // computes the same exclusion semantics — so any anchor we got is one
        // the session would naturally surface anyway.
        let anchorIDs = Set(anchorSongs.map { $0.id.rawValue })

        do {
            switch config.mode {
            case .library:
                sessionExclusionSet = fetchExcludedIdentifiers().union(anchorIDs)
                dismissedStore.loadAll()
                let fetched = try await fetchNextSessionSongs()
                populateQueue(with: anchorSongs + fetched)
                // Membership chips fill in once the index lands — the card is
                // already on screen by then.
                Task { @MainActor in await membershipIndex.rebuild() }

            case .unsorted:
                // Unsorted needs every playlist's tracks anyway (to compute the
                // exclusion set), so we build the membership index from the
                // SAME parallel fetch instead of walking the library twice.
                let data = try await service.fetchAllPlaylistData(
                    includeCurated: true
                )
                membershipIndex.setIndex(data.membershipIndex)
                let sortedIDs = fetchSortedSongIDs()
                // Only *recent* dismissals stay excluded — anything older than
                // DismissedDateStore.resurfaceWindow comes back into the deck
                // so the user can give it another chance (marked with the
                // "Dismissed Xmo ago" chip).
                let recentDismissed = dismissedStore.recentSongIDs()
                sessionExclusionSet = data.songIDs
                    .union(sortedIDs)
                    .union(recentDismissed)
                    .union(anchorIDs)
                dismissedStore.loadAll()
                let fetched = try await service.fetchNextLibrarySongs(
                    excluding: sessionExclusionSet,
                    desired: batchSize,
                    ascending: config.order.ascending
                )
                populateQueue(with: anchorSongs + fetched)

            case .dismissed:
                dismissedStore.loadAll()
                try await loadDismissedDeck(skipping: anchorIDs, leadingWith: anchorSongs)
                Task { @MainActor in await membershipIndex.rebuild() }
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
        membershipIndex.reset()
        dismissedStore.reset()
        isEmpty = false
        await loadInitial()
    }

    // MARK: - Playlist Membership Index

    /// Passthrough to `membershipIndex.memberships(for:)` — kept on the VM so
    /// the view's call sites (read on every drag frame) don't have to reach
    /// through the coordinator. Memoization lives in `MembershipIndex`.
    func playlistMemberships(for song: Song) -> [Playlist] {
        membershipIndex.memberships(for: song)
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
                let editable = computeEditability(for: amPlaylist)

                if let existing = localByAMID[amID] {
                    let wasEditable = existing.isEditable
                    // Editability mirrors Apple's current kind/name every sync —
                    // no local latch, so it can never get stuck read-only.
                    existing.isEditable = editable
                    existing.name = amPlaylist.name

                    if wasEditable && !editable {
                        if existing.isInSidebar { existing.isInSidebar = false }
                        let defaults = UserDefaults.standard
                        if defaults.string(forKey: LovedPlaylistResolver.defaultsKey) == amID {
                            defaults.removeObject(forKey: LovedPlaylistResolver.defaultsKey)
                        }
                    }
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

            refreshLocalPlaylists()
        } catch {
            print("syncPlaylistsFromAppleMusic failed: \(error)")
        }
    }

    private func fetchLocalPlaylists() -> [Playlist] {
        let descriptor = FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.displayOrder)])
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Centralizes the "we just changed something about the playlists table"
    /// step so the memoized memberships cache stays in sync with the array
    /// the view sees. Every mutation path used to reassign `playlists` inline
    /// — going through this helper means no caller forgets the invalidation.
    private func refreshLocalPlaylists() {
        playlists = fetchLocalPlaylists()
        membershipIndex.invalidateCache()
    }

    func setSidebar(_ playlist: Playlist, included: Bool) {
        guard playlist.isEditable || !included else { return }
        playlist.isInSidebar = included
        try? modelContext.save()
        refreshLocalPlaylists()
    }

    // MARK: - Swipe Actions

    func dismissCurrent() {
        guard let song = currentSong else { return }
        let songID = song.id.rawValue

        // Re-dismiss path: the song already has a DismissedSong row. Reached
        // from Unsorted (resurfaced old dismissals) and from Dismissed mode
        // itself (every card has a record). Bump the timestamp so the deck
        // re-orders by recency next session instead of orphaning duplicates.
        if let existing = dismissedStore.record(for: songID) {
            let originalDismissedAt = existing.dismissedAt
            existing.dismissedAt = .now
            try? modelContext.save()
            undoCoordinator.record(.redismissed(
                song: song,
                record: existing,
                originalDismissedAt: originalDismissedAt
            ))
            sessionExclusionSet.insert(songID)
            dismissedStore.set(songID: songID, date: existing.dismissedAt)
            sessionDismissedCount += 1
            setToast("Dismissed")
            advance()
            return
        }

        let record = DismissedSong(songID: songID)
        modelContext.insert(record)
        try? modelContext.save()
        undoCoordinator.record(.dismissed(song: song, record: record))
        sessionExclusionSet.insert(songID)
        dismissedStore.set(songID: songID, date: record.dismissedAt)
        sessionDismissedCount += 1
        // Only a playlist scope can surface a catalog-only track; every other
        // deck is library-bound, so skip the lookup there.
        if config.isPlaylistSource {
            classifyDismissedTrack(recordID: record.id, song: song)
        }
        setToast("Dismissed")
        advance()
    }

    /// Skip is in-session only: no SwiftData record, no Apple Music side effect.
    /// The song stays out of the deck for this run but reappears next session.
    func skipCurrent() {
        guard let song = currentSong else { return }
        sessionExclusionSet.insert(song.id.rawValue)
        sessionSkippedCount += 1
        undoCoordinator.record(.skipped(song: song))
        setToast("Skipped")
        advance()
    }

    func assignToPlaylist(_ playlist: Playlist) {
        guard let song = currentSong else { return }
        guard let amIDString = playlist.appleMusicPlaylistID else {
            setToast("Playlist not synced — try again")
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
            if let dismissedRecord {
                modelContext.delete(dismissedRecord)
                dismissedStore.remove(songID: song.id.rawValue)
            }

            let sortedRecord = SortedSong(songID: song.id.rawValue, playlist: playlist)
            modelContext.insert(sortedRecord)
            try? modelContext.save()
            undoCoordinator.record(.sortedFromDismissed(
                song: song,
                playlist: playlist,
                sortedRecord: sortedRecord,
                originalDismissedAt: originalDismissedAt
            ))
            sessionSortedCount += 1
            addMembership(songID: song.id.rawValue, playlistAMID: amID)
            setToast("Added to \(playlist.name)")
            advance()

            Task { @MainActor in
                do { try await service.addSong(song, toPlaylistID: amID) }
                catch { setToast("Couldn't add to \(playlist.name)") }
            }
            return
        }

        // Normal mode: just sort.
        let record = SortedSong(songID: song.id.rawValue, playlist: playlist)
        modelContext.insert(record)
        try? modelContext.save()
        undoCoordinator.record(.sorted(song: song, playlist: playlist, record: record))
        sessionExclusionSet.insert(song.id.rawValue)
        sessionSortedCount += 1
        addMembership(songID: song.id.rawValue, playlistAMID: amID)
        setToast("Added to \(playlist.name)")
        advance()

        Task { @MainActor in
            do {
                try await service.addSong(song, toPlaylistID: amID)
            } catch {
                setToast("Couldn't add to \(playlist.name)")
                return
            }
            // The add landed. In Move mode we also strip the song from the
            // source — but some sources (e.g. imported `.external` playlists)
            // accept adds yet reject track-list edits, so the removal can fail
            // even though the add succeeded. Keep the add (it stands as a copy)
            // and report the removal failure honestly rather than mislabeling
            // it as an add failure.
            do {
                try await removeFromSourceIfNeeded(song: song, destinationPlaylist: playlist)
            } catch {
                let sourceName = config.sourcePlaylistName ?? "source playlist"
                setToast("Couldn't remove from \(sourceName)")
            }
        }
    }

    /// Strips the current song from a chosen subset of its playlists. Used by
    /// the long-press cleanup sheet in Dismissed mode. The `DismissedSong` row
    /// is left intact — the song stays dismissed, it just stops showing in
    /// those playlists. Local `SortedSong` rows for the targeted playlists are
    /// deleted; their `sortedAt` is captured so undo can recreate them.
    func removeFromPlaylists(_ playlists: [Playlist]) {
        guard let song = currentSong else { return }
        guard !playlists.isEmpty else { return }

        let songID = song.id.rawValue
        let targetAMIDs = Set(playlists.compactMap(\.appleMusicPlaylistID))
        guard !targetAMIDs.isEmpty else { return }

        // Snapshot existing SortedSong rows for the target playlists so undo
        // can recreate them with their original sortedAt instead of .now.
        let sortedDescriptor = FetchDescriptor<SortedSong>(
            predicate: #Predicate { $0.songID == songID }
        )
        let allExistingRecords = (try? modelContext.fetch(sortedDescriptor)) ?? []
        let targetedRecords = allExistingRecords.filter { record in
            guard let amID = record.playlist?.appleMusicPlaylistID else { return false }
            return targetAMIDs.contains(amID)
        }
        let sortedAtByPlaylistAMID: [String: Date] = Dictionary(
            uniqueKeysWithValues: targetedRecords.compactMap { record in
                guard let amID = record.playlist?.appleMusicPlaylistID else { return nil }
                return (amID, record.sortedAt)
            }
        )

        let snapshots = playlists.map { playlist in
            PlaylistRemovalSnapshot(
                playlist: playlist,
                sortedAt: playlist.appleMusicPlaylistID.flatMap { sortedAtByPlaylistAMID[$0] }
            )
        }

        for record in targetedRecords {
            modelContext.delete(record)
        }
        try? modelContext.save()

        // Drop only the affected AM IDs from the membership index — any
        // playlists the user left checked stay in place.
        for amID in targetAMIDs {
            membershipIndex.remove(songID: songID, playlistAMID: amID)
        }
        undoCoordinator.record(.removedFromPlaylists(song: song, removals: snapshots))

        let count = snapshots.count
        let plural = count == 1 ? "" : "s"
        setToast("Removing from \(count) playlist\(plural)…", undoable: true)

        pendingPlaylistRemovalTask?.cancel()
        pendingPlaylistRemovalTask = Task { @MainActor in
            var failures = 0
            for snapshot in snapshots {
                if Task.isCancelled { return }
                guard let amIDString = snapshot.playlist.appleMusicPlaylistID else { continue }
                let amID = MusicItemID(amIDString)
                do {
                    try await service.removeSong(song, fromPlaylistID: amID)
                } catch {
                    failures += 1
                }
            }
            if Task.isCancelled { return }
            let succeeded = count - failures
            if failures == 0 {
                setToast("Removed from \(count) playlist\(plural)", undoable: true)
            } else {
                setToast("Removed from \(succeeded), \(failures) failed", undoable: true)
            }
            pendingPlaylistRemovalTask = nil
        }
    }

    /// Deletes the current song's `DismissedSong` row, dropping it from the
    /// dismissed deck. Playlist memberships are untouched — if the song was in
    /// playlists it stays there; otherwise it resurfaces in Unsorted next time.
    /// Card advances. Undo recreates the row with its original timestamp.
    func forgetCurrentDismissal() {
        guard let song = currentSong else { return }
        let songID = song.id.rawValue
        guard let record = dismissedStore.record(for: songID) else { return }

        let originalDismissedAt = record.dismissedAt
        modelContext.delete(record)
        try? modelContext.save()

        dismissedStore.remove(songID: songID)
        sessionExclusionSet.insert(songID)
        undoCoordinator.record(.forgotDismissal(song: song, dismissedAt: originalDismissedAt))
        setToast("Dismissal forgotten")
        advance()
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
                isEditable: true,
                createdByApp: true
            )
            modelContext.insert(local)
            try? modelContext.save()
            refreshLocalPlaylists()
            setToast("Created \(name)")
        } catch {
            setToast("Couldn't create playlist")
        }
    }

    // MARK: - Loved (up-swipe)

    /// Up-swipe target. Mirrors `assignToPlaylist` but resolves the destination
    /// from the persisted `lovedPlaylistID` (auto-creates "Culla Loves" the
    /// first time). Returns immediately if the song already belongs to the
    /// loved playlist, so a stray second up-swipe no-ops gracefully.
    func loveCurrent() {
        guard let song = currentSong else { return }

        Task { @MainActor in
            guard let playlist = await lovedResolver.resolveOrCreate() else {
                setToast("Couldn't open Loved playlist")
                return
            }

            guard let amIDString = playlist.appleMusicPlaylistID else {
                setToast("Loved playlist not synced — try again")
                return
            }
            let amID = MusicItemID(amIDString)

            // Already loved? Skip silently — chip + a toast tell the user.
            let existing = membershipIndex.index[song.id.rawValue] ?? []
            if existing.contains(amID) {
                setToast("Already loved")
                advance()
                return
            }

            let songID = song.id.rawValue

            // Loving a dismissed track also un-dismisses it — otherwise the
            // song lives in both the Loved playlist and the Dismissed deck,
            // which is contradictory. The original dismissedAt rides along
            // so undo can restore the prior state.
            let dismissedRecord = dismissedStore.record(for: songID)
            let originalDismissedAt = dismissedRecord?.dismissedAt
            if let dismissedRecord {
                modelContext.delete(dismissedRecord)
                dismissedStore.remove(songID: songID)
            }

            let record = SortedSong(songID: songID, playlist: playlist)
            modelContext.insert(record)
            try? modelContext.save()
            let recordID = record.id
            if let originalDismissedAt {
                undoCoordinator.record(.lovedFromDismissed(
                    song: song,
                    playlist: playlist,
                    record: record,
                    originalDismissedAt: originalDismissedAt
                ))
            } else {
                undoCoordinator.record(.loved(song: song, playlist: playlist, record: record))
            }
            sessionExclusionSet.insert(songID)
            sessionSortedCount += 1
            addMembership(songID: songID, playlistAMID: amID)
            setToast(originalDismissedAt == nil ? "Loved" : "Loved & restored")
            advance()

            do {
                try await service.addSong(song, toPlaylistID: amID)
            } catch {
                print("loveCurrent addSong failed: \(error)")
                // Either way, undo the optimistic local write so the song
                // doesn't silently disappear from the library deck next
                // session — we treat SortedSong membership as "permanently
                // sorted".
                rollbackLoved(
                    song: song,
                    recordID: recordID,
                    playlistAMID: amID,
                    restoreDismissedAt: originalDismissedAt
                )

                if lovedResolver.isSessionCreated(amIDString) {
                    // We created this playlist ourselves earlier in this
                    // process — Apple Music's library is eventually consistent
                    // for new playlists, so the first add usually fails even
                    // when the playlist is healthy. Leaving defaults +
                    // editability alone lets the next up-swipe (this session
                    // or next launch) hit the same playlist instead of
                    // creating a fresh duplicate every time.
                    setToast("Couldn't reach \(playlist.name) — try again")
                } else {
                    // A real write failure on a playlist we didn't just create.
                    // Drop the loved-target pointer so the next up-swipe picks a
                    // fresh target; we don't brand it read-only off one failure.
                    let displayName = playlist.name
                    lovedResolver.forgetLovedTarget(playlist)
                    setToast("Couldn't add to \(displayName)")
                }
            }
        }
    }

    /// Reverses every side-effect of an optimistic `loveCurrent` write when
    /// the Apple Music call fails. Removes the action from history first so
    /// the soon-to-be-deleted SortedSong reference doesn't outlive its row.
    /// When `restoreDismissedAt` is non-nil, the song was un-dismissed as
    /// part of the love operation — reinsert the DismissedSong with the
    /// original timestamp so the local state matches what was on disk before.
    private func rollbackLoved(
        song: Song,
        recordID: UUID,
        playlistAMID: MusicItemID,
        restoreDismissedAt: Date? = nil
    ) {
        let songID = song.id.rawValue
        undoCoordinator.remove { action in
            if case .loved(_, _, let r) = action { return r.id == recordID }
            if case .lovedFromDismissed(_, _, let r, _) = action { return r.id == recordID }
            return false
        }

        let descriptor = FetchDescriptor<SortedSong>(
            predicate: #Predicate { $0.id == recordID }
        )
        if let row = (try? modelContext.fetch(descriptor))?.first {
            modelContext.delete(row)
        }

        if let restoreDismissedAt {
            let restored = DismissedSong(songID: songID)
            restored.dismissedAt = restoreDismissedAt
            modelContext.insert(restored)
            dismissedStore.set(songID: songID, date: restoreDismissedAt)
            classifyDismissedTrack(recordID: restored.id, song: song)
        }

        try? modelContext.save()

        sessionExclusionSet.remove(songID)
        sessionSortedCount = max(sessionSortedCount - 1, 0)
        removeMembership(songID: songID, playlistAMID: playlistAMID.rawValue)
    }

    // MARK: - Undo

    func undo() {
        guard let action = undoCoordinator.popLast() else { return }
        switch action {
        case .dismissed(let song, let record):
            modelContext.delete(record)
            try? modelContext.save()
            sessionExclusionSet.remove(song.id.rawValue)
            dismissedStore.remove(songID: song.id.rawValue)
            sessionDismissedCount = max(sessionDismissedCount - 1, 0)
            pushBackToFront(song: song)

        case .redismissed(let song, let record, let originalDismissedAt):
            // The row was never deleted — only the timestamp moved. Put it
            // back so the resurface window math stays correct.
            record.dismissedAt = originalDismissedAt
            try? modelContext.save()
            sessionExclusionSet.remove(song.id.rawValue)
            dismissedStore.set(songID: song.id.rawValue, date: originalDismissedAt)
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
            removeMembership(songID: song.id.rawValue, playlistAMID: playlist.appleMusicPlaylistID)
            pushBackToFront(song: song)
            remoteRemove(song: song, fromPlaylist: playlist)
            remoteRestoreToSourceIfNeeded(song: song, destinationPlaylist: playlist)

        case .sortedFromDismissed(let song, let playlist, let sortedRecord, let originalDismissedAt):
            modelContext.delete(sortedRecord)
            let restored = DismissedSong(songID: song.id.rawValue)
            restored.dismissedAt = originalDismissedAt
            modelContext.insert(restored)
            try? modelContext.save()
            classifyDismissedTrack(recordID: restored.id, song: song)
            sessionSortedCount = max(sessionSortedCount - 1, 0)
            dismissedStore.set(songID: song.id.rawValue, date: originalDismissedAt)
            removeMembership(songID: song.id.rawValue, playlistAMID: playlist.appleMusicPlaylistID)
            pushBackToFront(song: song)
            remoteRemove(song: song, fromPlaylist: playlist)

        case .loved(let song, let playlist, let record):
            modelContext.delete(record)
            try? modelContext.save()
            sessionExclusionSet.remove(song.id.rawValue)
            sessionSortedCount = max(sessionSortedCount - 1, 0)
            removeMembership(songID: song.id.rawValue, playlistAMID: playlist.appleMusicPlaylistID)
            pushBackToFront(song: song)
            remoteRemove(song: song, fromPlaylist: playlist)

        case .lovedFromDismissed(let song, let playlist, let record, let originalDismissedAt):
            modelContext.delete(record)
            let restored = DismissedSong(songID: song.id.rawValue)
            restored.dismissedAt = originalDismissedAt
            modelContext.insert(restored)
            try? modelContext.save()
            classifyDismissedTrack(recordID: restored.id, song: song)
            sessionExclusionSet.remove(song.id.rawValue)
            sessionSortedCount = max(sessionSortedCount - 1, 0)
            dismissedStore.set(songID: song.id.rawValue, date: originalDismissedAt)
            removeMembership(songID: song.id.rawValue, playlistAMID: playlist.appleMusicPlaylistID)
            pushBackToFront(song: song)
            remoteRemove(song: song, fromPlaylist: playlist)

        case .removedFromPlaylists(let song, let removals):
            // Cancel any in-flight Apple Music removals first so we don't
            // race remove and add on the same playlist.
            pendingPlaylistRemovalTask?.cancel()
            pendingPlaylistRemovalTask = nil
            toastUndoable = false

            // Recreate any SortedSong rows that existed, preserving sortedAt.
            for removal in removals {
                if let sortedAt = removal.sortedAt {
                    let record = SortedSong(songID: song.id.rawValue, playlist: removal.playlist)
                    record.sortedAt = sortedAt
                    modelContext.insert(record)
                }
            }
            try? modelContext.save()

            // Merge restored AM IDs back into the membership index. `add` is
            // dedup-safe — playlists the user left checked stay in place, and
            // the existing order is preserved.
            for snapshot in removals {
                guard let amID = snapshot.playlist.appleMusicPlaylistID else { continue }
                membershipIndex.add(songID: song.id.rawValue, playlistAMID: MusicItemID(amID))
            }

            // The card never advanced, so no pushBackToFront — undo restores
            // memberships in place. Apple Music re-adds happen in the
            // background; toast reports the outcome.
            let count = removals.count
            let plural = count == 1 ? "" : "s"
            setToast("Restoring to \(count) playlist\(plural)…")

            Task { @MainActor in
                var failures = 0
                for removal in removals {
                    guard let amIDString = removal.playlist.appleMusicPlaylistID else { continue }
                    let amID = MusicItemID(amIDString)
                    do {
                        try await service.addSong(song, toPlaylistID: amID)
                    } catch {
                        failures += 1
                    }
                }
                if failures == 0 {
                    setToast("Restored to \(count) playlist\(plural)")
                } else {
                    setToast("Restored to \(count - failures), \(failures) failed")
                }
            }

        case .forgotDismissal(let song, let dismissedAt):
            let restored = DismissedSong(songID: song.id.rawValue)
            restored.dismissedAt = dismissedAt
            modelContext.insert(restored)
            try? modelContext.save()
            classifyDismissedTrack(recordID: restored.id, song: song)
            sessionExclusionSet.remove(song.id.rawValue)
            dismissedStore.set(songID: song.id.rawValue, date: dismissedAt)
            pushBackToFront(song: song)
        }
    }

    /// Single entry point for toast updates. Pairs `toastMessage` with
    /// `toastUndoable` so the snackbar flag can't leak from a previous
    /// destructive action into a later, unrelated toast. `toastUndoable` is
    /// written first so the view's `onChange(of: toastMessage)` reads the
    /// correct snackbar mode for its timer.
    private func setToast(_ message: String, undoable: Bool = false) {
        toastUndoable = undoable
        toastMessage = message
    }

    private func addMembership(songID: String, playlistAMID: MusicItemID) {
        membershipIndex.add(songID: songID, playlistAMID: playlistAMID)
    }

    private func removeMembership(songID: String, playlistAMID: String?) {
        membershipIndex.remove(songID: songID, playlistAMID: playlistAMID)
    }

    private func remoteRemove(song: Song, fromPlaylist playlist: Playlist) {
        guard let amIDString = playlist.appleMusicPlaylistID else { return }
        let amID = MusicItemID(amIDString)
        Task { @MainActor in
            do {
                try await service.removeSong(song, fromPlaylistID: amID)
                setToast("Removed from \(playlist.name)")
            } catch {
                setToast("Couldn't remove from \(playlist.name)")
            }
        }
    }

    // MARK: - Playback

    func togglePreview() {
        guard let song = currentSong else { return }
        // Same song already loaded: pause/resume in place so the position is
        // kept. A different song (or nothing loaded): start fresh from the top.
        if service.nowPlayingSongID == song.id.rawValue {
            if service.isPlayingPreview {
                service.pausePreview()
            } else {
                service.resumePreview()
            }
        } else {
            service.playPreview(for: song)
        }
    }

    // MARK: - Private

    /// Loads the dismissed deck in order. When an anchor is in play (the swipe
    /// was launched from `HomeArtCarouselView`), the anchor songs lead the
    /// deck and the SwiftData fetch skips their IDs so the same songs don't
    /// land in the queue twice.
    private func loadDismissedDeck(
        skipping skipIDs: Set<String> = [],
        leadingWith lead: [Song] = []
    ) async throws {
        let ascending = config.order.ascending
        let sortDescriptor = ascending
            ? SortDescriptor<DismissedSong>(\.dismissedAt, order: .forward)
            : SortDescriptor<DismissedSong>(\.dismissedAt, order: .reverse)
        let descriptor = FetchDescriptor<DismissedSong>(sortBy: [sortDescriptor])
        let dismissed = (try? modelContext.fetch(descriptor)) ?? []

        guard !dismissed.isEmpty || !lead.isEmpty else {
            isEmpty = true
            return
        }

        let remaining = dismissed.filter { !skipIDs.contains($0.songID) }
        let remainingIDs = remaining.map(\.songID)
        let catalogIDs = Set(remaining.filter(\.isCatalogTrack).map(\.songID))
        let resolved = remainingIDs.isEmpty
            ? []
            : try await service.resolveSongs(orderedIDs: remainingIDs, catalogIDs: catalogIDs)
        populateQueue(with: lead + resolved)
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
                if let more = try? await fetchNextSessionSongs() {
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

    /// Marks a dismissed record as a catalog track when the song isn't in the
    /// user's library, so the Dismissed deck later resolves it from the catalog
    /// instead of dropping it. Runs after the optimistic dismiss — the flag
    /// only affects future Dismissed loads, never the current advance — so the
    /// swipe stays instant. Re-fetches by id so an undo that deleted the row in
    /// the meantime is a harmless no-op. The split is decided by a real library
    /// lookup, never by inspecting the ID string (which risks a catalog/library
    /// namespace collision).
    private func classifyDismissedTrack(recordID: UUID, song: Song) {
        Task { @MainActor in
            let inLibrary = await service.isInLibrary(songID: song.id)
            guard !inLibrary else { return }
            let descriptor = FetchDescriptor<DismissedSong>(
                predicate: #Predicate { $0.id == recordID }
            )
            guard let row = (try? modelContext.fetch(descriptor))?.first else { return }
            row.isCatalogTrack = true
            try? modelContext.save()
        }
    }

    private func fetchExcludedIdentifiers() -> Set<String> {
        var excluded = Set<String>()
        // Scoped sources (playlist or artist) are "revisit this collection
        // with purity" — we show everything in scope regardless of prior
        // sorts so the user can freely re-categorize, with chips revealing
        // existing memberships. Dismissals are filtered by default; the
        // `includeDismissedInScope` opt-in flips that for "audit this
        // collection" sessions, and the per-card "Dismissed Xmo ago" chip
        // signals the song's history when it re-appears.
        if config.source == nil,
           let sorted = try? modelContext.fetch(FetchDescriptor<SortedSong>()) {
            excluded.formUnion(sorted.map(\.songID))
        }
        let keepDismissedOut = config.source == nil || !config.includeDismissedInScope
        if keepDismissedOut,
           let dismissed = try? modelContext.fetch(FetchDescriptor<DismissedSong>()) {
            excluded.formUnion(dismissed.map(\.songID))
        }
        return excluded
    }

    /// Passthrough to `dismissedStore.date(for:)` — view body reads this on
    /// every drag frame; keeping the API on the VM avoids reaching through.
    func dismissedDate(for song: Song) -> Date? {
        dismissedStore.date(for: song)
    }

    private func fetchNextSessionSongs() async throws -> [Song] {
        if config.mode == .library, let source = config.source {
            switch source {
            case .playlist(let id, _, _):
                return try await service.fetchNextPlaylistSongs(
                    playlistID: MusicItemID(id),
                    excluding: sessionExclusionSet,
                    desired: batchSize,
                    ascending: config.order.ascending
                )
            case .artist(let id, _):
                return try await service.fetchNextArtistSongs(
                    artistID: MusicItemID(id),
                    excluding: sessionExclusionSet,
                    desired: batchSize,
                    ascending: config.order.ascending
                )
            }
        }

        return try await service.fetchNextLibrarySongs(
            excluding: sessionExclusionSet,
            desired: batchSize,
            ascending: config.order.ascending
        )
    }

    private func removeFromSourceIfNeeded(song: Song, destinationPlaylist: Playlist) async throws {
        guard config.sourceTransferMode == .move,
              let sourcePlaylistID = config.sourcePlaylistID,
              sourcePlaylistID != destinationPlaylist.appleMusicPlaylistID
        else { return }

        try await service.removeSong(song, fromPlaylistID: MusicItemID(sourcePlaylistID))
    }

    private func remoteRestoreToSourceIfNeeded(song: Song, destinationPlaylist: Playlist) {
        guard config.sourceTransferMode == .move,
              let sourcePlaylistID = config.sourcePlaylistID,
              sourcePlaylistID != destinationPlaylist.appleMusicPlaylistID
        else { return }

        let sourceName = config.sourcePlaylistName ?? "source playlist"
        Task { @MainActor in
            do {
                try await service.addSong(song, toPlaylistID: MusicItemID(sourcePlaylistID))
            } catch {
                setToast("Couldn't restore to \(sourceName)")
            }
        }
    }

    private func fetchSortedSongIDs() -> Set<String> {
        Set((try? modelContext.fetch(FetchDescriptor<SortedSong>()))?.map(\.songID) ?? [])
    }
}

