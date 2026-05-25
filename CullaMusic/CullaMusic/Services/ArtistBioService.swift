import Foundation

/// Fetches a short artist bio from Wikipedia's REST summary endpoint.
///
/// Artist-name → Wikipedia summary, fronted by a disk cache. Two guards keep us
/// from rendering a confident *wrong* bio (the real hazard of name-only lookup):
///   - reject `type == "disambiguation"` (e.g. "Drake", "Nas")
///   - reject when the page `description` has no music word (e.g. "Bush" →
///     "President of the United States", "Air" → the gas)
/// A rejected match returns `nil` (the hub hides the section) rather than
/// surfacing misinformation. The correct long-term fix is the MusicBrainz
/// MBID hop in a later slice.
@MainActor
final class ArtistBioService {
    static let shared = ArtistBioService()
    private let cache = ArtistBioCache()
    private init() {}

    struct ArtistBio: Codable, Sendable {
        let extract: String
        /// Short tag like "English rock band" — shown under the bio so a user
        /// can spot a subtle wrong match.
        let descriptor: String?
        let pageURL: URL
    }

    /// Cache-first, then two attempts:
    ///   1. direct — the artist name straight to Wikipedia.
    ///   2. fallback — if direct misses, ask MusicBrainz to disambiguate the
    ///      identity and hand back the correct English Wikipedia title.
    /// A fresh cache hit (including a cached "no bio") returns immediately. The
    /// final result — bio or definitive nil — is cached. A *direct* network
    /// error is surfaced (the view shows a retry row); the MusicBrainz fallback
    /// is best-effort, so its errors degrade to "no bio" instead.
    func bio(forName name: String) async throws -> ArtistBio? {
        if let cached = await cache.entry(forName: name) {
            return cached.bio
        }

        var result = try await summary(forTitle: name)

        if result == nil {
            let resolved = try? await MusicBrainzClient.shared.wikipediaTitle(forArtist: name)
            if let title = resolved ?? nil {
                result = (try? await summary(forTitle: title)) ?? nil
            }
        }

        await cache.upsert(name: name, bio: result)
        return result
    }

    /// One Wikipedia summary round-trip for a given page title, with the guards
    /// applied. Used for both the direct attempt (title = artist name) and the
    /// MusicBrainz-resolved title.
    private func summary(forTitle title: String) async throws -> ArtistBio? {
        guard let url = Self.summaryURL(forTitle: title) else { return nil }

        let (data, status) = try await cullaGET(url)
        // 404 = no page for this title. "No bio", not an error.
        if status == 404 { return nil }

        let payload = try JSONDecoder().decode(WikipediaSummary.self, from: data)
        guard Self.looksLikeArtist(payload),
              !payload.extract.isEmpty,
              let pageURL = URL(string: payload.content_urls.desktop.page)
        else { return nil }

        return ArtistBio(
            extract: payload.extract,
            descriptor: payload.description,
            pageURL: pageURL
        )
    }

    // MARK: - URL

    private static func summaryURL(forTitle title: String) -> URL? {
        // Wikipedia titles use underscores for spaces; everything else gets
        // percent-encoded. We strip "/" from the allowed set so "AC/DC"
        // becomes "AC%2FDC" instead of a bogus path separator.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let underscored = title.replacingOccurrences(of: " ", with: "_")
        guard let encoded = underscored.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)")
    }

    // MARK: - Guards

    /// True when the page is a real article (not a disambiguation list) and its
    /// description reads like a music act. A nil description is accepted —
    /// rare for notable artists, and rejecting on absence would drop legit
    /// matches. This list is the one tuning knob for the spot-check.
    private static func looksLikeArtist(_ summary: WikipediaSummary) -> Bool {
        if summary.type == "disambiguation" { return false }

        // Reject *works* before checking for music words. Name-only lookup
        // lands on album/soundtrack/compilation articles whose description
        // ("UK compilation album series", "Album") often carries a genre word
        // too, so the music-word check alone lets them through. The short
        // description is the reliable signal; fall back to the extract's
        // opening when there's no description.
        let workWords = ["album", "soundtrack", "compilation", "mixtape",
                         "discography", "extended play"]
        let workHaystack = (summary.description ?? String(summary.extract.prefix(90)))
            .lowercased()
        if workWords.contains(where: { workHaystack.contains($0) }) { return false }

        guard let description = summary.description?.lowercased() else { return true }
        let musicWords = [
            "band", "singer", "musician", "rapper", "songwriter", "producer",
            "dj", "duo", "trio", "quartet", "group", "composer", "vocalist",
            "guitarist", "drummer", "bassist", "rock", "pop", "hip hop",
            "metal", "jazz", "r&b", "music", "performer", "ensemble",
            "orchestra", "choir", "record"
        ]
        return musicWords.contains { description.contains($0) }
    }

    // Only the fields we use. Wikipedia returns ~30; we ignore the rest.
    private struct WikipediaSummary: Decodable {
        let type: String?
        let description: String?
        let extract: String
        let content_urls: ContentURLs
        struct ContentURLs: Decodable {
            let desktop: Desktop
            struct Desktop: Decodable { let page: String }
        }
    }
}
