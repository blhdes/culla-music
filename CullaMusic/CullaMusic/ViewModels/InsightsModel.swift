import Foundation
import MusicKit

/// Backs the Insights screen. The simple counts are computed straight from
/// the local SwiftData rows the view already holds via `@Query`; this model
/// owns the two pieces that aren't: streak math and the async taste resolve
/// (top artists, genre mix, era histogram, total music time), all fed by one
/// library walk over the most recent sorts.
@Observable
@MainActor
final class InsightsModel {

    struct ArtistCount: Identifiable {
        let name: String
        let count: Int
        /// Any resolved song by this artist — the tap-through seed for
        /// `ArtistDetailSheet`, which resolves the artist page itself.
        var seedSong: Song?
        /// The artist-page portrait, filled by `loadTasteProfile` when the name
        /// resolves to a catalog artist; nil → the view shows an initial circle.
        var artwork: Artwork?
        var id: String { name }
    }

    struct GenreShare: Identifiable {
        let name: String
        let count: Int
        var id: String { name }
    }

    struct DecadeCount: Identifiable {
        /// Decade start year — 1990 stands for the '90s.
        let decade: Int
        let count: Int
        var id: Int { decade }
    }

    private(set) var currentStreak = 0
    private(set) var longestStreak = 0

    /// The user's most-sorted artists, filled in by `loadTasteProfile`.
    private(set) var topArtists: [ArtistCount] = []
    /// Top genres across all sorts, most common first. Apple tags every song
    /// with the umbrella genre "Music", which is filtered out.
    private(set) var genres: [GenreShare] = []
    /// Sorts per release decade, oldest decade first and zero-filled in
    /// between, so the era chart shows gaps as gaps.
    private(set) var decades: [DecadeCount] = []
    /// Total playing time of the distinct sorted songs.
    private(set) var musicSeconds: TimeInterval = 0
    /// How many sort events actually resolved — the denominator for genre
    /// shares (a share is "x% of your sorts carried this genre").
    private(set) var resolvedEventCount = 0
    /// True while the library resolve that powers Top Artists is in flight —
    /// the card shows skeleton bones meanwhile. Finished-but-empty needs no
    /// flag of its own: the view hides the card when this is false and
    /// `topArtists` stayed empty.
    private(set) var isResolvingArtists = false

    private let service = MusicLibraryService.shared

    // MARK: - Streaks

