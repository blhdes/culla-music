import Foundation

/// Persisted set of playlist Apple Music IDs whose tracks are filtered out of
/// `.library` swipe sessions (lenient: a song is hidden only when *every*
/// playlist it belongs to is in this set). Stored as a comma-joined `String`
/// so the value fits `@AppStorage`'s native types — Apple Music IDs never
/// contain commas, so no escaping is needed. Read by
/// `MusicLibraryService.queueFilterExclusions` (which feeds the hero, the
/// carousel, and the swipe session alike), read + written by
/// `ManagePlaylistsSheet`.
enum QueueFilterStore {
    static let defaultsKey = "queueFilterPlaylistAMIDs"
    /// Sibling key for the artist filter — same comma-joined `String` shape, so
    /// it shares `decode`/`encode` below. Apple Music artist IDs never contain
    /// commas either. Read by `MusicLibraryService.queueFilterExclusions`, read
    /// + written by `ManagePlaylistsSheet`'s Artists sub-tab.
    static let artistDefaultsKey = "queueFilterArtistAMIDs"

    /// Both filter sets captured at one instant. The swipe screen takes one
    /// when the Manage sheet opens and compares on close, so a change to
    /// EITHER list (playlists or artists) rebuilds the deck.
    struct Snapshot: Equatable {
        var playlists: Set<String> = []
        var artists: Set<String> = []
    }

    static func snapshot() -> Snapshot {
        Snapshot(playlists: read(), artists: readArtists())
    }

    static func read() -> Set<String> {
        decode(UserDefaults.standard.string(forKey: defaultsKey) ?? "")
    }

    /// Artist IDs whose tracks are filtered out of `.library` sessions. Unlike
    /// the playlist filter's lenient rule, this is a hard exclude: any library
    /// track crediting a listed artist is hidden (see `queueFilterExclusions`).
    static func readArtists() -> Set<String> {
        decode(UserDefaults.standard.string(forKey: artistDefaultsKey) ?? "")
    }

    static func decode(_ raw: String) -> Set<String> {
        guard !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").map(String.init))
    }

    static func encode(_ set: Set<String>) -> String {
        set.sorted().joined(separator: ",")
    }
}
