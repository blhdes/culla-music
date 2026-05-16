import Foundation
import MusicKit
import SwiftData

/// Resolves "the playlist an up-swipe should add to" — either the one the user
/// picked in Settings, an existing "Culla Loves" already in Apple Music, or a
/// fresh one this app creates on demand. Also owns the self-heal logic that
/// runs when a write to the resolved playlist fails.
///
/// Why a separate type:
/// - Apple Music's library is eventually consistent for newly-created
///   playlists, so the first write often fails even on a healthy target.
///   The resolver tracks which playlist *we* created this session so the
///   caller can tell "transient timing failure" from "real read-only failure".
/// - Smart system playlists (the heart-button "Favorites") have metadata
///   identical to user-made playlists, so detection is name-based with a
///   locale list. Misses are caught by a write-failure self-heal that demotes
///   the playlist locally and clears the defaults pointer so the next up-swipe
///   picks (or creates) a different target.
///
/// The resolver does NOT do the optimistic SortedSong write, the membership
/// update, or the action-history record — those stay on the VM because they're
/// generic to every sort path, not loved-specific.
@MainActor
final class LovedPlaylistResolver {
    /// Key under which the loved-playlist's Apple Music ID is persisted.
    /// Views read this same key via `@AppStorage("lovedPlaylistID")` literals —
    /// keep them in sync if it ever changes (Settings, ManagePlaylistsSheet,
    /// PlaylistMembershipChips, LovedPlaylistPickerSheet).
    static let defaultsKey = "lovedPlaylistID"

    /// Name of the auto-created playlist when the user hasn't picked one.
    static let defaultName = "Culla Loves"

    /// Apple Music ID of a loved playlist that *this* process created via
    /// `resolveOrCreate`. Lets the caller distinguish "first add to a brand-new
    /// playlist Apple hasn't fully propagated" from "tried to write into a
    /// genuinely read-only playlist" so a transient timing failure doesn't
    /// trash our own freshly-created playlist.
    private(set) var sessionCreatedAMID: String?

    private let service: MusicLibraryService
    private let modelContext: ModelContext

    /// Lookup closure that returns the current `playlists` array from the VM.
    /// Wired post-init via `setPlaylistsProvider` (same reason as
    /// `MembershipIndex` — closure can't capture `self` mid-init).
    private var playlistsProvider: @MainActor () -> [Playlist] = { [] }

    /// Hook the VM uses to refresh its local `playlists` mirror after the
    /// resolver inserts or mutates a row. Wired post-init.
    private var onPlaylistsChanged: @MainActor () -> Void = {}

    init(service: MusicLibraryService, modelContext: ModelContext) {
        self.service = service
        self.modelContext = modelContext
    }

    func setPlaylistsProvider(_ provider: @escaping @MainActor () -> [Playlist]) {
        playlistsProvider = provider
    }

    func setOnPlaylistsChanged(_ block: @escaping @MainActor () -> Void) {
        onPlaylistsChanged = block
    }

    // MARK: - Public API

