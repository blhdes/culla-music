import Foundation
import MusicKit

/// Single source of truth for the swipe-deck undo stack.
///
/// Owns the `actionHistory` array and the `SwipeAction` / `PlaylistRemovalSnapshot`
/// types it stores. Exposes a small API (`record`, `popLast`, `remove(where:)`,
/// `clear`) so callers can't mutate the history directly — the only way an
/// action enters or leaves the stack is through this type.
///
/// The actual `undo()` switch still lives on `MusicSwipeViewModel` because each
/// case touches view-model state (SwiftData mutations, queue front insertion,
/// session counters, Apple Music side effects). The coordinator handles the
/// data structure; the VM handles the orchestration.
@Observable
@MainActor
final class UndoCoordinator {
    private(set) var actionHistory: [SwipeAction] = []

    var canUndo: Bool { !actionHistory.isEmpty }
    var count: Int { actionHistory.count }

    func record(_ action: SwipeAction) {
        actionHistory.append(action)
    }

    func popLast() -> SwipeAction? {
        actionHistory.popLast()
    }

    /// Used by `rollbackLoved` when an optimistic Loved write fails — the
    /// soon-to-be-deleted SortedSong row would otherwise outlive its action
    /// reference in history.
    func remove(where predicate: (SwipeAction) -> Bool) {
        actionHistory.removeAll(where: predicate)
    }

    func clear() {
        actionHistory.removeAll()
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
    /// Long-press cleanup sheet in Dismissed mode → "Remove from playlists".
    /// Strips the song from a user-chosen subset of its Apple Music playlists.
    /// The `DismissedSong` row is untouched. Undo re-adds the song to each
    /// playlist and recreates any `SortedSong` rows that previously existed.
    case removedFromPlaylists(song: Song, removals: [PlaylistRemovalSnapshot])
    /// Long-press menu in Dismissed mode → "Forget dismissal". Deletes the
    /// `DismissedSong` row outright. Any `SortedSong` rows are untouched —
    /// if the song was in playlists it stays there; otherwise it resurfaces
    /// in Unsorted. Undo recreates the row with its original `dismissedAt`.
    case forgotDismissal(song: Song, dismissedAt: Date)
}
