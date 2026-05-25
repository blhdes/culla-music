import Foundation

/// Resolves an artist name to its English Wikipedia page *title* via MusicBrainz,
/// for the cases where a direct name → Wikipedia lookup misses or lands on the
/// wrong subject ("Air" → the gas). MusicBrainz disambiguates by identity
/// (MBID); many artists then link out only through Wikidata, so we follow that
/// hop too (verified: "Air" the band exposes only a `wikidata` relation).
///
/// All MusicBrainz requests pass through a ≥1s gate — their published rate limit
/// is 1 req/sec/IP — and carry the mandatory descriptive User-Agent (via
/// `cullaGET`). Wikidata is generous and skips the gate.
actor MusicBrainzClient {
    static let shared = MusicBrainzClient()
    private init() {}

    // MARK: - Rate-limit gate

    private var nextSlot = Date.distantPast
    private static let minInterval: TimeInterval = 1.1  // a hair over 1 req/sec

    /// Reserves the next time slot *atomically* — the `nextSlot` write happens
    /// before any `await`, so concurrent callers (a fast A → B → C drill) each
    /// grab a distinct, increasing slot instead of all firing at once — then
    /// sleeps until its slot comes up.
    private func awaitSlot() async {
        let now = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(Self.minInterval)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }

    // MARK: - Public

    /// English Wikipedia page title for `name`, or nil when MusicBrainz can't
    /// confidently identify the artist or it has no English page.
    func wikipediaTitle(forArtist name: String) async throws -> String? {
        guard let mbid = try await bestMatchMBID(forArtist: name),
              let relations = try await urlRelations(forMBID: mbid)
        else { return nil }

        // Prefer a direct Wikipedia relation; otherwise hop through Wikidata.
        if let wiki = relations.first(where: { $0.type == "wikipedia" }),
           let title = Self.wikipediaTitle(fromURL: wiki.url.resource) {
            return title
        }
        if let wd = relations.first(where: { $0.type == "wikidata" }),
           let qid = Self.wikidataQID(fromURL: wd.url.resource) {
            return try await enwikiTitle(forWikidataQID: qid)
        }
        return nil
    }

    // MARK: - MusicBrainz (gated)

    private func bestMatchMBID(forArtist name: String) async throws -> String? {
        var comps = URLComponents(string: "https://musicbrainz.org/ws/2/artist")
        comps?.queryItems = [
            .init(name: "query", value: name),
            .init(name: "fmt", value: "json"),
            .init(name: "limit", value: "5")
        ]
        guard let url = comps?.url else { return nil }

        await awaitSlot()
        let (data, _) = try await cullaGET(url)
        let result = try JSONDecoder().decode(SearchResult.self, from: data)

        // Strict: accept the highest-scored candidate only if its normalized
        // name matches the query. No match → nil (a wrong bio is worse than no
        // bio). The Wikipedia guards downstream are a second net.
        let target = Self.normalize(name)
        return result.artists
            .sorted { ($0.score ?? 0) > ($1.score ?? 0) }
            .first { Self.normalize($0.name) == target }?
            .id
    }

    private func urlRelations(forMBID mbid: String) async throws -> [Relation]? {
        guard let url = URL(string:
            "https://musicbrainz.org/ws/2/artist/\(mbid)?inc=url-rels&fmt=json")
        else { return nil }

        await awaitSlot()
        let (data, _) = try await cullaGET(url)
        return try JSONDecoder().decode(LookupResult.self, from: data).relations
    }

    // MARK: - Wikidata (not gated)

    private func enwikiTitle(forWikidataQID qid: String) async throws -> String? {
        guard let url = URL(string:
            "https://www.wikidata.org/wiki/Special:EntityData/\(qid).json")
        else { return nil }

        let (data, _) = try await cullaGET(url)
        let result = try JSONDecoder().decode(WikidataResult.self, from: data)
        return result.entities[qid]?.sitelinks?["enwiki"]?.title
    }

    // MARK: - Helpers

    /// Lowercase, drop accents and punctuation, drop a leading "the", collapse
    /// whitespace — so "Beyoncé" / "The Beatles" / "AC/DC" compare cleanly
    /// against MusicBrainz's spelling.
    private static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                               locale: nil)
        let cleaned = folded.map { $0.isLetter || $0.isNumber ? $0 : " " }
        var words = String(cleaned).split(separator: " ").map(String.init)
        if words.first == "the" { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// "https://en.wikipedia.org/wiki/Air_(band)" → "Air (band)".
    private static func wikipediaTitle(fromURL urlString: String) -> String? {
        guard let url = URL(string: urlString),
              url.host?.contains("wikipedia.org") == true,
              let last = url.pathComponents.last, !last.isEmpty
        else { return nil }
        return last.removingPercentEncoding?.replacingOccurrences(of: "_", with: " ")
    }

    /// "https://www.wikidata.org/wiki/Q318452" → "Q318452".
    private static func wikidataQID(fromURL urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let last = url.pathComponents.last, last.hasPrefix("Q")
        else { return nil }
        return last
    }

    // MARK: - Decodable (only the fields we use)

    private struct SearchResult: Decodable {
        let artists: [Artist]
        struct Artist: Decodable {
            let id: String
            let name: String
            let score: Int?
        }
    }

    private struct LookupResult: Decodable {
        let relations: [Relation]
    }

    private struct Relation: Decodable {
        let type: String
        let url: RelURL
        struct RelURL: Decodable { let resource: String }
    }

    private struct WikidataResult: Decodable {
        let entities: [String: Entity]
        struct Entity: Decodable {
            let sitelinks: [String: Sitelink]?
            struct Sitelink: Decodable { let title: String }
        }
    }
}
