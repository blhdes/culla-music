import Foundation
import SwiftData
import SwiftUI

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

    @Relationship(deleteRule: .cascade, inverse: \SortedSong.playlist)
    var sortedSongs: [SortedSong]

    var color: Color { Color.adaptiveNeon(hex: colorHex) }

    init(
        name: String,
        iconName: String = "music.note.list",
        colorHex: String? = nil,
        displayOrder: Int = 0,
        appleMusicPlaylistID: String? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.iconName = iconName
        self.colorHex = colorHex ?? Color.neonHexes[displayOrder % Color.neonHexes.count]
        self.displayOrder = displayOrder
        self.colorIndex = displayOrder
        self.createdAt = .now
        self.appleMusicPlaylistID = appleMusicPlaylistID
        self.sortedSongs = []
    }
}
