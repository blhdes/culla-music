import Foundation
import MusicKit

/// Single source of truth for the swipe-deck undo stack.
///
/// Owns the `actionHistory` array and the `SwipeAction` type it stores.
/// Exposes a small API (`record`, `popLast`, `remove(where:)`,
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
}
