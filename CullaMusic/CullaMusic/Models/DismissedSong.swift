import Foundation
import SwiftData

@Model
final class DismissedSong {
    var id: UUID
    var songID: String
    var dismissedAt: Date

    init(songID: String) {
        self.id = UUID()
        self.songID = songID
        self.dismissedAt = .now
    }
}
