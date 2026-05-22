import Foundation

struct SwipeConfig {
    var mode: ReviewMode = .library
    var order: SortOrder = .newestFirst
    var source: SourceScope?
    var sourceTransferMode: SourceTransferMode = .copy
    /// Opt-in for scoped (playlist/artist) sessions to also surface
    /// previously-dismissed tracks — "audit this collection" intent. Ignored
    /// when `source == nil`; All-Library walks always hide dismissals.
    var includeDismissedInScope: Bool = false

    var isPlaylistSource: Bool {
        if case .playlist = source { return true }
        return false
    }

    var isArtistSource: Bool {
        if case .artist = source { return true }
        return false
    }

    /// Returns the source playlist's ID only when the scope is `.playlist`,
    /// so the playlist-only call sites (Move-from-source, restore-on-undo)
    /// naturally bail to nil for artist or library scope.
    var sourcePlaylistID: String? {
        if case .playlist(let id, _, _) = source { return id }
        return nil
    }

    var sourcePlaylistName: String? {
        if case .playlist(_, let name, _) = source { return name }
        return nil
    }
}

/// Optional scope passed alongside a `.library` swipe to narrow the deck to a
/// single playlist or artist. Library walks are unscoped (no value).
enum SourceScope: Equatable {
    case playlist(id: String, name: String, isEditable: Bool)
    case artist(id: String, name: String)

    var displayName: String {
        switch self {
        case .playlist(_, let name, _): return name
        case .artist(_, let name): return name
        }
    }
}

enum ReviewMode: String, CaseIterable, Identifiable {
    case library
    case unsorted
    case dismissed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .library:   "Library"
        case .unsorted:  "Unsorted"
        case .dismissed: "Dismissed"
        }
    }

    var description: String {
        switch self {
        case .library:   "Everything"
        case .unsorted:  "Not in any playlist"
        case .dismissed: "Previously skipped"
        }
    }

    var icon: String {
        switch self {
        case .library:   "music.note.list"
        case .unsorted:  "tray.full"
        case .dismissed: "archivebox"
        }
    }
}

enum SortOrder: String, CaseIterable {
    case newestFirst
    case oldestFirst

    var label: String {
        switch self {
        case .newestFirst: "Newest first"
        case .oldestFirst: "Oldest first"
        }
    }

    var ascending: Bool { self == .oldestFirst }
}

enum SourceTransferMode: String, CaseIterable {
    case copy
    case move

    var label: String {
        switch self {
        case .copy: "Keep in playlist"
        case .move: "Move out"
        }
    }
}
