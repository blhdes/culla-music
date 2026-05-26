import Foundation
import SwiftData

@Model
final class Playlist {
    var id: UUID
    var name: String
    var iconName: String
    var colorHex: String
    var displayOrder: Int
    var colorIndex: Int
    var createdAt: Date

    /// Nil until the matching Apple Music playlist is actually created in the user's library.
    var appleMusicPlaylistID: String?

    /// User-controlled: which playlists appear in the right-swipe sidebar (capped to 5).
    var isInSidebar: Bool = false

    /// Whether this playlist accepts writes. Recomputed from Apple's current
    /// `Playlist.Kind` / name on every sync (see `computeEditability`) — it is
    /// NOT latched, so a playlist Apple reports as writable always recovers,
    /// even if an older heuristic once demoted it.
    /// Only editable playlists can be sorted into or added to the sidebar.
    var isEditable: Bool = true

    /// True only for playlists THIS app created (via `createPlaylist`). Apple's
    /// `MusicLibrary.shared.edit` — the only way to *remove* a track — succeeds
    /// solely on app-created playlists; it rejects every other library playlist
    /// (even the user's own Music-app ones) with `ICPlaylistUpdateErrorDomain`.
    /// So "Move out" (which removes from the source) is only offered when this
    /// is true. Defaults false: imported / synced / Music-app playlists can be
    /// added to but never edited, and a reinstall conservatively re-gates them.
    var createdByApp: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \SortedSong.playlist)
    var sortedSongs: [SortedSong]

    init(
        name: String,
        iconName: String = "music.note.list",
        colorHex: String = "#F5F5F5",
        displayOrder: Int = 0,
        appleMusicPlaylistID: String? = nil,
        isInSidebar: Bool = false,
        isEditable: Bool = true,
        createdByApp: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.iconName = iconName
        self.colorHex = colorHex
        self.displayOrder = displayOrder
        self.colorIndex = displayOrder
        self.createdAt = .now
        self.appleMusicPlaylistID = appleMusicPlaylistID
        self.isInSidebar = isInSidebar
        self.isEditable = isEditable
        self.createdByApp = createdByApp
        self.sortedSongs = []
    }
}
