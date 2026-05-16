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
///
/// The raw `index` is also persisted to a JSON file in the caches directory so
/// chips can render immediately on cold launch with last-known data. The fresh
/// `rebuild()` runs in the background and silently overwrites the index when
/// it lands. `isRebuilding` / `hasEverLoaded` drive the loading-placeholder
/// chip in the view layer.
@Observable
@MainActor
final class MembershipIndex {
    /// Raw membership state — Apple Music playlist IDs the song belongs to.
    /// Mutated by `add`, `remove`, `setIndex`, and `reset`.
    private(set) var index: [String: [MusicItemID]] = [:]

    /// True while a `rebuild()` task is in flight. Combined with `hasEverLoaded`
    /// to decide whether to show the loading-placeholder pill: only when we
    /// have NO data to render yet AND a fetch is running.
    private(set) var isRebuilding: Bool = false

    /// True once the index has been populated at least once — either from disk
    /// (cold-launch fast path) or from a successful `rebuild()`. Resets to
    /// false on `reset()` so a manual reload re-shows the placeholder.
    private(set) var hasEverLoaded: Bool = false

    /// View-layer signal: render the loading-placeholder chip only when we
    /// have nothing to show yet AND a fetch is in flight. Once we've loaded
    /// from disk or finished a rebuild, we trust the data — subsequent
    /// rebuilds (e.g. toggle flips) refresh silently without flicker.
    var showsLoadingPlaceholder: Bool { isRebuilding && !hasEverLoaded }

    /// Memoized resolution of `index` into local `Playlist` rows.
    private var cache: [String: [Playlist]] = [:]

    private let service: MusicLibraryService

    /// Lookup closure that returns the current `playlists` array from the VM.
    /// Default is empty so the index can be constructed before `self` is
    /// available to capture; the VM calls `setPlaylistsProvider` immediately
    /// after init to wire in the real lookup.
    private var playlistsProvider: @MainActor () -> [Playlist] = { [] }

    /// Coalesces rapid mutations (e.g. a burst of swipes) into a single disk
    /// write — every change cancels the prior in-flight task and starts a
    /// fresh debounced one.
    private var persistTask: Task<Void, Never>?

    init(service: MusicLibraryService) {
        self.service = service
        loadPersisted()
    }

    func setPlaylistsProvider(_ provider: @escaping @MainActor () -> [Playlist]) {
        playlistsProvider = provider
    }

    // MARK: - Bulk lifecycle

    /// Clears both the raw index and the memoized cache. Used by `reload()`.
    /// Leaves the on-disk cache file alone — the next `rebuild()` will
    /// overwrite it with fresh data, and keeping the file is a safety net if
    /// the rebuild fails.
    func reset() {
        index = [:]
        cache.removeAll(keepingCapacity: true)
        hasEverLoaded = false
    }

    /// Drops the memoized cache without touching the raw index. Call this
    /// whenever the `playlists` array changes (sync, create, sidebar toggle) —
    /// the cache resolves index entries against `playlists`, so a stale cache
    /// would return rows for the wrong sort order or hide newly-editable ones.
    func invalidateCache() {
        cache.removeAll(keepingCapacity: true)
    }

    /// Replaces the raw index wholesale (e.g. after a fetch from Apple Music).
    /// Invalidates the cache and triggers a debounced disk write.
    func setIndex(_ newIndex: [String: [MusicItemID]]) {
        index = newIndex
        cache.removeAll(keepingCapacity: true)
        hasEverLoaded = true
        schedulePersist()
    }

    // MARK: - Point mutations

    func add(songID: String, playlistAMID: MusicItemID) {
        var current = index[songID] ?? []
        if !current.contains(playlistAMID) {
            current.append(playlistAMID)
            index[songID] = current
        }
        cache.removeValue(forKey: songID)
        hasEverLoaded = true
        schedulePersist()
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
        schedulePersist()
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
        isRebuilding = true
        defer { isRebuilding = false }

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

    // MARK: - Persistence

    private static let persistenceFilename = "membership_index.json"

    // `nonisolated` so the detached persist task can resolve the URL without
    // hopping back to the main actor. The body only touches FileManager, which
    // is documented as thread-safe.
    nonisolated private static var persistenceURL: URL? {
        guard let cachesDir = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return cachesDir.appendingPathComponent(persistenceFilename)
    }

    private func loadPersisted() {
        guard let url = Self.persistenceURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let raw = try JSONDecoder().decode([String: [String]].self, from: data)
            index = raw.mapValues { $0.map { MusicItemID($0) } }
            cache.removeAll(keepingCapacity: true)
            hasEverLoaded = true
        } catch {
            print("MembershipIndex.loadPersisted failed: \(error)")
        }
    }

    /// Debounced disk write — coalesces rapid mutations so a burst of swipes
    /// produces one write, not ten. Encodes off the main actor.
    private func schedulePersist() {
        persistTask?.cancel()
        let snapshot: [String: [String]] = index.mapValues { $0.map(\.rawValue) }
        persistTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            guard let url = Self.persistenceURL else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("MembershipIndex.persist failed: \(error)")
            }
        }
    }
}
