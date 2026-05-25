import Foundation

/// Disk-backed cache for artist bios, keyed by lowercased artist name.
///
/// Stores the *result of a completed fetch*: `Entry.bio` is itself optional, so
/// "we looked and there's no usable bio" is cached too (negative caching). That
/// matters because the long tail of library artists with no Wikipedia page is
/// exactly where we'd otherwise re-hit the network on every hub open. Network
/// *errors* are never cached — the service only upserts after a fetch completes
/// — so a transient failure still retries on the next open.
///
/// Modeled as an `actor` like `PlaylistTracksCache`, with the same debounced
/// disk write. Keyed by name for now; the MusicBrainz MBID becomes the key once
/// the disambiguation slice lands (bump `filename` then to drop stale name-keyed
/// negatives in one shot).
actor ArtistBioCache {
    struct Entry: Codable, Sendable {
        /// nil = fetch completed but found no usable bio (negative cache).
        let bio: ArtistBioService.ArtistBio?
        let fetchedAt: Date
    }

    private(set) var entries: [String: Entry] = [:]
    private var persistTask: Task<Void, Never>?

    /// Bio data barely changes; a week between refetches is plenty.
    private static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    init() {
        entries = Self.loadPersisted()
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Returns the cached fetch result only while fresh. The *outer* optional is
    /// "cache hit?"; the inner `Entry.bio` is "did that fetch find a bio?".
    func entry(forName name: String) -> Entry? {
        guard let entry = entries[Self.key(name)] else { return nil }
        guard Date().timeIntervalSince(entry.fetchedAt) < Self.staleAfter else { return nil }
        return entry
    }

    func upsert(name: String, bio: ArtistBioService.ArtistBio?) {
        entries[Self.key(name)] = Entry(bio: bio, fetchedAt: Date())
        schedulePersist()
    }

    // MARK: - Persistence

    private static let filename = "artist_bio_cache.json"

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
            print("ArtistBioCache.loadPersisted failed: \(error)")
            return [:]
        }
    }

    /// Debounced write — coalesces a burst of upserts (one per artist as the
    /// user drills A → B → C) into a single file write.
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
                print("ArtistBioCache.persist failed: \(error)")
            }
        }
    }
}
