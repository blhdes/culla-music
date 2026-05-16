import Foundation
import MusicKit
import SwiftData

/// Per-song dismissal timestamps + the SwiftData queries that read
/// `DismissedSong` rows.
///
/// Two responsibilities:
/// - An in-memory `dates` map seeded from SwiftData on load and kept in sync
///   alongside every `DismissedSong` mutation. Drives the "Dismissed Xmo ago"
///   chip on the card — the view reads this on every drag frame, so the map
///   keeps the lookup O(1) instead of round-tripping SwiftData per frame.
/// - The SwiftData fetch helpers (`record(for:)`, `recentSongIDs`) that the
///   VM uses to decide what to resurface and which existing row to bump.
///
/// The VM still owns the actual `DismissedSong` insert/delete operations —
/// they're interleaved with action history, session counters, and exclusion
/// sets, none of which are dismissed-specific. The store just stays in lockstep
/// via `set` / `remove`.
@Observable
@MainActor
final class DismissedDateStore {
    /// Per-song dismissal timestamps for every `DismissedSong` row (any age).
    private(set) var dates: [String: Date] = [:]

    /// Dismissals younger than this resurface in Unsorted with the chip.
    /// Older ones stay excluded so the deck doesn't suddenly flood with
    /// months of rejected tracks. Library mode still hides every dismissal.
    private static let resurfaceWindow: TimeInterval = 30 * 24 * 60 * 60

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Bulk lifecycle

    /// Snapshot of every song's dismissal timestamp. Used to seed `dates` on
    /// load — replaces the current map wholesale.
    func loadAll() {
        let descriptor = FetchDescriptor<DismissedSong>()
        let records = (try? modelContext.fetch(descriptor)) ?? []
        var dict: [String: Date] = [:]
        for r in records { dict[r.songID] = r.dismissedAt }
        dates = dict
    }

    func reset() {
        dates = [:]
    }

    // MARK: - Point mutations

    func set(songID: String, date: Date) {
        dates[songID] = date
    }

    func remove(songID: String) {
        dates.removeValue(forKey: songID)
    }

    // MARK: - Lookup

    /// Returns the dismissal timestamp for this song, or nil if it isn't
    /// dismissed. Drives the "Dismissed Xmo ago" chip on the card.
    func date(for song: Song) -> Date? {
        dates[song.id.rawValue]
    }

    // MARK: - SwiftData queries

    /// IDs of dismissals still within the resurface window — Unsorted unions
    /// these into its exclusion set so only stale dismissals come back.
    func recentSongIDs() -> Set<String> {
        let cutoff = Date().addingTimeInterval(-Self.resurfaceWindow)
        let descriptor = FetchDescriptor<DismissedSong>(
            predicate: #Predicate { $0.dismissedAt > cutoff }
        )
        return Set((try? modelContext.fetch(descriptor))?.map(\.songID) ?? [])
    }

    /// Fetches the single `DismissedSong` row for this songID, if any.
    /// Used by re-dismiss / forget / love-from-dismissed paths so the VM can
    /// bump the existing row's timestamp instead of inserting a duplicate.
    func record(for songID: String) -> DismissedSong? {
        let descriptor = FetchDescriptor<DismissedSong>(
            predicate: #Predicate { $0.songID == songID }
        )
        return (try? modelContext.fetch(descriptor))?.first
    }
}
