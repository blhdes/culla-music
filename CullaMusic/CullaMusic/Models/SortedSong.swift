import Foundation
import SwiftData

@Model
final class SortedSong {
    var id: UUID
    var songID: String
    var sortedAt: Date
    var playlist: Playlist?

    init(songID: String, playlist: Playlist) {
        self.id = UUID()
        self.songID = songID
        self.sortedAt = .now
        self.playlist = playlist
    }
}
