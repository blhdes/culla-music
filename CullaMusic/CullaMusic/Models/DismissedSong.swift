import Foundation
import SwiftData

@Model
final class DismissedSong {
    var id: UUID
    var songID: String
    var dismissedAt: Date

    /// True when this song lives only in the Apple Music catalog, not the
    /// user's library — i.e. it was dismissed from a playlist scope while
    /// auditing tracks they haven't added yet. The Dismissed deck reads this
    /// to resolve the song from the catalog instead of the library. Defaults
    /// to `false` so every pre-existing record (all library tracks) keeps
    /// resolving exactly as before.
    var isCatalogTrack: Bool = false

    /// Set when the song is no longer in the library — the user deleted it in
    /// Apple Music, so the dismissal can't surface anywhere. Nil = active.
    /// Re-derived from live library evidence by `DismissedSongReconciler`
    /// (mirrors `SortedSong.voidedAt`): counts and the dismissed deck skip
    /// voided rows, History renders them as greyed tombstones, and re-adding
    /// the song to the library un-voids the row. Adding an optional attribute
    /// is a safe lightweight SwiftData migration.
    var voidedAt: Date?

    /// Saved display identity from the moment of dismissal — see
    /// `MovementSnapshotting`. Lets History keep showing the track (greyed)
    /// after the song leaves the library. Optional: rows from before this
    /// feature have none and fall back to "Track unavailable".
    var snapshotTitle: String?
    var snapshotArtist: String?
    @Attribute(.externalStorage) var snapshotArtworkData: Data?

    init(songID: String) {
        self.id = UUID()
        self.songID = songID
        self.dismissedAt = .now
    }
}

extension DismissedSong: MovementSnapshotting {}

extension DismissedSong {
    /// Rows that still count as dismissed — not voided. Every surface that
    /// shows a dismissed COUNT or deck CONTENT must fetch through this, or a
    /// deleted song's tombstone row would inflate the number / hold an empty
    /// slot (the phantom-count bug). Exclusion sets deliberately keep reading
    /// ALL rows: a voided ID excludes nothing while the song is gone, and if
    /// the song comes back before the next reconcile it stays hidden as
    /// dismissed rather than flip-flopping into the decks.
    static let activePredicate = #Predicate<DismissedSong> { $0.voidedAt == nil }
}

/// Single source of truth for keeping `DismissedSong.voidedAt` in step with
/// the library, mirroring `SortedSongReconciler`. A dismissed song the user
/// later deletes from Apple Music becomes a voided row: still in History as a
/// greyed record of the decision, but skipped by Home's count and the
/// dismissed deck (which used to show "count says 1, stack is empty"). Voiding
/// is self-healing — if the song is re-added, the next reconcile with it in
/// evidence un-voids the row and the dismissal applies again.
enum DismissedSongReconciler {
    /// Voids the non-catalog rows in `rows` whose song ID isn't in
    /// `resolvedIDs`, un-voids any whose song is back, and returns the song
    /// IDs left voided after the pass (empty when nothing changed hands —
    /// safe to run on every load).
    ///
    /// Callers must only pass rows they hold authoritative evidence for:
    /// `resolvedIDs` has to come from a library fetch that SUCCEEDED (a full
    /// page-through or an exact-ID filter). A failed fetch proves nothing —
    /// voiding against one would grey out real dismissals over a network
    /// blip, so never call this from an error path.
    ///
    /// Catalog rows (`isCatalogTrack`) are never voided: they live outside
    /// the library by design, so "not in the library" is their normal state.
    @discardableResult
    static func reconcile(
        rows: [DismissedSong],
        resolvedIDs: Set<String>,
        in context: ModelContext
    ) -> [String] {
        var voidedSongIDs: [String] = []
        var changed = false
        for row in rows where !row.isCatalogTrack {
            if resolvedIDs.contains(row.songID) {
                if row.voidedAt != nil {
                    row.voidedAt = nil
                    changed = true
                }
            } else {
                if row.voidedAt == nil {
                    row.voidedAt = .now
                    changed = true
                }
                voidedSongIDs.append(row.songID)
            }
        }
        if changed {
            do {
                try context.save()
            } catch {
                print("DismissedSongReconciler save failed: \(error)")
            }
        }
        return voidedSongIDs
    }
}
