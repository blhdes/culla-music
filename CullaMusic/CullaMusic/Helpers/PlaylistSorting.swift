import Foundation

// MARK: - Shared playlist sort

extension Array where Element == Playlist {
    /// Orders playlists by a sort field — the one implementation every sheet and
    /// the swipe sidebar share, so they all sort identically. A `nil` field keeps
    /// the source order (for the sidebar that's `displayOrder`, i.e. the order the
    /// playlists were added).
    ///
    /// `trackCount` is injected because callers read counts from different places:
    /// the manage sheet and swipe sidebar use the live `membershipIndex`, the
    /// scope picker uses a fetched dictionary. Missing modified-dates sink to the
    /// bottom while ascending; the `descending` reverse then floats them to the
    /// top — unchanged from the original inline sorts this replaced.
    func sortedBy(
        field: PlaylistSortField?,
        descending: Bool,
        trackCount: (Playlist) -> Int
    ) -> [Playlist] {
        guard let field else { return self }
        var rows = self
        rows.sort { lhs, rhs in
            switch field {
            case .alphabetical:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .modifiedDate:
                let l = lhs.appleMusicPlaylistID.flatMap {
                    MusicLibraryService.shared.lastModifiedDate(forPlaylistID: $0)
                }
                let r = rhs.appleMusicPlaylistID.flatMap {
                    MusicLibraryService.shared.lastModifiedDate(forPlaylistID: $0)
                }
                switch (l, r) {
                case let (l?, r?): return l < r
                case (nil, _?):    return false
                case (_?, nil):    return true
                case (nil, nil):
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            case .trackCount:
                return trackCount(lhs) < trackCount(rhs)
            }
        }
        if descending { rows.reverse() }
        return rows
    }
}

// MARK: - Sidebar sort field

/// Sort options for the **Sidebar** segment of `ManagePlaylistsSheet`, and the
/// order the live swipe sidebar (`MusicSwipeView`) inherits from it. Adds
/// "Sidebar Order" — the playlists' real `displayOrder` (the order they were
/// added) — as a directionless default, so opening the sheet doesn't reshuffle
/// anything. Lives here, not inside the sheet, because the swipe sidebar reads
/// the same choice to stay in sync.
enum SidebarSortField: String, CaseIterable, Identifiable, SortFieldProtocol {
    case sidebarOrder
    case alphabetical
    case modifiedDate
    case trackCount

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sidebarOrder: String(localized: "Sidebar Order")
        case .alphabetical: String(localized: "Name")
        case .modifiedDate: String(localized: "Date Modified")
        case .trackCount:   String(localized: "Song Count")
        }
    }

    /// `nil` for `sidebarOrder` — the natural as-added order has no direction, so
    /// the chip shows a checkmark instead of an arrow and re-picking it is a no-op.
    var defaultDescending: Bool? {
        switch self {
        case .sidebarOrder: nil
        case .alphabetical: false  // A→Z reads best first
        case .modifiedDate: true   // newest first
        case .trackCount:   true   // biggest first
        }
    }

    /// Maps to the shared playlist sorter's field. `nil` keeps the source order,
    /// which for the sidebar is `displayOrder`.
    var playlistField: PlaylistSortField? {
        switch self {
        case .sidebarOrder: nil
        case .alphabetical: .alphabetical
        case .modifiedDate: .modifiedDate
        case .trackCount:   .trackCount
        }
    }
}

// MARK: - Legacy preference migration

/// One-time move from the old combined sort keys ("nameAsc", "dateDesc", …) to
/// the new field + direction pair, so a saved sort survives the redesign instead
/// of resetting. Runs at launch and is idempotent: it removes each legacy key
/// after splitting it, so re-running does nothing.
enum SortPreferenceMigration {
    static func run(_ defaults: UserDefaults = .standard) {
        migrate(defaults,
                legacy: "managePlaylists.sidebarSort",
                fieldKey: "managePlaylists.sidebarSortField",
                descendingKey: "managePlaylists.sidebarSortDescending")
        migrate(defaults,
                legacy: "managePlaylists.filterSort",
                fieldKey: "managePlaylists.filterSortField",
                descendingKey: "managePlaylists.filterSortDescending")
        migrate(defaults,
                legacy: "managePlaylists.artistFilterSort",
                fieldKey: "managePlaylists.artistFilterSortField",
                descendingKey: "managePlaylists.artistFilterSortDescending")
    }

    private static func migrate(
        _ defaults: UserDefaults,
        legacy: String,
        fieldKey: String,
        descendingKey: String
    ) {
        guard let combined = defaults.string(forKey: legacy) else { return }
        let split = split(combined)
        defaults.set(split.field, forKey: fieldKey)
        defaults.set(split.descending, forKey: descendingKey)
        defaults.removeObject(forKey: legacy)
    }

    /// "nameAsc" → ("alphabetical", false), "dateDesc" → ("modifiedDate", true),
    /// "countAsc" → ("trackCount", false), "sidebarOrder" → ("sidebarOrder", false).
    private static func split(_ raw: String) -> (field: String, descending: Bool) {
        switch raw {
        case "sidebarOrder": ("sidebarOrder", false)
        case "nameAsc":      ("alphabetical", false)
        case "nameDesc":     ("alphabetical", true)
        case "dateAsc":      ("modifiedDate", false)
        case "dateDesc":     ("modifiedDate", true)
        case "countAsc":     ("trackCount", false)
        case "countDesc":    ("trackCount", true)
        default:             ("alphabetical", false)
        }
    }
}