    /// Returns the configured loved-playlist (matching the AM ID stored under
    /// `defaultsKey` in UserDefaults). Adopts an existing "Culla Loves" in
    /// Apple Music when present, otherwise creates a fresh one. Returns nil
    /// only if creation itself fails; the caller surfaces a toast.
    func resolveOrCreate() async -> Playlist? {
        let defaults = UserDefaults.standard
        // Require `isEditable` so a stored target that's since been flagged
        // read-only (by sync or by an earlier write failure) falls through to
        // auto-create instead of repeating the failed write.
        let playlists = playlistsProvider()
        if let stored = defaults.string(forKey: Self.defaultsKey),
           !stored.isEmpty,
           let match = playlists.first(where: { $0.appleMusicPlaylistID == stored }),
           match.isEditable {
            return match
        }

        // Stored ID is missing / read-only. Before creating yet another
        // duplicate, look for an existing "Culla Loves" already in Apple's
        // library — could be from a previous buggy session where the
        // create-response ID didn't match the canonical library ID, or one
        // the user made manually. Adopt the first editable match instead of
        // spawning another empty playlist every launch.
        if let refreshed = try? await service.refreshUserPlaylists() {
            let candidates = refreshed.filter {
                $0.name == Self.defaultName && computeEditability(for: $0)
            }
            if let adopted = candidates.first {
                return upsertLocalLovedRow(amID: adopted.id.rawValue)
            }
        }

        // Genuinely missing — create one.
        do {
            let amPlaylist = try await service.createPlaylist(name: Self.defaultName)
            // Apple Music's library is eventually consistent — give the new
            // playlist a moment to be queryable before the caller tries to
            // add a song. Without this, the first up-swipe almost always
            // hits the catch path because MusicLibraryRequest can't yet see
            // the playlist we literally just created.
            try? await Task.sleep(for: .milliseconds(600))

            // The `.id` returned by `MusicLibrary.shared.createPlaylist` does
            // not always match the library ID that subsequent
            // `MusicLibraryRequest<MusicKit.Playlist>` fetches return for the
            // same playlist. If we anchor on the create-response ID,
            // `addSong` resolves via `MusicLibraryRequest.filter(matching: \.id, ...)`,
            // gets nothing, throws `playlistNotFound`, and the next launch's
            // self-heal nukes defaults and spawns a fresh duplicate — every
            // session. Re-fetch and prefer the new playlist (matched by name,
            // with an ID not yet in our local SwiftData) so we record the
            // canonical library ID instead.
            let existingAMIDs = Set(playlistsProvider().compactMap(\.appleMusicPlaylistID))
            var canonicalAMID = amPlaylist.id.rawValue
            if let refreshed = try? await service.refreshUserPlaylists(),
               let canonical = refreshed.first(where: {
                   $0.name == Self.defaultName
                       && !existingAMIDs.contains($0.id.rawValue)
               }) {
                canonicalAMID = canonical.id.rawValue
            }
            return upsertLocalLovedRow(amID: canonicalAMID)
        } catch {
            return nil
        }
    }

    /// True when the given AM ID is the playlist *we* created this session.
    /// The VM's loveCurrent catch path uses this to distinguish "Apple's
    /// library is still catching up" (don't demote) from "this is actually
    /// read-only" (demote).
    func isSessionCreated(_ amIDString: String) -> Bool {
        sessionCreatedAMID == amIDString
    }

    /// Self-heal: a write to this playlist failed and it wasn't one we just
    /// created. Demote it locally so picker / sidebar / sources hide it from
    /// now on, and clear the defaults pointer so the next up-swipe picks a
    /// different target. Sticky-downgrade in sync stops the heuristic
    /// re-upgrading it on next launch.
    func markReadOnly(_ playlist: Playlist) {
        let amIDString = playlist.appleMusicPlaylistID ?? ""
        playlist.isEditable = false
        if playlist.isInSidebar { playlist.isInSidebar = false }
        try? modelContext.save()
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.defaultsKey) == amIDString {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
        onPlaylistsChanged()
    }

    // MARK: - Private

    /// Either returns the existing local `Playlist` row tagged with this AM ID
    /// (re-enabling it if it was previously disabled) or inserts a new one.
    /// Also points `defaultsKey` at this AM ID and arms the session-created
    /// flag so a transient first-add failure doesn't kick off the duplicate-
    /// spawning self-heal.
    @discardableResult
    private func upsertLocalLovedRow(amID: String) -> Playlist {
        let row: Playlist
        let playlists = playlistsProvider()
        if let existing = playlists.first(where: { $0.appleMusicPlaylistID == amID }) {
            existing.isEditable = true
            row = existing
        } else {
            let nextOrder = (playlists.map(\.displayOrder).max() ?? -1) + 1
            let inserted = Playlist(
                name: Self.defaultName,
                displayOrder: nextOrder,
                appleMusicPlaylistID: amID,
                isInSidebar: false,
                isEditable: true
            )
            modelContext.insert(inserted)
            row = inserted
        }
        try? modelContext.save()
        onPlaylistsChanged()
        UserDefaults.standard.set(amID, forKey: Self.defaultsKey)
        sessionCreatedAMID = amID
        return row
    }
}
