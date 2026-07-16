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

    init(songID: String) {
        self.id = UUID()
        self.songID = songID
        self.dismissedAt = .now
    }
}

/// Single source of truth for deleting `DismissedSong` rows whose song was
/// later removed from the Apple Music library. Those orphans can't surface on
/// any screen, yet they inflate the Dismissed count on Home and hold deck
/// slots that render as nothing (the "count says 1, stack is empty" bug). The
/// swipe deck, Home's hero stack, Home's count walk, and the carousel feed all
/// prune through here so they can't drift on what counts as "orphaned."
enum DismissedSongReconciler {
    /// Deletes the non-catalog rows in `rows` whose song ID isn't in
    /// `resolvedIDs`, and returns the pruned song IDs (empty when nothing was
    /// orphaned — safe to run on every load).
    ///
    /// Callers must only pass rows they hold authoritative evidence for:
    /// `resolvedIDs` has to come from a library fetch that SUCCEEDED (a full
    /// page-through or an exact-ID filter). A failed fetch proves nothing —
    /// pruning against one would delete real dismissals over a network blip,
    /// so never call this from an error path.
    ///
    /// Catalog rows (`isCatalogTrack`) are never pruned: they live outside the
    /// library by design, so "not in the library" is their normal state.
    @discardableResult
    static func pruneOrphans(
        rows: [DismissedSong],
        resolvedIDs: Set<String>,
        in context: ModelContext
    ) -> [String] {
        let orphans = rows.filter { !$0.isCatalogTrack && !resolvedIDs.contains($0.songID) }
        guard !orphans.isEmpty else { return [] }
        for row in orphans {
            context.delete(row)
        }
        do {
            try context.save()
        } catch {
            print("DismissedSongReconciler prune save failed: \(error)")
        }
        return orphans.map(\.songID)
    }
}
