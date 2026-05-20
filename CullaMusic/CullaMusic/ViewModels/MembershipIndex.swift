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

    /// Memoized inversion of `index` into `[playlistAMID: trackCount]`. Used by
    /// the playlist sheets to show a per-row count badge without re-walking the
    /// per-song map on every render. Lazily built on first read and cleared
    /// whenever `index` mutates.
    private var countsCache: [String: Int]?

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
        countsCache = nil
        hasEverLoaded = false
    }

    /// Drops the memoized cache without touching the raw index. Call this
    /// whenever the `playlists` array changes (sync, create, sidebar toggle) —
    /// the cache resolves index entries against `playlists`, so a stale cache
    /// would return rows for the wrong sort order or hide newly-editable ones.
    func invalidateCache() {
        cache.removeAll(keepingCapacity: true)
    }

    /// Returns the number of indexed songs belonging to the given playlist, or
    /// `nil` when `amID` is nil **or** the playlist isn't in the index.
    ///
    /// "Not in the index" can mean two different things, and the function
    /// can't tell them apart — that's why it returns nil instead of 0:
    /// - An editable playlist that's truly empty (0 tracks), or
    /// - A read-only playlist that wasn't walked because the curated toggle
    ///   is off.
    ///
    /// Callers that know the playlist is editable should `?? 0` the result.
    /// Callers that don't should render nothing rather than lie with a zero.
    func trackCount(forPlaylistAMID amID: String?) -> Int? {
        guard let amID else { return nil }
        if countsCache == nil {
            var counts: [String: Int] = [:]
            for amIDs in index.values {
                for itemID in amIDs {
                    counts[itemID.rawValue, default: 0] += 1
                }
            }
            countsCache = counts
        }
        return countsCache?[amID]
    }

    /// Replaces the raw index wholesale (e.g. after a fetch from Apple Music).
    /// Invalidates the cache and triggers a debounced disk write.
    func setIndex(_ newIndex: [String: [MusicItemID]]) {
        index = newIndex
        cache.removeAll(keepingCapacity: true)
        countsCache = nil
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
        countsCache = nil
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
        countsCache = nil
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

    nonisolated private static let persistenceFilename = "membership_index.json"

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

    /// Per-playlist track count snapshot derived from the live in-memory
    /// `index`. Same shape as `diskCountsSnapshot()` but doesn't depend on
    /// the debounced disk write having flushed — useful immediately after
    /// a `rebuild()` when callers need fresh counts right away.
    func countsSnapshot() -> [String: Int] {
        var counts: [String: Int] = [:]
        for amIDs in index.values {
            for itemID in amIDs {
                counts[itemID.rawValue, default: 0] += 1
            }
        }
        return counts
    }

    /// Reads the persisted index file directly and returns a per-playlist track
    /// count snapshot. Used by surfaces that don't have a live `MembershipIndex`
    /// instance (e.g. `HomeView`'s source picker). One rebuild stale at worst —
    /// the in-memory index persists with a 250 ms debounce.
    nonisolated static func diskCountsSnapshot() -> [String: Int] {
        guard let url = persistenceURL,
              FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            let raw = try JSONDecoder().decode([String: [String]].self, from: data)
            var counts: [String: Int] = [:]
            for amIDs in raw.values {
                for amID in amIDs {
                    counts[amID, default: 0] += 1
                }
            }
            return counts
        } catch {
            print("MembershipIndex.diskCountsSnapshot failed: \(error)")
            return [:]
        }
    }

    // MARK: - Artist counts persistence

    nonisolated private static let artistCountsFilename = "artist_track_counts.json"

    nonisolated private static var artistCountsURL: URL? {
        guard let cachesDir = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return cachesDir.appendingPathComponent(artistCountsFilename)
    }

    /// Per-artist library track count snapshot read from disk. The
    /// `attemptedIDs` list records every artist we *tried* to count — even
    /// ones whose `\.artists, contains:` filter came back empty (and thus
    /// were omitted from `counts`). Callers use it to decide whether the
    /// snapshot covers the current library or a fresh fetch is needed.
    nonisolated static func diskArtistCountsSnapshot() -> ArtistCountsSnapshot {
        guard let url = artistCountsURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(ArtistCountsSnapshot.self, from: data)
        else {
            return ArtistCountsSnapshot(counts: [:], attemptedIDs: [])
        }
        return snapshot
    }

    nonisolated static func writeArtistCounts(_ snapshot: ArtistCountsSnapshot) {
        guard let url = artistCountsURL else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            print("MembershipIndex.writeArtistCounts failed: \(error)")
        }
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

    // MARK: - Disk shapes

    /// Persisted shape for the artist-counts snapshot. Carries both the counts
    /// AND the list of artist IDs we attempted — so callers can tell "we
    /// haven't seen this artist" apart from "we tried and got nothing back."
    struct ArtistCountsSnapshot: Codable {
        var counts: [String: Int]
        var attemptedIDs: [String]
    }

    /// Debounced disk write — coalesces rapid mutations so a burst of swipes
    /// produces one write, not ten. Encodes off the main actor.
    ///
    /// The snapshot is built *inside* the debounced task (after the sleep,
    /// after the cancellation check) so a burst of N mutations allocates one
    /// `mapValues` pass instead of N. Capturing `index` requires the closure
    /// to hop back to the main actor for the read — cheap, and only happens
    /// for the surviving task in each burst.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            guard let snapshot = await self?.snapshotForDisk() else { return }
            guard let url = Self.persistenceURL else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("MembershipIndex.persist failed: \(error)")
            }
        }
    }

    /// Snapshots the in-memory index into the disk shape. Main-actor isolated
    /// because it reads `index`; the persist task awaits it.
    private func snapshotForDisk() -> [String: [String]] {
        index.mapValues { $0.map(\.rawValue) }
    }
}
