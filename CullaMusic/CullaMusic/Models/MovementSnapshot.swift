import Foundation
import MusicKit
import SwiftData

/// A movement row (`SortedSong` / `DismissedSong`) that can carry a saved copy
/// of its song's display identity. The library row is the only durable thing
/// Culla keeps — if the user later deletes the song from Apple Music, the live
/// `Song` stops resolving and every screen loses the title/artist/cover. The
/// snapshot preserves that identity at movement time so History can still show
/// *what* was sorted or dismissed (as a greyed tombstone) after the song is gone.
protocol MovementSnapshotting: AnyObject {
    var snapshotTitle: String? { get set }
    var snapshotArtist: String? { get set }
    var snapshotArtworkData: Data? { get set }
}

/// Captures a song's identity onto a movement row.
///
/// Title/artist are copied synchronously — the caller's own `save()` persists
/// them with the row. The artwork thumb needs a network fetch, so it's kicked
/// off as a fire-and-forget task that writes back (with its own save) when the
/// bytes land; a movement never waits on an image download.
enum MovementSnapshotter {
    /// Longest edge of the stored thumb, in pixels. 52pt row avatar at 3x =
    /// 156px, so 300px keeps tombstones sharp without hoarding disk.
    private static let thumbPixels = 300
    /// Discard anything suspiciously large — a thumb should be tens of KB.
    private static let maxThumbBytes = 2 * 1024 * 1024

    /// Copies title/artist onto the row now (caller saves) and fetches the
    /// artwork thumb in the background when the row doesn't have one yet.
    /// `fetchArtwork: false` skips the download half — History's backfill
    /// uses it to cap how many covers one open can pull.
    ///
    /// Artwork is best-effort by design: `Artwork.url` for library-only items
    /// can be a `musicKit://` URL that only MusicKit's own views can render —
    /// those are skipped, and the tombstone falls back to a placeholder cover
    /// while keeping the saved title/artist. Catalog-matched artwork (https)
    /// fetches fine, which is the common case.
    static func capture(
        from song: Song,
        into row: some MovementSnapshotting & PersistentModel,
        context: ModelContext,
        fetchArtwork: Bool = true
    ) {
        row.snapshotTitle = song.title
        row.snapshotArtist = song.artistName

        guard
            fetchArtwork,
            row.snapshotArtworkData == nil,
            let url = song.artwork?.url(width: thumbPixels, height: thumbPixels),
            url.scheme == "https" || url.scheme == "http"
        else { return }

        Task {
            guard
                let (data, _) = try? await URLSession.shared.data(from: url),
                !data.isEmpty, data.count <= maxThumbBytes
            else { return }
            // The row may have been deleted while the fetch was in flight
            // (e.g. an immediate undo) — writing to a deleted model is invalid.
            guard !row.isDeleted, row.modelContext != nil else { return }
            row.snapshotArtworkData = data
            do {
                try context.save()
            } catch {
                print("MovementSnapshotter artwork save failed: \(error)")
            }
        }
    }
}
