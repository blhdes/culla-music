import Foundation

struct SwipeConfig {
    var mode: ReviewMode = .library
    var order: SortOrder = .newestFirst
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
        case .library:   "Your full music library"
        case .unsorted:  "Songs not in any of your playlists"
        case .dismissed: "Songs you've previously skipped"
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
