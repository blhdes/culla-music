import Foundation
import MusicKit

extension Song {
    /// A link that opens this song in Apple Music. Prefers the catalog URL when
    /// the song was matched to the catalog; otherwise falls back to an Apple
    /// Music *search* for the title + artist — so library-only songs (whose
    /// `url` is nil) still open to the right place instead of nowhere.
    var appleMusicLinkURL: URL {
        if let url { return url }
        var components = URLComponents(string: "https://music.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artistName)")
        ]
        return components?.url ?? URL(string: "https://music.apple.com")!
    }
}