    /// Calculates longest and current sorting streaks from sort dates.
    /// Groups by calendar day and finds consecutive-day runs — same logic as
    /// the photo app's insights.
    func calculateStreaks(from sortedDates: [Date]) {
        let calendar = Calendar.current
        let uniqueDays = Set(sortedDates.map { calendar.startOfDay(for: $0) })
        let sorted = uniqueDays.sorted()

        guard !sorted.isEmpty else {
            longestStreak = 0
            currentStreak = 0
            return
        }

        // Longest streak
        var maxRun = 1
        var run = 1
        for i in 1..<sorted.count {
            let gap = calendar.dateComponents([.day], from: sorted[i - 1], to: sorted[i]).day ?? 0
            if gap == 1 {
                run += 1
                maxRun = max(maxRun, run)
            } else {
                run = 1
            }
        }
        longestStreak = maxRun

        // Current streak — counts backward from today; a streak survives until
        // a full calendar day passes with no sorting.
        let today = calendar.startOfDay(for: .now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        guard let lastDay = sorted.last, lastDay == today || lastDay == yesterday else {
            currentStreak = 0
            return
        }

        var streak = 1
        for i in stride(from: sorted.count - 2, through: 0, by: -1) {
            let gap = calendar.dateComponents([.day], from: sorted[i], to: sorted[i + 1]).day ?? 0
            if gap == 1 {
                streak += 1
            } else {
                break
            }
        }
        currentStreak = streak
    }

    // MARK: - Taste profile

    /// Resolves every sorted song from the library and derives the whole
    /// taste profile from that one batch: artist ranking, genre mix,
    /// release-decade histogram, and total music time. Uncapped by design —
    /// the resolve is one library walk whose cost is bounded by library size,
    /// not by how many IDs it looks for. Sorted songs are library songs by
    /// definition (sorting added them to a playlist), so the library resolver
    /// is the right path — no catalog split needed. Failure just leaves
    /// everything empty; the cards hide themselves rather than surfacing a
    /// lookup error on a stats screen.
    func loadTasteProfile(recentFirstSongIDs: [String]) async {
        guard !recentFirstSongIDs.isEmpty else { return }

        // De-dupe for the resolve. A song sorted twice (e.g. into two
        // playlists) still counts its artist twice below — the ranking
        // measures sorting activity, not distinct tracks.
        var seen = Set<String>()
        let uniqueIDs = recentFirstSongIDs.filter { seen.insert($0).inserted }

        isResolvingArtists = true
        defer { isResolvingArtists = false }

        do {
            let songs = try await service.resolveSongs(ids: uniqueIDs)
            // The cover may have been dismissed mid-walk — the model dies with
            // the view, so bail before counting and the portrait lookups.
            if Task.isCancelled { return }
            let byID = Dictionary(
                songs.map { ($0.id.rawValue, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            // One pass over the full (pre-dedupe) activity list: artists,
            // genres and decades all count per sort event so repeat sorts
            // weigh in, skipping songs that no longer resolve.
            let calendar = Calendar.current
            var artistCounts: [String: Int] = [:]
            var genreCounts: [String: Int] = [:]
            var decadeCounts: [Int: Int] = [:]
            var events = 0
            for id in recentFirstSongIDs {
                guard let song = byID[id] else { continue }
                events += 1
                artistCounts[song.artistName, default: 0] += 1
                for genre in song.genreNames where !Self.isUmbrellaGenre(genre) {
                    genreCounts[genre, default: 0] += 1
                }
                if let released = song.releaseDate {
                    let year = calendar.component(.year, from: released)
                    decadeCounts[(year / 10) * 10, default: 0] += 1
                }
            }

            resolvedEventCount = events
            genres = Array(
                genreCounts
                    .map { GenreShare(name: $0.key, count: $0.value) }
                    .sorted { lhs, rhs in
                        if lhs.count != rhs.count { return lhs.count > rhs.count }
                        return lhs.name < rhs.name   // stable tie-break
                    }
                    .prefix(4)
            )
            if let oldest = decadeCounts.keys.min(), let newest = decadeCounts.keys.max() {
                decades = stride(from: oldest, through: newest, by: 10).map {
                    DecadeCount(decade: $0, count: decadeCounts[$0] ?? 0)
                }
            } else {
                decades = []
            }
            // Distinct songs only — `songs` is already de-duped, and "how much
            // music passed through" shouldn't double-count a re-sorted track.
            musicSeconds = songs.compactMap(\.duration).reduce(0, +)

            var ranked = Array(
                artistCounts
                    .map { ArtistCount(name: $0.key, count: $0.value) }
                    .sorted { lhs, rhs in
                        if lhs.count != rhs.count { return lhs.count > rhs.count }
                        return lhs.name < rhs.name   // stable tie-break
                    }
                    .prefix(3)
            )
            for index in ranked.indices {
                ranked[index].seedSong = songs.first(where: { $0.artistName == ranked[index].name })
            }
            // Publish rows (and drop the bones) as soon as counting is done —
            // the portrait lookups below are slow network calls, and the rows
            // are already useful with their initial-letter circles.
            topArtists = ranked
            isResolvingArtists = false

            // Attach portraits via the same resolver the Artist hub uses
            // (exact-name catalog match, "Various Artists" guarded), so the
            // face here always matches the artist page a lookup would open.
            // Each write lands in the visible rows, so avatars fill in live.
            for index in ranked.indices {
                if Task.isCancelled { return }
                guard let seed = ranked[index].seedSong else { continue }
                do {
                    topArtists[index].artwork = try await service.resolveArtist(for: seed)?.artwork
                } catch {
                    // "No catalog page" is the nil return above — a throw is a
                    // real lookup failure, and the initial-letter fallback
                    // shouldn't hide it from the log.
                    print("InsightsModel portrait resolve failed for \(ranked[index].name): \(error)")
                }
            }
        } catch {
            print("InsightsModel.loadTasteProfile failed: \(error)")
            topArtists = []
            genres = []
            decades = []
            musicSeconds = 0
            resolvedEventCount = 0
        }
    }

    /// Apple tags every catalog song with the generic "Music" genre — it says
    /// nothing about taste, so the genre mix skips it.
    private static func isUmbrellaGenre(_ name: String) -> Bool {
        name.caseInsensitiveCompare("Music") == .orderedSame
    }
}
