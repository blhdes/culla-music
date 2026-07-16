import Foundation
import MusicKit
import SwiftData

/// Backs the History sheet: a reverse-chronological timeline of every persisted
/// "movement" — songs sorted into a playlist (loved is just a sort into the
/// Culla Loves playlist) and songs dismissed.
///
/// Unlike `UndoCoordinator` (which only tracks the *current* session's stack),
/// this reads the durable SwiftData rows (`SortedSong` / `DismissedSong`), so it
/// can surface and reverse movements from any past session. Swiping a row calls
/// `undo`, which deletes the local record and — for a sort — also removes the
/// song from its Apple Music playlist, a true reversal.
@Observable
@MainActor
final class HistoryStore {

    /// What kind of movement a row represents. Playlist details are captured as
    /// plain values (name, app-created flag) — never the live `Playlist` model —
    /// so the entry doesn't hold a SwiftData reference across the async
    /// song-resolve. `undo` refetches the row fresh by id when it needs the live
    /// relationship; `createdByApp` lets the row pick its swipe action: a real
    /// Undo for Culla-created playlists, an "Open in Music" hand-off for the
    /// user's own (which Apple won't let Culla remove from).
    enum Movement {
        case sorted(playlistName: String, loved: Bool, createdByApp: Bool)
        case dismissed
    }

    struct Entry: Identifiable {
        let id: UUID            // the SortedSong / DismissedSong row's id
        let songID: String
        let date: Date
        let movement: Movement
        let isCatalogTrack: Bool
        /// Saved display identity captured at movement time (see
        /// `MovementSnapshotting`). When the song no longer resolves, these
        /// keep the row readable as a greyed tombstone instead of collapsing
        /// to "Track unavailable". Nil on rows from before snapshots existed.
        let snapshotTitle: String?
        let snapshotArtist: String?
        /// Saved cover bytes. Filled lazily AFTER the resolve pass, and only
        /// for entries whose song is gone — copying blobs up front would drag
        /// every row's external-storage data into memory for covers that
        /// `ArtworkImage` already renders live.
        var snapshotArtworkData: Data? = nil
        var song: Song?         // filled in lazily by `resolveSongs`
        /// Set when the saved record and reality have drifted: a sort whose
        /// song left its playlist (`reconcileSortedMemberships`) or a
        /// dismissal whose song left the library (`reconcileDismissedRows`).
        /// The row stays as a dimmed, action-less phantom (a log of what
        /// happened) rather than vanishing. Recomputed every open, so
        /// re-adding the song un-greys it.
        var isStale = false
    }

    /// One day's worth of entries, used to render the sectioned list.
    struct DaySection: Identifiable {
        let id: String          // "yyyy-MM-dd"
        let title: String       // "Today" / "Yesterday" / "May 12"
        let entries: [Entry]
    }

    private(set) var entries: [Entry] = []
    /// True only during the (fast, local) SwiftData fetch.
    private(set) var isLoading = true
    /// True while the library/catalog walk that fills in song artwork + titles
    /// is in flight. Rows render with a shimmer placeholder meanwhile.
    private(set) var isResolving = false
    var toast: String?

    /// Cap so a long history doesn't kick off a full-library resolve of
    /// thousands of rows when the sheet opens. The most recent movements are
    /// what the user actually wants to review and undo.
    private let limit = 200

    private let modelContext: ModelContext
    private let service = MusicLibraryService.shared

    /// Live rows the entries were built from, kept for the post-resolve
    /// passes (dismissed reconcile + snapshot backfill). Refreshed on every
    /// `load`; undo still refetches its row by id, so holding these is safe.
    private var sortedRowsByID: [UUID: SortedSong] = [:]
    private var dismissedRowsByID: [UUID: DismissedSong] = [:]

