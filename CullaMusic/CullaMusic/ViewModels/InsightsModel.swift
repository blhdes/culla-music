import Foundation
import MusicKit

/// Backs the Insights screen. Everything on that screen except Top Artists is
/// computed straight from the local SwiftData rows the view already holds via
/// `@Query`; this model owns the two pieces that aren't a simple count:
/// streak math and the async top-artist resolve.
@Observable
@MainActor
final class InsightsModel {

    struct ArtistCount: Identifiable {
        let name: String
        let count: Int
        /// The artist-page portrait, filled by `loadTopArtists` when the name
        /// resolves to a catalog artist; nil → the view shows an initial circle.
        var artwork: Artwork?
        var id: String { name }
    }

    private(set) var currentStreak = 0
    private(set) var longestStreak = 0

    /// The user's most-sorted artists, filled in by `loadTopArtists`.
    private(set) var topArtists: [ArtistCount] = []
    /// True while the library resolve that powers Top Artists is in flight —
    /// the card shows skeleton bones meanwhile.
    private(set) var isResolvingArtists = false
    /// Set once the resolve has finished (success or failure), so the view can
    /// tell "still loading, show bones" apart from "done and empty, hide the
    /// card" — without this the card would vanish and reappear on load.
    private(set) var artistResolveFinished = false

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

    // MARK: - Top artists

    /// Cap on how many sorted songs feed the artist ranking. Matches History's
    /// resolve cap: recent activity is what the ranking should reflect, and it
    /// keeps the library walk bounded on long histories.
    private let artistSampleLimit = 200

    /// Resolves the most recent sorted songs from the library and ranks their
    /// artists. Sorted songs are library songs by definition (sorting added
    /// them to a playlist), so the library resolver is the right path — no
    /// catalog split needed. Failure just leaves `topArtists` empty; the card
    /// hides itself rather than surfacing an error on a stats screen.
    func loadTopArtists(recentFirstSongIDs: [String]) async {
        guard !recentFirstSongIDs.isEmpty else {
            artistResolveFinished = true
            return
        }

        // De-dupe while keeping recency order, then cap. A song sorted twice
        // (e.g. into two playlists) still counts its artist twice below — the
        // ranking measures sorting activity, not distinct tracks.
        var seen = Set<String>()
        let uniqueIDs = recentFirstSongIDs
            .filter { seen.insert($0).inserted }
            .prefix(artistSampleLimit)

        isResolvingArtists = true
        defer {
            isResolvingArtists = false
            artistResolveFinished = true
        }

        do {
            let songs = try await service.resolveSongs(ids: Array(uniqueIDs))
            let byID = Dictionary(
                songs.map { ($0.id.rawValue, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            // Count per artist across the full (pre-dedupe) activity list so
            // repeat sorts weigh in, skipping songs that no longer resolve.
            var counts: [String: Int] = [:]
            for id in recentFirstSongIDs.prefix(artistSampleLimit) {
                guard let song = byID[id] else { continue }
                counts[song.artistName, default: 0] += 1
            }
            var ranked = Array(
                counts
                    .map { ArtistCount(name: $0.key, count: $0.value) }
                    .sorted { lhs, rhs in
                        if lhs.count != rhs.count { return lhs.count > rhs.count }
                        return lhs.name < rhs.name   // stable tie-break
                    }
                    .prefix(3)
            )
            // Attach portraits via the same resolver the Artist hub uses
            // (exact-name catalog match, "Various Artists" guarded), so the
            // face here always matches the artist page a lookup would open.
            // The resolver wants a Song, so any resolved song by the artist
            // seeds it; a miss just leaves the initial-letter fallback.
            for index in ranked.indices {
                let name = ranked[index].name
                guard let seed = songs.first(where: { $0.artistName == name }) else { continue }
                ranked[index].artwork = (try? await service.resolveArtist(for: seed))?.artwork
            }
            topArtists = ranked
        } catch {
            print("InsightsModel.loadTopArtists failed: \(error)")
            topArtists = []
        }
    }
}
