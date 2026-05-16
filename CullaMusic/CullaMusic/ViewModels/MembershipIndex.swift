import Foundation
import MusicKit

/// Per-song Apple Music playlist memberships + the memoized lookup result.
///
/// Two layers of state:
/// - `index` — raw Apple Music IDs the song belongs to. Updated optimistically
///   on sort/love/remove so the chips reflect the action immediately, without
///   waiting for a round-trip refresh.
/// - `cache` — memoized resolution of `index` into the local `Playlist` rows
///   the view actually renders. The view body calls `memberships(for:)` on
///   every drag frame for both current and next song; without this cache we'd
///   re-filter+sort the playlists array at 60 Hz AND hand SwiftUI a fresh
///   array reference each time, churning the card view.
///
/// The local-Playlist resolution depends on the VM's `playlists` array, which
/// can change independently (sync, create, sidebar toggle). That's why the
/// cache must be invalidated whenever playlists change — call
/// `invalidateCache()` from the VM's playlist-mutation paths.
@Observable
@MainActor
final class MembershipIndex {
    /// Raw membership state — Apple Music playlist IDs the song belongs to.
    /// Mutated by `add`, `remove`, `setIndex`, and `reset`.
    private(set) var index: [String: [MusicItemID]] = [:]

    /// Memoized resolution of `index` into local `Playlist` rows.
    private var cache: [String: [Playlist]] = [:]

    private let service: MusicLibraryService

    /// Lookup closure that returns the current `playlists` array from the VM.
    /// Default is empty so the index can be constructed before `self` is
    /// available to capture; the VM calls `setPlaylistsProvider` immediately
    /// after init to wire in the real lookup.
    private var playlistsProvider: @MainActor () -> [Playlist] = { [] }

    init(service: MusicLibraryService) {
        self.service = service
    }

    func setPlaylistsProvider(_ provider: @escaping @MainActor () -> [Playlist]) {
        playlistsProvider = provider
    }

    // MARK: - Bulk lifecycle

    /// Clears both the raw index and the memoized cache. Used by `reload()`.
    func reset() {
        index = [:]
        cache.removeAll(keepingCapacity: true)
    }

    /// Drops the memoized cache without touching the raw index. Call this
    /// whenever the `playlists` array changes (sync, create, sidebar toggle) —
    /// the cache resolves index entries against `playlists`, so a stale cache
    /// would return rows for the wrong sort order or hide newly-editable ones.
    func invalidateCache() {
        cache.removeAll(keepingCapacity: true)
    }

    /// Replaces the raw index wholesale (e.g. after a fetch from Apple Music).
    /// Invalidates the cache as a side effect.
    func setIndex(_ newIndex: [String: [MusicItemID]]) {
        index = newIndex
        cache.removeAll(keepingCapacity: true)
    }

    // MARK: - Point mutations

    func add(songID: String, playlistAMID: MusicItemID) {
        var current = index[songID] ?? []
        if !current.contains(playlistAMID) {
            current.append(playlistAMID)
            index[songID] = current
        }
        cache.removeValue(forKey: songID)
    }

    func remove(songID: String, playlistAMID: String?) {
        guard let playlistAMID, var current = index[songID] else { return }
        current.removeAll { $0.rawValue == playlistAMID }
        if current.isEmpty {
            index.removeValue(forKey: songID)
        } else {
            index[songID] = current
        }
        cache.removeValue(forKey: songID)
    }

    // MARK: - Lookup

    /// Returns the local `Playlist` rows (sorted by displayOrder) that the
    /// given song currently belongs to. Returns an empty array when the song
    /// isn't in any tracked playlist.
    func memberships(for song: Song) -> [Playlist] {
        let id = song.id.rawValue
        if let cached = cache[id] { return cached }

        let ids = index[id] ?? []
        let result: [Playlist]
        if ids.isEmpty {
            result = []
        } else {
            let idStrings = Set(ids.map(\.rawValue))
            result = playlistsProvider()
                .filter {
                    guard let amID = $0.appleMusicPlaylistID else { return false }
                    return idStrings.contains(amID)
                }
                .sorted { $0.displayOrder < $1.displayOrder }
        }
        cache[id] = result
        return result
    }

    // MARK: - Refresh

    /// Builds the per-song playlist membership index from Apple Music.
    /// Reads the `membershipIncludeCurated` toggle to decide whether to
    /// include editorial / replay / personalMix playlists.
    func rebuild() async {
        let includeCurated = UserDefaults.standard.bool(forKey: "membershipIncludeCurated")
        do {
            let newIndex = try await service.fetchPlaylistMembershipIndex(
                includeCurated: includeCurated
            )
            setIndex(newIndex)
        } catch {
            print("MembershipIndex.rebuild failed: \(error)")
        }
    }
}
