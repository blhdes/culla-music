import Foundation
import SwiftData

@Model
final class SortedSong {
    var id: UUID
    var songID: String
    var sortedAt: Date
    var playlist: Playlist?

    /// Set when the song is no longer in `playlist` — the user removed it
    /// directly in Apple Music, so this sort no longer reflects reality. Nil =
    /// active sort. Re-derived from live membership by `SortedSongReconciler`:
    /// the swipe decks skip voided records (so the song becomes re-sortable),
    /// and History renders them as dimmed phantoms. Adding an optional attribute
    /// is a safe lightweight SwiftData migration.
    var voidedAt: Date?

    /// Saved display identity from the moment of sorting — see
    /// `MovementSnapshotting`. Lets History keep showing the track (greyed)
    /// after the song leaves the library. Optional: rows from before this
    /// feature have none and fall back to "Track unavailable".
    var snapshotTitle: String?
    var snapshotArtist: String?
    @Attribute(.externalStorage) var snapshotArtworkData: Data?

    init(songID: String, playlist: Playlist) {
        self.id = UUID()
        self.songID = songID
        self.sortedAt = .now
        self.playlist = playlist
    }
}

extension SortedSong: MovementSnapshotting {}

/// Single source of truth for keeping `SortedSong.voidedAt` in step with what's
/// actually in each playlist. Both the swipe deck (at session start) and the
/// History sheet (on open) call this with a freshly-fetched membership map, so
/// the deck's exclusion and History's phantom rows can never disagree.
enum SortedSongReconciler {
    /// Voids sort records whose song has left its playlist and un-voids any
    /// whose song is back (self-healing both ways). `membership` maps a song ID
    /// to the set of playlist Apple-Music IDs it currently belongs to. Returns
    /// the row ids that are voided after the pass, so a caller can drive UI off
    /// it without re-deriving. Reconciling against a stale/empty map would
    /// falsely void live sorts, so an empty membership is refused here (see the
    /// guard) — callers still shouldn't pass a *failed* fetch, but a
    /// successful-but-empty one (cold open, library not synced) is handled.
    @discardableResult
    static func reconcile(
        membership: [String: Set<String>],
        in context: ModelContext
    ) -> Set<UUID> {
        // An empty map isn't a trustworthy read. On a cold open the membership
        // fetch can SUCCEED-but-empty before the library has synced (see
        // `fetchAllPlaylistData` -> `refreshUserPlaylists` returning `[]`
        // without throwing), and voiding every live sort against that corrupts
        // both the deck's exclusion set and History. Never void on empty — the
        // guard lives in the callee so no caller (current or future) can skip
        // it. A genuinely-empty library is an accepted false-negative: rare,
        // and the next non-empty reconcile self-heals it.
        guard !membership.isEmpty else { return [] }

        let rows = (try? context.fetch(FetchDescriptor<SortedSong>())) ?? []
        var voidedRowIDs = Set<UUID>()
        var changed = false
        for row in rows {
            guard let amID = row.playlist?.appleMusicPlaylistID else { continue }
            if membership[row.songID]?.contains(amID) == true {
                if row.voidedAt != nil { row.voidedAt = nil; changed = true }
            } else {
                voidedRowIDs.insert(row.id)
                if row.voidedAt == nil { row.voidedAt = .now; changed = true }
            }
        }
        if changed { try? context.save() }
        return voidedRowIDs
    }
}
