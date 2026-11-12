import Foundation

/// MusicBrainz blocks clients that don't send a descriptive User-Agent, and
/// Wikipedia / Wikidata are friendlier with one too. Every outbound request in
/// the bio pipeline goes through `cullaGET` so the header is set in one place.
///
/// The version is read from the bundle so it tracks the shipped build (it was
/// hard-coded to "1.0" and went stale by 1.5.0).
let cullaUserAgent: String = {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    return "CullaMusic/\(version) ( agomezurrea@gmail.com )"
}()

/// GET with the Culla User-Agent set. Returns the body and HTTP status (0 for a
/// non-HTTP response) — deliberately *not* the `URLResponse`, which isn't
/// `Sendable` and would trip strict-concurrency checks when handed across the
/// actor boundary in `MusicBrainzClient`.
func cullaGET(_ url: URL) async throws -> (data: Data, status: Int) {
    var request = URLRequest(url: url)
    request.setValue(cullaUserAgent, forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    return (data, status)
}
