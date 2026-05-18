import Foundation

/// Per-playlist track IDs cache, keyed by Apple Music playlist ID. Lets the
/// membership-index rebuild skip the expensive `playlist.with([.tracks])`
/// round-trip when the playlist's `lastModifiedDate` matches what we last
/// fetched.
///
/// Apple is the source of truth: when a user edits a playlist (via the swipe
/// gestures or on another device), Apple stamps a new `lastModifiedDate`. We
/// compare on read; mismatch → refetch and overwrite. That makes stale
/// cache entries self-healing on the next rebuild, no manual invalidation
/// needed.
///
/// Modeled as an `actor` so the parallel `withThrowingTaskGroup` in
/// `fetchAllPlaylistData` can read/write concurrently without main-actor
/// serialization.
actor PlaylistTracksCache {
    struct Entry: Codable, Sendable {
        let modifiedAt: Date?
        let trackIDs: [String]
    }

    private(set) var entries: [String: Entry] = [:]
    private var persistTask: Task<Void, Never>?

    init() {
        entries = Self.loadPersisted()
    }

    /// Returns cached track IDs only when both sides have a non-nil
    /// `modifiedAt` and they match exactly. nil-modifiedAt playlists
    /// (curated / algorithmic content) always miss so we re-fetch — we
    /// can't trust them not to have changed under us.
    func tracks(forPlaylist amID: String, modifiedAt: Date?) -> [String]? {
        guard let entry = entries[amID],
              let cachedMod = entry.modifiedAt,
              let mod = modifiedAt
        else { return nil }
        return cachedMod == mod ? entry.trackIDs : nil
    }

    func upsert(playlistAMID: String, modifiedAt: Date?, trackIDs: [String]) {
        entries[playlistAMID] = Entry(modifiedAt: modifiedAt, trackIDs: trackIDs)
        schedulePersist()
    }

    /// Drops entries for playlists no longer in the user's library. Called
    /// from `fetchAllPlaylistData` against the full set of known playlist
    /// IDs (regardless of curated scope) so toggling the curated filter
    /// doesn't wipe entries we still need.
    func prune(keepingIDs valid: Set<String>) {
        let before = entries.count
        entries = entries.filter { valid.contains($0.key) }
        if entries.count != before { schedulePersist() }
    }

    // MARK: - Persistence

    private static let filename = "playlist_tracks_cache.json"

    nonisolated private static var fileURL: URL? {
        guard let cachesDir = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return cachesDir.appendingPathComponent(filename)
    }

    nonisolated private static func loadPersisted() -> [String: Entry] {
        guard let url = fileURL,
              FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: Entry].self, from: data)
        } catch {
            print("PlaylistTracksCache.loadPersisted failed: \(error)")
            return [:]
        }
    }

    /// Debounced write — coalesces a burst of upserts (one per playlist
    /// during a parallel rebuild) into a single file write.
    private func schedulePersist() {
        persistTask?.cancel()
        let snapshot = entries
        persistTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            guard let url = Self.fileURL else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("PlaylistTracksCache.persist failed: \(error)")
            }
        }
    }
}
