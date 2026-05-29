import Foundation
import SwiftData

@Model
final class DismissedSong {
    var id: UUID
    var songID: String
    var dismissedAt: Date

    /// True when this song lives only in the Apple Music catalog, not the
    /// user's library — i.e. it was dismissed from a playlist scope while
    /// auditing tracks they haven't added yet. The Dismissed deck reads this
    /// to resolve the song from the catalog instead of the library. Defaults
    /// to `false` so every pre-existing record (all library tracks) keeps
    /// resolving exactly as before.
    var isCatalogTrack: Bool = false

    init(songID: String) {
        self.id = UUID()
        self.songID = songID
        self.dismissedAt = .now
    }
}
