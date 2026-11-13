import SwiftUI
import MusicKit

// MARK: - ArtistThumbnail

/// Renders an artist's library artwork as a small circular thumbnail for the
/// source button. Reads the cached `Artist` from `MusicLibraryService` rather
/// than refetching — the picker sheet primes the cache when it lists artists.
/// Falls back to an initials placeholder when the library artist has no
/// catalog-matched artwork.
struct ArtistThumbnail: View {
    let artistID: String
    let artistName: String
    let size: CGFloat

    var body: some View {
        Group {
            if let artwork = MusicLibraryService.shared.artwork(forArtistID: artistID) {
                ArtworkImage(artwork, width: size, height: size)
            } else {
                ArtistPlaceholder(name: artistName, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
