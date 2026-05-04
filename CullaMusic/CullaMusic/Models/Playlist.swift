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

    @Relationship(deleteRule: .cascade, inverse: \SortedSong.playlist)
    var sortedSongs: [SortedSong]

    init(
        name: String,
        iconName: String = "music.note.list",
        colorHex: String = "#F5F5F5",
        displayOrder: Int = 0,
        appleMusicPlaylistID: String? = nil,
        isInSidebar: Bool = false
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
        self.sortedSongs = []
    }
}
