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
        var song: Song?         // filled in lazily by `resolveSongs`
        /// Set by `reconcileSortedMemberships` when a sort's song is no longer
        /// in its playlist — i.e. the user removed it directly in the Music app,
        /// so Culla's saved record and reality have drifted. The row stays as a
        /// dimmed, action-less phantom (a log of what happened) rather than
        /// vanishing. Recomputed every open, so re-adding the song un-greys it.
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

    private var lovedPlaylistID: String {
        UserDefaults.standard.string(forKey: LovedPlaylistResolver.defaultsKey) ?? ""
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    var isEmpty: Bool { visibleEntries.isEmpty }

    /// Entries worth rendering. Drops "dead phantom" rows — a sort that's both
    /// voided (greyed; its song left the playlist) AND unresolvable (the song
    /// is gone from the library): no track identity, no swipe action, nothing
    /// the user can act on. Resolved-but-voided rows stay (a readable log), and
    /// unresolved-but-active rows stay (still undoable for cleanup); only the
    /// useless intersection is hidden. Safe during load — `isStale` is set only
    /// after the resolve, so this never hides a row that's merely still loading.
    private var visibleEntries: [Entry] {
        entries.filter { !($0.isStale && $0.song == nil) }
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
                song: nil
            ))
        }

        built.sort { $0.date > $1.date }
        if built.count > limit { built = Array(built.prefix(limit)) }
        entries = built
        isLoading = false

        await resolveSongs()
        await reconcileSortedMemberships()
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
    /// from the library) simply keep a nil `song` and render as "unavailable".
    private func resolveSongs() async {
        guard !entries.isEmpty else { return }
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
                return
            } catch {
                // First failure: let the library settle, then retry once.
                // Second: give up — rows fall back to "Track unavailable."
                guard attempt == 0 else {
                    print("HistoryStore.resolveSongs failed: \(error)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(600))
                if Task.isCancelled { return }
            }
        }
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
            toast = "Dismissal undone"

        case .sorted(let playlistName, let loved, _):
            let removal = deleteSortedRow(id: entry.id)
            let displayName = loved ? "Loved" : playlistName

            // Apple only permits track removal on playlists Culla created
            // (`MusicLibrary.shared.edit` rejects every other library playlist
            // with ICPlaylistUpdateErrorDomain). The local record is already
            // gone; for non-Culla playlists, skip the doomed removal and be
            // honest — the song stays in the playlist — instead of flashing a
            // false "Couldn't remove" error. Mirrors the swipe-deck undo.
            guard let removal, removal.createdByApp else {
                toast = removal == nil
                    ? "Removed from \(displayName)"
                    : "Undone — still in \(displayName)"
                return
            }

            toast = "Removed from \(displayName)"
            // Pull it from the Apple Music playlist too. Needs the resolved
            // Song; if the song is gone from the library we can only delete the
            // local record (the playlist keeps the track, but that's an orphan
            // edge case the user can't see in Culla anyway).
            if let song = entry.song {
                do {
                    try await service.removeSong(song, fromPlaylistID: MusicItemID(removal.amID))
                } catch {
                    toast = "Couldn't remove from \(displayName)"
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
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if calendar.isDate(day, equalTo: .now, toGranularity: .year) {
            return sameYearFormatter.string(from: day)
        }
        return otherYearFormatter.string(from: day)
    }
}
