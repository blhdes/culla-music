import SwiftUI
import MusicKit

/// Shared loader for the library's artists plus their per-artist track counts.
/// Both the Sort-From scope picker (`SourceScopePickerSheet`) and the Playlists
/// manager's artist filter (`ManagePlaylistsSheet`) browse the same artist list
/// with the same disk-cached counts, so the load / hydrate / refresh logic lives
/// here once instead of being copied into each sheet.
///
/// Hand this to a view as `@State private var artistStore = ArtistLibraryStore()`
/// and call `await artistStore.prime()` from a `.task`. The store is
/// `@Observable`, so the view re-renders when `artists` / `trackCounts` land.
///
/// **Ordering matters.** `prime()` runs disk-hydrate → list-load → stale-refresh
/// in that exact order: the disk counts MUST be in place before the artist list
/// lands, otherwise the first sort pass treats every count as 0 and the list
/// visibly snaps into its real order a frame later.
@MainActor
@Observable
final class ArtistLibraryStore {
    /// The library's artists, unordered — callers sort by their own prefs.
    private(set) var artists: [Artist] = []
    /// Per-artist library track count, keyed by Apple Music artist ID. A missing
    /// key means we either haven't counted yet or the count came back nil
    /// (uploaded-only tracks, fuzzy metadata); see `attemptedArtistIDs`.
    private(set) var trackCounts: [String: Int] = [:]
    private(set) var isLoadingArtists = false
    private(set) var isLoadingCounts = false

    /// Artist IDs we've attempted to count (success OR nil result), loaded from
    /// disk or computed this session. Drives the "needs refresh" check so an
    /// artist whose count is legitimately nil doesn't force a re-walk every open.
    private(set) var attemptedArtistIDs: Set<String> = []

    /// True on the first-ever open while the count walk is still in flight. Lets
    /// a list hold its rows back so the user doesn't see a count-sorted list snap
    /// into its final order once the numbers arrive. Once the walk finishes
    /// (success or failure) `attemptedArtistIDs` is populated and the gate drops.
    var isAwaitingFirstCounts: Bool {
        attemptedArtistIDs.isEmpty && isLoadingCounts
    }

    /// Runs the full load sequence in the order that keeps the first sort stable.
    /// Cheap to call from every `.task` — each step no-ops once its data is in.
    func prime() async {
        await hydrateCountsFromDisk()
        await loadArtistsIfNeeded()
        await refreshCountsIfStale()
    }

    func loadArtistsIfNeeded() async {
        guard artists.isEmpty, !isLoadingArtists else { return }
        isLoadingArtists = true
        defer { isLoadingArtists = false }
        do {
            artists = try await MusicLibraryService.shared.refreshLibraryArtists()
        } catch {
            print("ArtistLibraryStore.loadArtists failed: \(error)")
        }
    }

    /// Loads any prior count snapshot from disk before the artist list lands, so
    /// the first sort pass already has real numbers. Split from the network
    /// refresh so `prime()` can run it first — the order is what keeps the list
    /// from re-sorting visibly.
    func hydrateCountsFromDisk() async {
        guard trackCounts.isEmpty && attemptedArtistIDs.isEmpty else { return }
        let disk = await Task.detached(priority: .userInitiated) {
            MembershipIndex.diskArtistCountsSnapshot()
        }.value
        trackCounts = disk.counts
        attemptedArtistIDs = Set(disk.attemptedIDs)
    }

    /// Refetch only when the disk snapshot doesn't cover every current library
    /// artist. "Covered" = we tried to count them, even if the attempt came back
    /// nil. Comparing against `attemptedArtistIDs` (not `trackCounts`) is what
    /// keeps nil-result artists from defeating the cache and re-walking the
    /// library on every open. On success, persists counts AND attempted IDs.
    func refreshCountsIfStale() async {
        let currentIDs = Set(artists.map { $0.id.rawValue })
        let needsRefresh = !currentIDs.isSubset(of: attemptedArtistIDs)
        guard needsRefresh, !isLoadingCounts else { return }
        isLoadingCounts = true
        defer { isLoadingCounts = false }
        do {
            // Pass our already-loaded artist list so the service skips a second
            // full library walk.
            let fresh = try await MusicLibraryService.shared.fetchAllArtistTrackCounts(
                artists: artists
            )
            trackCounts = fresh.counts
            attemptedArtistIDs = Set(fresh.attemptedIDs)
            MembershipIndex.writeArtistCounts(fresh)
        } catch {
            print("ArtistLibraryStore.refreshCounts failed: \(error)")
        }
    }
}
