import Foundation

/// Persisted set of playlist Apple Music IDs whose tracks are filtered out of
/// `.library` swipe sessions (lenient: a song is hidden only when *every*
/// playlist it belongs to is in this set). Stored as a comma-joined `String`
/// so the value fits `@AppStorage`'s native types — Apple Music IDs never
/// contain commas, so no escaping is needed. Read by
/// `MusicLibraryService.deckExclusionSet`, read + written by
/// `ManagePlaylistsSheet`.
enum QueueFilterStore {
    static let defaultsKey = "queueFilterPlaylistAMIDs"

    static func read() -> Set<String> {
        decode(UserDefaults.standard.string(forKey: defaultsKey) ?? "")
    }

    static func decode(_ raw: String) -> Set<String> {
        guard !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").map(String.init))
    }

    static func encode(_ set: Set<String>) -> String {
        set.sorted().joined(separator: ",")
    }
}
