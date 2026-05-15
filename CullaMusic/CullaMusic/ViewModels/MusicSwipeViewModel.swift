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

    /// Per-song Apple Music playlist memberships. Built once per session and
    /// updated optimistically when the user sorts / undoes a sort.
    private(set) var membershipIndex: [String: [MusicItemID]] = [:]

    /// Per-song dismissal timestamps for every `DismissedSong` row (any age).
    /// Drives the "Dismissed Xmo ago" chip on the card. Kept in sync alongside
    /// SwiftData mutations so the chip lookup stays O(1) — the view reads it
    /// on every drag frame.
    private(set) var dismissedDates: [String: Date] = [:]

    /// Memoized result of `playlistMemberships(for:)` keyed by songID. The
    /// view body calls that method on every drag frame, so without this we'd
    /// re-filter+sort the playlists array 60 times per second AND hand SwiftUI
    /// a fresh array reference each time (forcing the card to re-render).
    /// Invalidated whenever `playlists` or `membershipIndex` changes.
    private var membershipsCache: [String: [Playlist]] = [:]

    /// Apple Music ID of the loved playlist that *this* process created via
    /// `resolveOrCreateLovedPlaylist`. Lets `loveCurrent` distinguish "first
    /// add to a brand-new playlist that Apple hasn't fully propagated" from
    /// "tried to write into a genuinely read-only playlist" so we don't trash
    /// our own freshly-created playlist on a transient timing failure.
    private var sessionCreatedLovedAMID: String?

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

        // Sync is one round-trip and needed for sidebar + chips; keep it
        // blocking. The membership index is the slow step — defer it where we
        // can so the first card paints sooner.
        await syncPlaylistsFromAppleMusic()

        do {
            switch config.mode {
            case .library:
                sessionExclusionSet = fetchExcludedIdentifiers()
                dismissedDates = fetchAllDismissedDates()
                let songs = try await fetchNextSessionSongs()
                populateQueue(with: songs)
                // Membership chips fill in once the index lands — the card is
                // already on screen by then.
                Task { @MainActor in await rebuildMembershipIndex() }

            case .unsorted:
                // Unsorted needs every playlist's tracks anyway (to compute the
                // exclusion set), so we build the membership index from the
                // SAME parallel fetch instead of walking the library twice.
                let chipToggleOn = UserDefaults.standard.bool(forKey: "membershipIncludeCurated")
                let data = try await service.fetchAllPlaylistData(
                    includeCurated: !chipToggleOn
                )
                membershipIndex = data.membershipIndex
                membershipsCache.removeAll(keepingCapacity: true)
                let sortedIDs = fetchSortedSongIDs()
                // Only *recent* dismissals stay excluded — anything older than
                // dismissedResurfaceAfter comes back into the deck so the user
                // can give it another chance (marked with the "Dismissed Xmo
                // ago" chip).
                let recentDismissed = fetchRecentDismissedSongIDs()
                sessionExclusionSet = data.songIDs.union(sortedIDs).union(recentDismissed)
                dismissedDates = fetchAllDismissedDates()
                let songs = try await service.fetchNextLibrarySongs(
                    excluding: sessionExclusionSet,
                    desired: batchSize,
                    ascending: config.order.ascending
                )
                populateQueue(with: songs)

            case .dismissed:
                dismissedDates = fetchAllDismissedDates()
                try await loadDismissedDeck()
                Task { @MainActor in await rebuildMembershipIndex() }
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
        membershipIndex = [:]
        membershipsCache.removeAll(keepingCapacity: true)
        dismissedDates = [:]
        isEmpty = false
        await loadInitial()
    }

    // MARK: - Playlist Membership Index

    /// Builds the per-song playlist membership index from Apple Music.
    /// Reads the `membershipIncludeCurated` toggle to decide whether to include
    /// editorial / replay / personalMix playlists.
    func rebuildMembershipIndex() async {
        let includeCurated = UserDefaults.standard.bool(forKey: "membershipIncludeCurated")
        do {
            membershipIndex = try await service.fetchPlaylistMembershipIndex(
                includeCurated: includeCurated
            )
            membershipsCache.removeAll(keepingCapacity: true)
        } catch {
            print("rebuildMembershipIndex failed: \(error)")
        }
    }

    /// Recomputes the exclusion set in unsorted mode after the toggle flips.
    /// Future refills will respect the new scope; the currently-visible song
    /// and the small in-flight queue stay as-is until naturally swiped, which
    /// preserves the undo history.
    @MainActor
    func refreshUnsortedExclusion() async {
        guard config.mode == .unsorted else { return }
        do {
            let chipToggleOn = UserDefaults.standard.bool(forKey: "membershipIncludeCurated")
            let playlistSongIDs = try await service.fetchPlaylistSongIDs(
                includeCurated: !chipToggleOn
            )
            let sortedIDs = fetchSortedSongIDs()
            let recentDismissed = fetchRecentDismissedSongIDs()
            sessionExclusionSet = playlistSongIDs.union(sortedIDs).union(recentDismissed)
        } catch {
            print("refreshUnsortedExclusion failed: \(error)")
        }
    }

    /// Returns the local `Playlist` rows (sorted by displayOrder) that the
    /// given song currently belongs to. Returns an empty array when the song
    /// isn't in any tracked playlist.
    ///
    /// Memoized — the view body asks for this on every drag frame for both
    /// current and next song; without the cache we'd re-filter+sort the
    /// playlists array at 60 Hz and SwiftUI would see a brand-new array each
    /// time, churning the card view.
    func playlistMemberships(for song: Song) -> [Playlist] {
        let id = song.id.rawValue
        if let cached = membershipsCache[id] { return cached }

        let ids = membershipIndex[id] ?? []
        let result: [Playlist]
        if ids.isEmpty {
            result = []
        } else {
            let idStrings = Set(ids.map(\.rawValue))
            result = playlists
                .filter {
                    guard let amID = $0.appleMusicPlaylistID else { return false }
                    return idStrings.contains(amID)
                }
                .sorted { $0.displayOrder < $1.displayOrder }
        }
        membershipsCache[id] = result
        return result
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
                    // Sticky-downgrade: once a playlist is known read-only
                    // (heuristic match OR a write that actually failed via
                    // the self-heal path in `loveCurrent`), keep it that
                    // way. Sync can downgrade an editable playlist but must
                    // never re-upgrade a read-only one.
                    let newEditable = wasEditable && editable
                    existing.isEditable = newEditable
                    existing.name = amPlaylist.name

                    if wasEditable && !newEditable {
                        if existing.isInSidebar { existing.isInSidebar = false }
                        let defaults = UserDefaults.standard
                        if defaults.string(forKey: lovedPlaylistDefaultsKey) == amID {
                            defaults.removeObject(forKey: lovedPlaylistDefaultsKey)
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
        membershipsCache.removeAll(keepingCapacity: true)
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
        if let existing = fetchDismissedRecord(for: songID) {
            let originalDismissedAt = existing.dismissedAt
            existing.dismissedAt = .now
            try? modelContext.save()
            actionHistory.append(.redismissed(
                song: song,
                record: existing,
                originalDismissedAt: originalDismissedAt
            ))
            sessionExclusionSet.insert(songID)
            dismissedDates[songID] = existing.dismissedAt
            sessionDismissedCount += 1
            toastMessage = "Dismissed"
            advance()
            return
        }

        let record = DismissedSong(songID: songID)
        modelContext.insert(record)
        try? modelContext.save()
        actionHistory.append(.dismissed(song: song, record: record))
        sessionExclusionSet.insert(songID)
        dismissedDates[songID] = record.dismissedAt
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
            if let dismissedRecord {
                modelContext.delete(dismissedRecord)
                dismissedDates.removeValue(forKey: song.id.rawValue)
            }

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
            addMembership(songID: song.id.rawValue, playlistAMID: amID)
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
        addMembership(songID: song.id.rawValue, playlistAMID: amID)
        toastMessage = "Added to \(playlist.name)"
        advance()

        Task { @MainActor in
            do {
                try await service.addSong(song, toPlaylistID: amID)
                try await removeFromSourceIfNeeded(song: song, destinationPlaylist: playlist)
            } catch {
                toastMessage = "Couldn't add to \(playlist.name)"
            }
        }
    }

    /// Strips the current song from every Apple Music playlist it's in.
    /// Used by the long-press menu in Dismissed mode. The `DismissedSong`
    /// row is left intact — the song stays dismissed, it just stops showing
    /// up in any playlist. Local `SortedSong` rows for those playlists are
    /// deleted too; their `sortedAt` is captured so undo can recreate them.
    func removeFromAllPlaylists() {
        guard let song = currentSong else { return }
        let memberships = playlistMemberships(for: song)
        guard !memberships.isEmpty else { return }

        let songID = song.id.rawValue

        // Snapshot existing SortedSong rows so undo can recreate them with
        // their original sortedAt instead of resetting to .now.
        let sortedDescriptor = FetchDescriptor<SortedSong>(
            predicate: #Predicate { $0.songID == songID }
        )
        let existingRecords = (try? modelContext.fetch(sortedDescriptor)) ?? []
        let sortedAtByPlaylistAMID: [String: Date] = Dictionary(
            uniqueKeysWithValues: existingRecords.compactMap { record in
                guard let amID = record.playlist?.appleMusicPlaylistID else { return nil }
                return (amID, record.sortedAt)
            }
        )

        let snapshots = memberships.map { playlist in
            PlaylistRemovalSnapshot(
                playlist: playlist,
                sortedAt: playlist.appleMusicPlaylistID.flatMap { sortedAtByPlaylistAMID[$0] }
            )
        }

        for record in existingRecords {
            modelContext.delete(record)
        }
        try? modelContext.save()

        membershipIndex.removeValue(forKey: songID)
        membershipsCache.removeValue(forKey: songID)
        actionHistory.append(.removedFromAllPlaylists(song: song, removals: snapshots))

        let count = snapshots.count
        let plural = count == 1 ? "" : "s"
        toastMessage = "Removing from \(count) playlist\(plural)…"

        Task { @MainActor in
            var failures = 0
            for snapshot in snapshots {
                guard let amIDString = snapshot.playlist.appleMusicPlaylistID else { continue }
                let amID = MusicItemID(amIDString)
                do {
                    try await service.removeSong(song, fromPlaylistID: amID)
                } catch {
                    failures += 1
                }
            }
            let succeeded = count - failures
            if failures == 0 {
                toastMessage = "Removed from \(count) playlist\(plural)"
            } else {
                toastMessage = "Removed from \(succeeded), \(failures) failed"
            }
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
            refreshLocalPlaylists()
            toastMessage = "Created \(name)"
        } catch {
            toastMessage = "Couldn't create playlist"
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
            guard let playlist = await resolveOrCreateLovedPlaylist() else {
                toastMessage = "Couldn't open Loved playlist"
                return
            }

            guard let amIDString = playlist.appleMusicPlaylistID else {
                toastMessage = "Loved playlist not synced — try again"
                return
            }
            let amID = MusicItemID(amIDString)

            // Already loved? Skip silently — chip + a toast tell the user.
            let existing = membershipIndex[song.id.rawValue] ?? []
            if existing.contains(amID) {
                toastMessage = "Already loved"
                advance()
                return
            }

            let songID = song.id.rawValue

            // Loving a dismissed track also un-dismisses it — otherwise the
            // song lives in both the Loved playlist and the Dismissed deck,
            // which is contradictory. The original dismissedAt rides along
            // so undo can restore the prior state.
            let dismissedRecord = fetchDismissedRecord(for: songID)
            let originalDismissedAt = dismissedRecord?.dismissedAt
            if let dismissedRecord {
                modelContext.delete(dismissedRecord)
                dismissedDates.removeValue(forKey: songID)
            }

            let record = SortedSong(songID: songID, playlist: playlist)
            modelContext.insert(record)
            try? modelContext.save()
            let recordID = record.id
            if let originalDismissedAt {
                actionHistory.append(.lovedFromDismissed(
                    song: song,
                    playlist: playlist,
                    record: record,
                    originalDismissedAt: originalDismissedAt
                ))
            } else {
                actionHistory.append(.loved(song: song, playlist: playlist, record: record))
            }
            sessionExclusionSet.insert(songID)
            sessionSortedCount += 1
            addMembership(songID: songID, playlistAMID: amID)
            toastMessage = originalDismissedAt == nil ? "Loved" : "Loved & restored"
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
                    songID: songID,
                    recordID: recordID,
                    playlistAMID: amID,
                    restoreDismissedAt: originalDismissedAt
                )

                if sessionCreatedLovedAMID == amIDString {
                    // We created this playlist ourselves earlier in this
                    // process — Apple Music's library is eventually consistent
                    // for new playlists, so the first add usually fails even
                    // when the playlist is healthy. Leaving defaults +
                    // editability alone lets the next up-swipe (this session
                    // or next launch) hit the same playlist instead of
                    // creating a fresh duplicate every time.
                    toastMessage = "Couldn't reach \(playlist.name) — try again"
                } else {
                    // Self-heal: name-based detection can't cover every locale
                    // (and Apple ships new system playlists over time). Mark
                    // the playlist read-only locally so the picker, sidebar,
                    // and sort-from sources hide it from now on. Sticky-
                    // downgrade in sync stops the heuristic re-upgrading it
                    // on next launch.
                    let displayName = playlist.name
                    playlist.isEditable = false
                    if playlist.isInSidebar { playlist.isInSidebar = false }
                    try? modelContext.save()
                    let defaults = UserDefaults.standard
                    if defaults.string(forKey: lovedPlaylistDefaultsKey) == amIDString {
                        defaults.removeObject(forKey: lovedPlaylistDefaultsKey)
                    }
                    refreshLocalPlaylists()

                    toastMessage = "Couldn't add to \(displayName)"
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
        songID: String,
        recordID: UUID,
        playlistAMID: MusicItemID,
        restoreDismissedAt: Date? = nil
    ) {
        actionHistory.removeAll { action in
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
            dismissedDates[songID] = restoreDismissedAt
        }

        try? modelContext.save()

        sessionExclusionSet.remove(songID)
        sessionSortedCount = max(sessionSortedCount - 1, 0)
        removeMembership(songID: songID, playlistAMID: playlistAMID.rawValue)
    }

    /// Returns the configured loved-playlist (matching `lovedPlaylistID` —
    /// the Apple Music playlist ID — in UserDefaults). Adopts an existing
    /// "Culla Loves" in Apple Music when present (cleaning up after the older
    /// bug that left duplicates), otherwise creates a fresh one. Returns nil
    /// only if creation itself fails; the caller surfaces a toast.
    @MainActor
    private func resolveOrCreateLovedPlaylist() async -> Playlist? {
        let defaults = UserDefaults.standard
        // Require `isEditable` so a stored target that's since been flagged
        // read-only (by sync or by an earlier write failure) falls through to
        // auto-create instead of repeating the failed write.
        if let stored = defaults.string(forKey: lovedPlaylistDefaultsKey),
           !stored.isEmpty,
           let match = playlists.first(where: { $0.appleMusicPlaylistID == stored }),
           match.isEditable {
            return match
        }

        // Stored ID is missing / read-only. Before creating yet another
        // duplicate, look for an existing "Culla Loves" already in Apple's
        // library — could be from a previous buggy session where the
        // create-response ID didn't match the canonical library ID, or one
        // the user made manually. Adopt the first editable match instead of
        // spawning another empty playlist every launch.
        if let refreshed = try? await service.refreshUserPlaylists() {
            let candidates = refreshed.filter {
                $0.name == defaultLovedPlaylistName && computeEditability(for: $0)
            }
            if let adopted = candidates.first {
                return upsertLocalLovedRow(amID: adopted.id.rawValue)
            }
        }

        // Genuinely missing — create one.
        do {
            let amPlaylist = try await service.createPlaylist(name: defaultLovedPlaylistName)
            // Apple Music's library is eventually consistent — give the new
            // playlist a moment to be queryable before the caller tries to
            // add a song. Without this, the first up-swipe almost always
            // hits the catch path because MusicLibraryRequest can't yet see
            // the playlist we literally just created.
            try? await Task.sleep(for: .milliseconds(600))

            // The `.id` returned by `MusicLibrary.shared.createPlaylist` does
            // not always match the library ID that subsequent
            // `MusicLibraryRequest<MusicKit.Playlist>` fetches return for the
            // same playlist. If we anchor on the create-response ID,
            // `addSong` resolves via `MusicLibraryRequest.filter(matching: \.id, ...)`,
            // gets nothing, throws `playlistNotFound`, and the next launch's
            // self-heal nukes defaults and spawns a fresh duplicate — every
            // session. Re-fetch and prefer the new playlist (matched by name,
            // with an ID not yet in our local SwiftData) so we record the
            // canonical library ID instead.
            let existingAMIDs = Set(playlists.compactMap(\.appleMusicPlaylistID))
            var canonicalAMID = amPlaylist.id.rawValue
            if let refreshed = try? await service.refreshUserPlaylists(),
               let canonical = refreshed.first(where: {
                   $0.name == defaultLovedPlaylistName
                       && !existingAMIDs.contains($0.id.rawValue)
               }) {
                canonicalAMID = canonical.id.rawValue
            }
            return upsertLocalLovedRow(amID: canonicalAMID)
        } catch {
            return nil
        }
    }

    /// Either returns the existing local `Playlist` row tagged with this AM ID
    /// (re-enabling it if it was previously disabled) or inserts a new one.
    /// Also points `lovedPlaylistID` defaults at this AM ID and arms the
    /// session-created flag so a transient first-add failure doesn't kick off
    /// the duplicate-spawning self-heal.
    @MainActor
    @discardableResult
    private func upsertLocalLovedRow(amID: String) -> Playlist {
        let row: Playlist
        if let existing = playlists.first(where: { $0.appleMusicPlaylistID == amID }) {
            existing.isEditable = true
            row = existing
        } else {
            let nextOrder = (playlists.map(\.displayOrder).max() ?? -1) + 1
            let inserted = Playlist(
                name: defaultLovedPlaylistName,
                displayOrder: nextOrder,
                appleMusicPlaylistID: amID,
                isInSidebar: false,
                isEditable: true
            )
            modelContext.insert(inserted)
            row = inserted
        }
        try? modelContext.save()
        refreshLocalPlaylists()
        UserDefaults.standard.set(amID, forKey: lovedPlaylistDefaultsKey)
        sessionCreatedLovedAMID = amID
        return row
    }

    // MARK: - Undo

    func undo() {
        guard let action = actionHistory.popLast() else { return }
        switch action {
        case .dismissed(let song, let record):
            modelContext.delete(record)
            try? modelContext.save()
            sessionExclusionSet.remove(song.id.rawValue)
            dismissedDates.removeValue(forKey: song.id.rawValue)
            sessionDismissedCount = max(sessionDismissedCount - 1, 0)
            pushBackToFront(song: song)

        case .redismissed(let song, let record, let originalDismissedAt):
            // The row was never deleted — only the timestamp moved. Put it
            // back so the resurface window math stays correct.
            record.dismissedAt = originalDismissedAt
            try? modelContext.save()
            sessionExclusionSet.remove(song.id.rawValue)
            dismissedDates[song.id.rawValue] = originalDismissedAt
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
            sessionSortedCount = max(sessionSortedCount - 1, 0)
            dismissedDates[song.id.rawValue] = originalDismissedAt
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
            sessionExclusionSet.remove(song.id.rawValue)
            sessionSortedCount = max(sessionSortedCount - 1, 0)
            dismissedDates[song.id.rawValue] = originalDismissedAt
            removeMembership(songID: song.id.rawValue, playlistAMID: playlist.appleMusicPlaylistID)
            pushBackToFront(song: song)
            remoteRemove(song: song, fromPlaylist: playlist)

        case .removedFromAllPlaylists(let song, let removals):
            // Recreate any SortedSong rows that existed, preserving sortedAt.
            for removal in removals {
                if let sortedAt = removal.sortedAt {
                    let record = SortedSong(songID: song.id.rawValue, playlist: removal.playlist)
                    record.sortedAt = sortedAt
                    modelContext.insert(record)
                }
            }
            try? modelContext.save()

            // Rebuild membership index for this song in one shot.
            let restoredAMIDs = removals.compactMap { snapshot -> MusicItemID? in
                guard let amID = snapshot.playlist.appleMusicPlaylistID else { return nil }
                return MusicItemID(amID)
            }
            if !restoredAMIDs.isEmpty {
                membershipIndex[song.id.rawValue] = restoredAMIDs
                membershipsCache.removeValue(forKey: song.id.rawValue)
            }

            // The card never advanced, so no pushBackToFront — undo restores
            // memberships in place. Apple Music re-adds happen in the
            // background; toast reports the outcome.
            let count = removals.count
            let plural = count == 1 ? "" : "s"
            toastMessage = "Restoring to \(count) playlist\(plural)…"

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
                    toastMessage = "Restored to \(count) playlist\(plural)"
                } else {
                    toastMessage = "Restored to \(count - failures), \(failures) failed"
                }
            }
        }
    }

    private func addMembership(songID: String, playlistAMID: MusicItemID) {
        var current = membershipIndex[songID] ?? []
        if !current.contains(playlistAMID) {
            current.append(playlistAMID)
            membershipIndex[songID] = current
        }
        membershipsCache.removeValue(forKey: songID)
    }

    private func removeMembership(songID: String, playlistAMID: String?) {
        guard let playlistAMID, var current = membershipIndex[songID] else { return }
        current.removeAll { $0.rawValue == playlistAMID }
        if current.isEmpty {
            membershipIndex.removeValue(forKey: songID)
        } else {
            membershipIndex[songID] = current
        }
        membershipsCache.removeValue(forKey: songID)
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

    /// Dismissals younger than this resurface in Unsorted with a red pill.
    /// Older ones stay excluded so the deck doesn't suddenly flood with
    /// months of rejected tracks. Library mode still hides every dismissal.
    private static let dismissedResurfaceAfter: TimeInterval = 30 * 24 * 60 * 60

    /// IDs of dismissals still within the resurface window — Unsorted unions
    /// these into its exclusion set so only stale dismissals come back.
    private func fetchRecentDismissedSongIDs() -> Set<String> {
        let cutoff = Date().addingTimeInterval(-Self.dismissedResurfaceAfter)
        let descriptor = FetchDescriptor<DismissedSong>(
            predicate: #Predicate { $0.dismissedAt > cutoff }
        )
        return Set((try? modelContext.fetch(descriptor))?.map(\.songID) ?? [])
    }

    /// Snapshot of every song's dismissal timestamp. Used to seed the
    /// in-memory `dismissedDates` map on load.
    private func fetchAllDismissedDates() -> [String: Date] {
        let descriptor = FetchDescriptor<DismissedSong>()
        let records = (try? modelContext.fetch(descriptor)) ?? []
        var dict: [String: Date] = [:]
        for r in records { dict[r.songID] = r.dismissedAt }
        return dict
    }

    /// Fetches the single `DismissedSong` row for this songID, if any.
    /// Used by the re-dismiss path so we can bump the timestamp instead of
    /// inserting a duplicate.
    private func fetchDismissedRecord(for songID: String) -> DismissedSong? {
        let descriptor = FetchDescriptor<DismissedSong>(
            predicate: #Predicate { $0.songID == songID }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }

    /// Returns the dismissal timestamp for this song, or nil if it isn't
    /// dismissed. Drives the "Dismissed Xmo ago" chip on the card.
    func dismissedDate(for song: Song) -> Date? {
        dismissedDates[song.id.rawValue]
    }

    private func fetchNextSessionSongs() async throws -> [Song] {
        if config.mode == .library,
           let sourcePlaylistID = config.sourcePlaylistID {
            return try await service.fetchNextPlaylistSongs(
                playlistID: MusicItemID(sourcePlaylistID),
                excluding: sessionExclusionSet,
                desired: batchSize,
                ascending: config.order.ascending
            )
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
                toastMessage = "Couldn't restore to \(sourceName)"
            }
        }
    }

    private func fetchSortedSongIDs() -> Set<String> {
        Set((try? modelContext.fetch(FetchDescriptor<SortedSong>()))?.map(\.songID) ?? [])
    }
}

// MARK: - Supporting Types

/// Captures a single playlist the song was removed from, plus enough state
/// to recreate the corresponding `SortedSong` row on undo. `sortedAt` is
/// nil when the song was only in the Apple Music playlist (added outside
/// Culla) — undo still re-adds to Apple Music but skips the local row.
struct PlaylistRemovalSnapshot {
    let playlist: Playlist
    let sortedAt: Date?
}

enum SwipeAction {
    case dismissed(song: Song, record: DismissedSong)
    /// Left-swipe on a song that *already* has a DismissedSong row (resurfaced
    /// in Unsorted). The row is reused — only its timestamp moves to now —
    /// so undo restores the original dismissedAt instead of deleting it.
    case redismissed(song: Song, record: DismissedSong, originalDismissedAt: Date)
    case sorted(song: Song, playlist: Playlist, record: SortedSong)
    /// Right-swipe in dismissed mode: un-dismisses + adds to playlist.
    case sortedFromDismissed(song: Song, playlist: Playlist, sortedRecord: SortedSong, originalDismissedAt: Date)
    /// Down-swipe: in-session only, song reappears next launch.
    case skipped(song: Song)
    /// Up-swipe: adds to the user's loved playlist (auto-created on first use).
    case loved(song: Song, playlist: Playlist, record: SortedSong)
    /// Up-swipe on a song that was dismissed: loves it AND un-dismisses it.
    /// `originalDismissedAt` lets undo restore the prior dismissed timestamp
    /// so the song goes back where it was, not to "now".
    case lovedFromDismissed(song: Song, playlist: Playlist, record: SortedSong, originalDismissedAt: Date)
    /// Long-press menu in Dismissed mode → "Remove from all playlists".
    /// Strips the song from every Apple Music playlist it was in. The
    /// `DismissedSong` row is untouched. Undo re-adds the song to each
    /// playlist and recreates any `SortedSong` rows that previously existed.
    case removedFromAllPlaylists(song: Song, removals: [PlaylistRemovalSnapshot])
}

/// Key under which the loved-playlist's Apple Music ID is persisted. Stored
/// as a string so the Settings picker can read/write it without any type
/// coupling — empty string means "auto-create Culla Loves on first up-swipe".
private let lovedPlaylistDefaultsKey = "lovedPlaylistID"
private let defaultLovedPlaylistName = "Culla Loves"