    private var lovedPlaylistID: String {
        UserDefaults.standard.string(forKey: LovedPlaylistResolver.defaultsKey) ?? ""
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    var isEmpty: Bool { visibleEntries.isEmpty }

    /// Entries worth rendering. Drops only truly "dead phantom" rows — voided
    /// (greyed), unresolvable (song gone from the library), AND without a
    /// saved snapshot: no track identity at all, nothing to read or act on.
    /// Rows with a snapshot stay as tombstones (the saved title/artist/cover
    /// keeps them a readable record); resolved-but-voided rows stay too.
    /// Only pre-snapshot rows whose song is gone can still hit this filter.
    private var visibleEntries: [Entry] {
        entries.filter { !($0.isStale && $0.song == nil && $0.snapshotTitle == nil) }
    }

    /// Entries grouped into day sections, newest day first. Recomputed when
    /// `entries` changes (a song resolves, or an undo removes a row).
    var sections: [DaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visibleEntries) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            let dayEntries = (grouped[day] ?? []).sorted { $0.date > $1.date }
            return DaySection(
                id: Self.keyFormatter.string(from: day),
                title: Self.sectionTitle(for: day, calendar: calendar),
                entries: dayEntries
            )
        }
    }

    // MARK: - Load

    func load() async {
        isLoading = true
        let sortedRows = (try? modelContext.fetch(FetchDescriptor<SortedSong>())) ?? []
        let dismissedRows = (try? modelContext.fetch(FetchDescriptor<DismissedSong>())) ?? []
        // Kept for the post-resolve passes (dismissed reconcile + snapshot
        // backfill), which need the live rows the entries were built from.
        sortedRowsByID = Dictionary(uniqueKeysWithValues: sortedRows.map { ($0.id, $0) })
        dismissedRowsByID = Dictionary(uniqueKeysWithValues: dismissedRows.map { ($0.id, $0) })

        let lovedID = lovedPlaylistID
        var built: [Entry] = []
        built.reserveCapacity(sortedRows.count + dismissedRows.count)

        for row in sortedRows {
            // A sort with no playlist is meaningless (and SwiftData cascades the
            // delete when a playlist is removed), so skip the defensive nil.
            guard let playlist = row.playlist else { continue }
            let loved = !lovedID.isEmpty && playlist.appleMusicPlaylistID == lovedID
            built.append(Entry(
                id: row.id,
                songID: row.songID,
                date: row.sortedAt,
                movement: .sorted(
                    playlistName: playlist.name,
                    loved: loved,
                    createdByApp: playlist.createdByApp
                ),
                isCatalogTrack: false,
                snapshotTitle: row.snapshotTitle,
                snapshotArtist: row.snapshotArtist,
                song: nil
            ))
        }
        for row in dismissedRows {
            built.append(Entry(
                id: row.id,
                songID: row.songID,
                date: row.dismissedAt,
                movement: .dismissed,
                isCatalogTrack: row.isCatalogTrack,
                snapshotTitle: row.snapshotTitle,
                snapshotArtist: row.snapshotArtist,
                song: nil,
                // Already-voided rows grey out immediately — no need to wait
                // for the resolve to prove again what a past pass recorded.
                isStale: row.voidedAt != nil
            ))
        }

        built.sort { $0.date > $1.date }
        if built.count > limit { built = Array(built.prefix(limit)) }
        entries = built
        isLoading = false

        let resolvedIDs = await resolveSongs()
        await reconcileSortedMemberships()
        if let resolvedIDs {
            reconcileDismissedRows(resolvedIDs: resolvedIDs)
        }
        backfillSnapshots()
    }

    /// Mirrors `reconcileSortedMemberships` for dismissals: the resolve pass
    /// paged the library for every entry's ID, so a dismissed row whose song
    /// didn't come back was deleted from the library. The shared reconciler
    /// voids it (and un-voids any whose song returned); the entry greys to a
    /// tombstone in place. Evidence-scoped: only rows whose IDs the resolve
    /// actually checked are passed, and an all-empty resolve is refused — on
    /// a cold open the library can read back empty before syncing, and
    /// voiding everything against that would grey out real records.
    private func reconcileDismissedRows(resolvedIDs: Set<String>) {
        guard !resolvedIDs.isEmpty else { return }
        let checkedIDs = Set(entries.map(\.songID))
        let checkedRows = dismissedRowsByID.values.filter { checkedIDs.contains($0.songID) }
        guard !checkedRows.isEmpty else { return }
        DismissedSongReconciler.reconcile(
            rows: Array(checkedRows),
            resolvedIDs: resolvedIDs,
            in: modelContext
        )
        entries = entries.map { entry in
            guard case .dismissed = entry.movement,
                  let row = dismissedRowsByID[entry.id] else { return entry }
            var copy = entry
            copy.isStale = row.voidedAt != nil
            return copy
        }
    }

    /// Two jobs after the resolve settles:
    /// - Rows that predate snapshots get one captured now from their live
    ///   `Song` (with a per-open cap on artwork downloads), so the identity is
    ///   saved BEFORE the song can ever disappear.
    /// - Entries whose song is gone pull their saved cover bytes in, so the
    ///   tombstone rows render with the remembered artwork.
    private func backfillSnapshots() {
        var artworkBudget = 50
        var wroteIdentity = false
        entries = entries.map { entry in
            var copy = entry
            let row: (any MovementSnapshotting & PersistentModel)? = switch entry.movement {
            case .sorted:    sortedRowsByID[entry.id]
            case .dismissed: dismissedRowsByID[entry.id]
            }
            guard let row else { return copy }

            if let song = entry.song {
                let needsIdentity = row.snapshotTitle == nil || row.snapshotArtist == nil
                let wantsArtwork = row.snapshotArtworkData == nil && artworkBudget > 0
                if needsIdentity || wantsArtwork {
                    if wantsArtwork { artworkBudget -= 1 }
                    MovementSnapshotter.capture(
                        from: song,
                        into: row,
                        context: modelContext,
                        fetchArtwork: wantsArtwork
                    )
                    wroteIdentity = wroteIdentity || needsIdentity
                }
            } else {
                copy.snapshotArtworkData = row.snapshotArtworkData
            }
            return copy
        }
        if wroteIdentity {
            try? modelContext.save()
        }
    }

    /// Greys out sort entries whose song is no longer in the playlist — the
    /// user removed it directly in the Music app, so the saved record and
    /// reality have drifted. We deliberately DON'T delete the record: the row
    /// stays as a dimmed, action-less phantom in the log. Runs after the list
    /// is already on screen, so rows fade to phantom a beat later (the
    /// membership map is `lastModifiedDate`-cached, so it's usually instant).
    /// Conservative: a failed membership walk marks nothing, so a transient
    /// network error can never turn live rows into false phantoms.
    private func reconcileSortedMemberships() async {
        guard !entries.isEmpty else { return }
        // `fetchAllPlaylistData` can SUCCEED with an empty map on a cold first
        // open — `refreshUserPlaylists` returns `[]` before Apple Music's
        // library has synced, without throwing. Reconciling against that would
        // void every live sort (and persist it), so require a non-empty result:
        // an empty walk on a library that has sorts means "not synced yet," not
        // "every song left its playlist." The next open reconciles for real.
        guard let data = try? await service.fetchAllPlaylistData(includeCurated: false),
              !data.songIDs.isEmpty else { return }
        let membership = data.membershipIndex.reduce(into: [String: Set<String>]()) { acc, pair in
            acc[pair.key] = Set(pair.value.map(\.rawValue))
        }
        // Shared reconciler persists `voidedAt` across ALL sort records — same
        // call the swipe deck makes — so the deck stops excluding songs that
        // left their playlist. Its returned ids drive the phantom greying here.
        let voidedRowIDs = SortedSongReconciler.reconcile(membership: membership, in: modelContext)
        entries = entries.map { entry in
            guard case .sorted = entry.movement else { return entry }
            var copy = entry
            copy.isStale = voidedRowIDs.contains(entry.id)
            return copy
        }
    }

    /// Fills in each entry's `song` (artwork + title + artist). Splits IDs
    /// across the library and catalog the same way the Dismissed deck does:
    /// catalog-only tracks come from `DismissedSong.isCatalogTrack`, everything
    /// else from the library (a sorted song is in the library by definition —
    /// adding it to a playlist added it). Unresolved IDs (song later removed
    /// from the library) simply keep a nil `song` and render as tombstones.
    ///
    /// Returns the set of song IDs that resolved, or nil when the resolve
    /// failed outright — the caller uses it as reconcile evidence, and a
    /// failed walk must never masquerade as "nothing resolved".
    @discardableResult
    private func resolveSongs() async -> Set<String>? {
        guard !entries.isEmpty else { return nil }
        isResolving = true
        defer { isResolving = false }

        var seen = Set<String>()
        var orderedIDs: [String] = []
        var catalogIDs = Set<String>()
        for entry in entries {
            if entry.isCatalogTrack { catalogIDs.insert(entry.songID) }
            if seen.insert(entry.songID).inserted { orderedIDs.append(entry.songID) }
        }

        // The library resolver THROWS when the library isn't ready yet (cold
        // first open, before Apple Music has synced) — distinct from "resolved,
        // song is genuinely gone," which comes back as a nil entry. Swallowing
        // the throw with `try?` would flash every row as "Track unavailable."
        // Retry once after a short beat instead: a bounded retry can't spin into
        // an endless skeleton, and the common cold-open case fills in cleanly.
        for attempt in 0..<2 {
            do {
                let resolved = try await service.resolveSongs(
                    orderedIDs: orderedIDs,
                    catalogIDs: catalogIDs
                )
                let byID = Dictionary(
                    resolved.map { ($0.id.rawValue, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                entries = entries.map { entry in
                    var copy = entry
                    copy.song = byID[entry.songID]
                    return copy
                }
                return Set(byID.keys)
            } catch {
                // First failure: let the library settle, then retry once.
                // Second: give up — rows fall back to their tombstone state.
                guard attempt == 0 else {
                    print("HistoryStore.resolveSongs failed: \(error)")
                    return nil
                }
                try? await Task.sleep(for: .milliseconds(600))
                if Task.isCancelled { return nil }
            }
        }
        return nil
    }

    // MARK: - Undo

    /// Reverses the movement and drops the row from the list. The in-memory
    /// removal happens first so the swipe animates out instantly; the Apple
    /// Music removal (sorts only) runs after and reports failures via `toast`.
    func undo(_ entry: Entry) async {
        entries.removeAll { $0.id == entry.id }

        switch entry.movement {
        case .dismissed:
            deleteDismissedRow(id: entry.id)
            toast = String(localized: "Dismissal undone")

        case .sorted(let playlistName, let loved, _):
            let removal = deleteSortedRow(id: entry.id)
            let displayName = loved ? String(localized: "Loved") : playlistName

            // Apple only permits track removal on playlists Culla created
            // (`MusicLibrary.shared.edit` rejects every other library playlist
            // with ICPlaylistUpdateErrorDomain). The local record is already
            // gone; for non-Culla playlists, skip the doomed removal and be
            // honest — the song stays in the playlist — instead of flashing a
            // false "Couldn't remove" error. Mirrors the swipe-deck undo.
            guard let removal, removal.createdByApp else {
                toast = removal == nil
                    ? String(localized: "Removed from \(displayName)")
                    : String(localized: "Undone — still in \(displayName)")
                return
            }

            toast = String(localized: "Removed from \(displayName)")
            // Pull it from the Apple Music playlist too. Needs the resolved
            // Song; if the song is gone from the library we can only delete the
            // local record (the playlist keeps the track, but that's an orphan
            // edge case the user can't see in Culla anyway).
            if let song = entry.song {
                do {
                    try await service.removeSong(song, fromPlaylistID: MusicItemID(removal.amID))
                } catch {
                    toast = String(localized: "Couldn't remove from \(displayName)")
                }
            }
        }
    }

    private func deleteDismissedRow(id: UUID) {
        let descriptor = FetchDescriptor<DismissedSong>(predicate: #Predicate { $0.id == id })
        if let row = try? modelContext.fetch(descriptor).first {
            modelContext.delete(row)
            try? modelContext.save()
        }
    }

    /// Deletes the `SortedSong` row, returning its playlist's Apple Music id and
    /// whether Culla created that playlist (if the row has one) so the caller can
    /// issue the matching Apple Music removal — but only when it's actually
    /// permitted (see `Playlist.createdByApp`).
    private func deleteSortedRow(id: UUID) -> (amID: String, createdByApp: Bool)? {
        let descriptor = FetchDescriptor<SortedSong>(predicate: #Predicate { $0.id == id })
        guard let row = try? modelContext.fetch(descriptor).first else { return nil }
        let removal = row.playlist.flatMap { playlist in
            playlist.appleMusicPlaylistID.map { (amID: $0, createdByApp: playlist.createdByApp) }
        }
        modelContext.delete(row)
        try? modelContext.save()
        return removal
    }

    // MARK: - Day formatting

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let sameYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private static let otherYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        return f
    }()

    private static func sectionTitle(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        if calendar.isDate(day, equalTo: .now, toGranularity: .year) {
            return sameYearFormatter.string(from: day)
        }
        return otherYearFormatter.string(from: day)
    }
}
