import Foundation
import MusicKit
import SwiftData

/// The one mirror of Apple Music's playlists into the local `Playlist` rows.
///
/// HomeView's launch load and the swipe session's `loadInitial` used to carry
/// near-twin copies of this sync, and they drifted: only the session copy
/// demoted playlists that turned read-only, and only the Home copy pruned
/// playlists deleted in Music. Both callers now run this single routine, so
/// every sync applies the union:
/// - Name and editability mirror Apple's current kind/name every sync — no
///   local latch, so a playlist can never get stuck read-only.
/// - A playlist that flipped read-only is demoted: dropped from the sidebar,
///   and cleared as the up-swipe Loved target.
/// - Local rows whose Apple Music source no longer exists are pruned.
/// - Optionally (session entry only), the one-time sidebar auto-fill runs.
@MainActor
enum PlaylistSyncer {

    /// UserDefaults flag: the one-time sidebar auto-fill already ran. The old
    /// check inferred "first launch" from the data (`no playlist is in the
    /// sidebar`), which also matched a deliberately emptied sidebar — and
    /// silently repopulated it on the next session start. A persisted flag
    /// makes the fill genuinely once-ever.
    static let sidebarSeededKey = "hasSeededSidebarPlaylists"

    /// Syncs and returns the local rows (sorted by `displayOrder`). Throws when
    /// the Apple Music playlist fetch fails — local rows are left untouched in
    /// that case, so callers keep showing last-known data.
    ///
    /// `seedSidebarLimit` opts in to the first-run sidebar auto-fill (the swipe
    /// session passes its cap; Home passes nil and leaves the decision to the
    /// first session, matching prior behavior).
    @discardableResult
    static func sync(
        modelContext: ModelContext,
        seedSidebarLimit: Int? = nil
    ) async throws -> [Playlist] {
        let amPlaylists = try await MusicLibraryService.shared.refreshUserPlaylists()
        let defaults = UserDefaults.standard
        let local = fetchLocal(modelContext)
        let localByAMID = Dictionary(
            uniqueKeysWithValues: local.compactMap { playlist -> (String, Playlist)? in
                guard let amID = playlist.appleMusicPlaylistID else { return nil }
                return (amID, playlist)
            }
        )
        var nextOrder = (local.map(\.displayOrder).max() ?? -1) + 1

        for amPlaylist in amPlaylists {
            let amID = amPlaylist.id.rawValue
            let editable = computeEditability(for: amPlaylist)

            if let existing = localByAMID[amID] {
                let wasEditable = existing.isEditable
                existing.isEditable = editable
                existing.name = amPlaylist.name

                // Demotion: a playlist that turned read-only can't take writes,
                // so it leaves the right-swipe sidebar and stops being the
                // up-swipe Loved target.
                if wasEditable && !editable {
                    if existing.isInSidebar { existing.isInSidebar = false }
                    if defaults.string(forKey: LovedPlaylistResolver.defaultsKey) == amID {
                        defaults.removeObject(forKey: LovedPlaylistResolver.defaultsKey)
                    }
                }
            } else {
                modelContext.insert(Playlist(
                    name: amPlaylist.name,
                    displayOrder: nextOrder,
                    appleMusicPlaylistID: amID,
                    isEditable: editable
                ))
                nextOrder += 1
            }
        }

        // Prune local rows whose Apple Music source no longer exists — without
        // this, playlists deleted from Apple Music stick around forever in the
        // picker and sidebar. SwiftData cascades the delete to their SortedSong
        // records, which is correct: that history is meaningless once the
        // destination playlist is gone.
        //
        // Never prune the Loved target. Every up-swipe is a SortedSong on this
        // playlist, so the cascade delete would erase all loved history. And
        // `refreshUserPlaylists` legitimately omits it sometimes — Apple's
        // library is eventually consistent right after we create "Culla Loves",
        // and the smart "Favorites" playlist is filtered out of that fetch
        // entirely — so a missing-from-Apple result here is not proof it's gone.
        let liveAMIDs = Set(amPlaylists.map { $0.id.rawValue })
        let lovedAMID = defaults.string(forKey: LovedPlaylistResolver.defaultsKey)
        for playlist in local {
            guard let amID = playlist.appleMusicPlaylistID, amID != lovedAMID else { continue }
            if !liveAMIDs.contains(amID) {
                modelContext.delete(playlist)
            }
        }

        try? modelContext.save()

        var refreshed = fetchLocal(modelContext)

        if let limit = seedSidebarLimit,
           !defaults.bool(forKey: sidebarSeededKey),
           !refreshed.isEmpty {
            if refreshed.allSatisfy({ !$0.isInSidebar }) {
                for playlist in refreshed.filter(\.isEditable).prefix(limit) {
                    playlist.isInSidebar = true
                }
                try? modelContext.save()
                refreshed = fetchLocal(modelContext)
            }
            // Set even when nothing was seeded — an install that already has
            // sidebar entries is past first run, so the fill must never fire
            // for it later. Skipped only while the playlist list is empty
            // (a cold pre-sync launch shouldn't burn the one-time fill).
            defaults.set(true, forKey: sidebarSeededKey)
        }

        return refreshed
    }

    private static func fetchLocal(_ modelContext: ModelContext) -> [Playlist] {
        let descriptor = FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.displayOrder)])
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}
