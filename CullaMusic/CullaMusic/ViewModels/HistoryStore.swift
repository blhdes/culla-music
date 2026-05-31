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

    /// What kind of movement a row represents. The playlist name is captured as
    /// a plain string (not the `Playlist` model) so the entry doesn't hold a
    /// SwiftData reference across the async song-resolve; `undo` refetches the
    /// row fresh by id when it needs the live relationship.
    enum Movement {
        case sorted(playlistName: String, loved: Bool)
        case dismissed
    }

    struct Entry: Identifiable {
        let id: UUID            // the SortedSong / DismissedSong row's id
        let songID: String
        let date: Date
        let movement: Movement
        let isCatalogTrack: Bool
        var song: Song?         // filled in lazily by `resolveSongs`
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

    var isEmpty: Bool { entries.isEmpty }

    /// Entries grouped into day sections, newest day first. Recomputed when
    /// `entries` changes (a song resolves, or an undo removes a row).
    var sections: [DaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
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
                movement: .sorted(playlistName: playlist.name, loved: loved),
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

        let resolved = (try? await service.resolveSongs(
            orderedIDs: orderedIDs,
            catalogIDs: catalogIDs
        )) ?? []
        let byID = Dictionary(resolved.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })

        entries = entries.map { entry in
            var copy = entry
            copy.song = byID[entry.songID]
            return copy
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

        case .sorted(let playlistName, let loved):
            let playlistAMID = deleteSortedRow(id: entry.id)
            toast = loved ? "Removed from Loved" : "Removed from \(playlistName)"
            // Pull it from the Apple Music playlist too. Needs the resolved
            // Song; if the song is gone from the library we can only delete the
            // local record (the playlist keeps the track, but that's an orphan
            // edge case the user can't see in Culla anyway).
            if let playlistAMID, let song = entry.song {
                do {
                    try await service.removeSong(song, fromPlaylistID: MusicItemID(playlistAMID))
                } catch {
                    toast = "Couldn't remove from \(playlistName)"
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

    /// Deletes the `SortedSong` row, returning its playlist's Apple Music id (if
    /// any) so the caller can issue the matching Apple Music removal.
    private func deleteSortedRow(id: UUID) -> String? {
        let descriptor = FetchDescriptor<SortedSong>(predicate: #Predicate { $0.id == id })
        guard let row = try? modelContext.fetch(descriptor).first else { return nil }
        let playlistAMID = row.playlist?.appleMusicPlaylistID
        modelContext.delete(row)
        try? modelContext.save()
        return playlistAMID
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
