import SwiftUI
import MusicKit

/// Sheet for picking a scope to sort from — a playlist, an artist, or
/// "All Library". The segmented control at the top swaps between the two
/// scoped lists; selecting "All Library" works from either tab.
struct SourceScopePickerSheet: View {
    let playlists: [Playlist]
    let selectedScope: SourceScope?
    let onPick: (SourceScope?) -> Void   // nil → All Library

    @Environment(\.dismiss) private var dismiss

    /// Per-playlist track counts loaded from the persisted membership index.
    /// HomeView has no live `MembershipIndex`, so we read the on-disk snapshot
    /// the swipe screen writes after each rebuild/swipe.
    @State private var trackCounts: [String: Int] = [:]
    @State private var libraryArtists: [Artist] = []
    @State private var isLoadingArtists: Bool = false
    /// Per-artist library track counts. Loaded from disk on open (instant if
    /// previously persisted), then refreshed via a parallel batch when the
    /// disk snapshot doesn't cover the current library.
    @State private var artistTrackCounts: [String: Int] = [:]
    /// Artist IDs we've attempted to count this session (or in a prior session
    /// loaded from disk). Used so we don't re-fetch artists whose count came
    /// back as "0" — `MusicLibraryService.safeCountLibrarySongs` deliberately
    /// returns nil for those, but we still know we tried. Refetch only fires
    /// when the current library has artists not in this set.
    @State private var attemptedArtistIDs: Set<String> = []
    @State private var isLoadingCounts: Bool = false
    @State private var pickerMode: PickerMode = .playlists
    @State private var searchQuery: String = ""
    /// Memoized filter+sort results. Recomputed only when an input changes
    /// (search text, sort field/direction, source data) rather than on every
    /// body render — typing in the search field was re-sorting the whole
    /// list per keystroke for users with 500+ artists.
    @State private var visiblePlaylists: [Playlist] = []
    @State private var visibleArtists: [Artist] = []

    // Sort preferences persist across sheet opens AND app launches. Each tab
    // has its own field + direction pair so sorting playlists by "Most tracks"
    // doesn't reshuffle artists.
    @AppStorage("picker.playlistSortField") private var playlistSortFieldRaw: String = PlaylistSortField.alphabetical.rawValue
    @AppStorage("picker.playlistSortDescending") private var playlistSortDescending: Bool = false
    @AppStorage("picker.artistSortField") private var artistSortFieldRaw: String = ArtistSortField.alphabetical.rawValue
    @AppStorage("picker.artistSortDescending") private var artistSortDescending: Bool = false

    enum PickerMode: String, CaseIterable, Identifiable {
        case playlists
        case artists

        var id: String { rawValue }
        var label: String { self == .playlists ? "Playlists" : "Artists" }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Scope", selection: $pickerMode) {
                    ForEach(PickerMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)

                listBody
            }
            .navigationTitle("Sort From")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .automatic))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if trackCounts.isEmpty {
                    trackCounts = await Task.detached(priority: .userInitiated) {
                        MembershipIndex.diskCountsSnapshot()
                    }.value
                }
            }
            .onAppear {
                // Seed the segmented control to the user's existing pick so
                // re-opening the sheet doesn't snap them back to Playlists.
                if case .artist = selectedScope { pickerMode = .artists }
                // Initial fill — body would otherwise paint an empty list
                // before the first onChange fires.
                visiblePlaylists = computeFilteredSortedPlaylists()
                visibleArtists = computeFilteredSortedArtists()
            }
            // Recompute triggers — explicit so we only re-filter+sort when
            // an actual input changed, not on every body render.
            .onChange(of: searchQuery) { _, _ in
                visiblePlaylists = computeFilteredSortedPlaylists()
                visibleArtists = computeFilteredSortedArtists()
            }
            .onChange(of: playlistSortFieldRaw) { _, _ in
                visiblePlaylists = computeFilteredSortedPlaylists()
            }
            .onChange(of: playlistSortDescending) { _, _ in
                visiblePlaylists = computeFilteredSortedPlaylists()
            }
            .onChange(of: trackCounts) { _, _ in
                visiblePlaylists = computeFilteredSortedPlaylists()
            }
            .onChange(of: artistSortFieldRaw) { _, _ in
                visibleArtists = computeFilteredSortedArtists()
            }
            .onChange(of: artistSortDescending) { _, _ in
                visibleArtists = computeFilteredSortedArtists()
            }
            .onChange(of: libraryArtists) { _, _ in
                visibleArtists = computeFilteredSortedArtists()
            }
            .onChange(of: artistTrackCounts) { _, _ in
                visibleArtists = computeFilteredSortedArtists()
            }
        }
    }

    // MARK: - Sort chip

    /// Per-tab sort control. The shared `SortChip` renders the active option
    /// and the flat menu of concrete (field, direction) combinations; this just
    /// hands it the right binding for the current tab.
    @ViewBuilder
    private var sortChip: some View {
        switch pickerMode {
        case .playlists: SortChip(selection: playlistSortChoiceBinding)
        case .artists:   SortChip(selection: artistSortChoiceBinding)
        }
    }

    /// Section header carrying the per-tab sort menu at its trailing edge.
    /// Anchoring the menu here — directly above the rows it reorders — replaces
    /// the old floating chip that sat in a detached band under the segmented
    /// control. `showsSpinner` surfaces the artist-count backfill inline.
    private func sortHeader(_ title: String, showsSpinner: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            if showsSpinner {
                ProgressView()
                    .controlSize(.small)
            }
            sortChip
        }
    }

    /// Concrete-choice bindings collapse (field, direction) into a single
    /// enum tag so the Menu Picker can render one flat list with a
    /// system-drawn checkmark on the active row. Storage stays the two
    /// `@AppStorage` keys — no migration needed.
    private var playlistSortChoiceBinding: Binding<PlaylistSortChoice> {
        Binding(
            get: {
                let field = PlaylistSortField(rawValue: playlistSortFieldRaw) ?? .alphabetical
                return PlaylistSortChoice(field: field, descending: playlistSortDescending)
            },
            set: { choice in
                playlistSortFieldRaw = choice.field.rawValue
                playlistSortDescending = choice.descending
            }
        )
    }

    private var artistSortChoiceBinding: Binding<ArtistSortChoice> {
        Binding(
            get: {
                let field = ArtistSortField(rawValue: artistSortFieldRaw) ?? .alphabetical
                return ArtistSortChoice(field: field, descending: artistSortDescending)
            },
            set: { choice in
                artistSortFieldRaw = choice.field.rawValue
                artistSortDescending = choice.descending
            }
        )
    }

    // MARK: - Filtering + sorting

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "All Library" disappears during search unless its name itself matches —
    /// we don't want it taking the top slot when the user is hunting a name.
    private var showsAllLibraryRow: Bool {
        guard !trimmedQuery.isEmpty else { return true }
        return "All Library".localizedStandardContains(trimmedQuery)
    }

    private func computeFilteredSortedPlaylists() -> [Playlist] {
        let field = PlaylistSortField(rawValue: playlistSortFieldRaw) ?? .alphabetical
        var rows = playlists
        if !trimmedQuery.isEmpty {
            rows = rows.filter { $0.name.localizedStandardContains(trimmedQuery) }
        }
        rows.sort { lhs, rhs in
            switch field {
            case .alphabetical:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .modifiedDate:
                // Missing-date rows sort last in ascending, first in descending —
                // keeping them out of the way regardless of direction.
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
                let l = (lhs.appleMusicPlaylistID.flatMap { trackCounts[$0] }) ?? 0
                let r = (rhs.appleMusicPlaylistID.flatMap { trackCounts[$0] }) ?? 0
                return l < r
            }
        }
        if playlistSortDescending { rows.reverse() }
        // Read-only (editorial / replay / shared) playlists always sink to the
        // bottom regardless of the user's sort — the user's own playlists are
        // what they're usually hunting for. `filter` is stable, so the user's
        // sort is preserved inside each group.
        let editable = rows.filter { $0.isEditable }
        let readOnly = rows.filter { !$0.isEditable }
        return editable + readOnly
    }

    private func computeFilteredSortedArtists() -> [Artist] {
        let field = ArtistSortField(rawValue: artistSortFieldRaw) ?? .alphabetical
        var rows = libraryArtists
        if !trimmedQuery.isEmpty {
            rows = rows.filter { $0.name.localizedStandardContains(trimmedQuery) }
        }
        rows.sort { lhs, rhs in
            switch field {
            case .alphabetical:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .trackCount:
                let l = artistTrackCounts[lhs.id.rawValue] ?? 0
                let r = artistTrackCounts[rhs.id.rawValue] ?? 0
                return l < r
            }
        }
        if artistSortDescending { rows.reverse() }
        return rows
    }

    // MARK: - Lists

    @ViewBuilder
    private var listBody: some View {
        switch pickerMode {
        case .playlists: playlistsList
        case .artists:   artistsList
        }
    }

    private var playlistsList: some View {
        let rows = visiblePlaylists
        return List {
            if showsAllLibraryRow {
                Section {
                    libraryRow
                } footer: {
                    if trimmedQuery.isEmpty {
                        Text("Pick a playlist to sort songs from, or use your full library.")
                    }
                }
            }

            if !rows.isEmpty {
                Section {
                    ForEach(rows, id: \.id) { playlist in
                        playlistRow(playlist)
                    }
                } header: {
                    sortHeader("Playlists")
                }
            } else if !trimmedQuery.isEmpty {
                noMatchesRow
            }
        }
    }

    private var artistsList: some View {
        let rows = visibleArtists
        return List {
            if showsAllLibraryRow {
                Section {
                    libraryRow
                } footer: {
                    if trimmedQuery.isEmpty {
                        Text("Pick an artist to swipe through their tracks in your library.")
                    }
                }
            }

            if (isLoadingArtists && libraryArtists.isEmpty) || isAwaitingFirstCounts {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            } else if !rows.isEmpty {
                Section {
                    ForEach(rows, id: \.id) { artist in
                        artistRow(artist)
                    }
                } header: {
                    sortHeader("Artists", showsSpinner: isLoadingCounts && artistTrackCounts.isEmpty)
                }
            } else if !trimmedQuery.isEmpty {
                noMatchesRow
            }
        }
        .task {
            // Disk-cached counts MUST land before `libraryArtists`, otherwise
            // the first list render sorts with every count treated as 0 (ties
            // broken arbitrarily) and the user sees the deck snap into its
            // real order a frame later. Disk read is a single small file —
            // fast enough that the ProgressView still covers the wait.
            await hydrateArtistCountsFromDisk()
            await loadArtistsIfNeeded()
            await refreshArtistCountsIfStale()
        }
    }

    private var noMatchesRow: some View {
        Section {
            ContentUnavailableView.search(text: trimmedQuery)
                .listRowBackground(Color.clear)
        }
    }

    /// True on the first-ever open of the picker, while the network walk that
    /// produces the initial counts is still in flight. Holds the artist list
    /// back so the user doesn't see a count-sorted list snap into its final
    /// order. Once the walk finishes (success OR failure) `attemptedArtistIDs`
    /// is populated and the gate drops; on failure the list renders without
    /// real counts, which is stable even if not ideally sorted.
    private var isAwaitingFirstCounts: Bool {
        attemptedArtistIDs.isEmpty && isLoadingCounts
    }

    private func loadArtistsIfNeeded() async {
        guard libraryArtists.isEmpty, !isLoadingArtists else { return }
        isLoadingArtists = true
        defer { isLoadingArtists = false }
        do {
            // Sort happens in `filteredSortedArtists` based on user prefs —
            // just hold the unordered list here.
            libraryArtists = try await MusicLibraryService.shared.refreshLibraryArtists()
        } catch {
            print("SourceScopePickerSheet.loadArtists failed: \(error)")
        }
    }

    /// Loads any prior count snapshot from disk before the artist list lands,
    /// so the first sort pass already has real numbers to compare. Split off
    /// from the network refresh so the `.task` can run it ahead of
    /// `loadArtistsIfNeeded` — the order matters for visual stability.
    private func hydrateArtistCountsFromDisk() async {
        guard artistTrackCounts.isEmpty && attemptedArtistIDs.isEmpty else { return }
        let disk = await Task.detached(priority: .userInitiated) {
            MembershipIndex.diskArtistCountsSnapshot()
        }.value
        artistTrackCounts = disk.counts
        attemptedArtistIDs = Set(disk.attemptedIDs)
    }

    /// Refetch only when the disk snapshot doesn't cover every current
    /// library artist. "Covered" = we tried to count them, even if the
    /// attempt came back as nil (uploaded tracks, fuzzy metadata, etc.).
    /// Previously this used `counts.count < libraryArtists.count`, which
    /// ALWAYS fired because nil-result artists are omitted from `counts` —
    /// defeating the cache and re-walking the library every picker open.
    /// On success, persists both the counts AND the attempted-IDs list so
    /// subsequent opens skip the fetch entirely.
    private func refreshArtistCountsIfStale() async {
        let currentIDs = Set(libraryArtists.map { $0.id.rawValue })
        let needsRefresh = !currentIDs.isSubset(of: attemptedArtistIDs)

        guard needsRefresh, !isLoadingCounts else { return }
        isLoadingCounts = true
        defer { isLoadingCounts = false }
        do {
            // Pass our already-loaded artist list so the service skips a second
            // full library walk. loadArtistsIfNeeded ran first; libraryArtists
            // is the fresh result of that fetch.
            let fresh = try await MusicLibraryService.shared.fetchAllArtistTrackCounts(
                artists: libraryArtists
            )
            artistTrackCounts = fresh.counts
            attemptedArtistIDs = Set(fresh.attemptedIDs)
            MembershipIndex.writeArtistCounts(fresh)
        } catch {
            print("SourceScopePickerSheet.loadArtistCounts failed: \(error)")
        }
    }

    // MARK: - Rows

    /// Trailing "this is the active scope" checkmark. Only laid out when the
    /// row is selected — an `opacity(0)` checkmark still reserves its width,
    /// which pushed the track-count badge left and left a dead gap to its
    /// right on every unselected row. Tapping a row dismisses the sheet, so
    /// `isSelected` never flips while visible and no insertion animation is lost.
    @ViewBuilder
    private func selectionCheckmark(_ isSelected: Bool) -> some View {
        if isSelected {
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .font(.body.weight(.semibold))
        }
    }

    private var libraryRow: some View {
        let isSelected = selectedScope == nil
        return Button {
            onPick(nil)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 44, height: 44)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 8))

                Text("All Library")
                    .foregroundStyle(.primary)

                Spacer()

                selectionCheckmark(isSelected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Track count to show, or nil to omit the badge. Editable playlists are
    /// always walked, so a missing key means a true zero. Read-only playlists
    /// aren't in the membership index, so we'd rather show nothing than lie
    /// with "0".
    private func displayCount(for playlist: Playlist) -> Int? {
        guard let amID = playlist.appleMusicPlaylistID else { return nil }
        if let count = trackCounts[amID] { return count }
        return playlist.isEditable ? 0 : nil
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        let isSelected: Bool = {
            guard case .playlist(let id, _, _) = selectedScope else { return false }
            return id == playlist.appleMusicPlaylistID
        }()
        return Button {
            guard let amID = playlist.appleMusicPlaylistID else { return }
            onPick(.playlist(id: amID, name: playlist.name, isEditable: playlist.isEditable))
            dismiss()
        } label: {
            HStack(spacing: 12) {
                PlaylistCoverView(appleMusicPlaylistID: playlist.appleMusicPlaylistID)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .foregroundStyle(.primary)
                    if !playlist.isEditable {
                        Text("Read-only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let count = displayCount(for: playlist) {
                    Text(count, format: .number)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                selectionCheckmark(isSelected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func artistRow(_ artist: Artist) -> some View {
        let isSelected: Bool = {
            guard case .artist(let id, _) = selectedScope else { return false }
            return id == artist.id.rawValue
        }()
        return Button {
            onPick(.artist(id: artist.id.rawValue, name: artist.name))
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Group {
                    if let artwork = artist.artwork {
                        ArtworkImage(artwork, width: 44, height: 44)
                    } else {
                        ArtistPlaceholder(name: artist.name, size: 44)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())

                Text(artist.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                if let count = artistTrackCounts[artist.id.rawValue] {
                    Text(count, format: .number)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                selectionCheckmark(isSelected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sort fields

/// Underlying sort field — persisted via `@AppStorage` as a string. The
/// concrete-choice enums (`PlaylistSortChoice`, `ArtistSortChoice`) layer
/// direction on top so the menu can render one flat list per tab.
enum PlaylistSortField: String, CaseIterable {
    case alphabetical
    case modifiedDate
    case trackCount
}

enum ArtistSortField: String, CaseIterable {
    case alphabetical
    case trackCount
}

// MARK: - Concrete sort choices

/// Every (field, direction) pair the playlist tab supports, in menu order.
/// Lets the Menu render one flat list of human-readable options instead of
/// two stacked Pickers ("Sort By" + "Sort Order").
enum PlaylistSortChoice: String, CaseIterable, Identifiable, SortChoiceProtocol {
    case nameAsc
    case nameDesc
    case dateDesc
    case dateAsc
    case countDesc
    case countAsc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nameAsc:   "Name (A→Z)"
        case .nameDesc:  "Name (Z→A)"
        case .dateDesc:  "Recently Modified"
        case .dateAsc:   "Oldest First"
        case .countDesc: "Most Songs"
        case .countAsc:  "Fewest Songs"
        }
    }

    var field: PlaylistSortField {
        switch self {
        case .nameAsc, .nameDesc:   .alphabetical
        case .dateDesc, .dateAsc:   .modifiedDate
        case .countDesc, .countAsc: .trackCount
        }
    }

    var descending: Bool {
        switch self {
        case .nameDesc, .dateDesc, .countDesc: true
        case .nameAsc, .dateAsc, .countAsc:    false
        }
    }

    init(field: PlaylistSortField, descending: Bool) {
        switch (field, descending) {
        case (.alphabetical, false): self = .nameAsc
        case (.alphabetical, true):  self = .nameDesc
        case (.modifiedDate, true):  self = .dateDesc
        case (.modifiedDate, false): self = .dateAsc
        case (.trackCount, true):    self = .countDesc
        case (.trackCount, false):   self = .countAsc
        }
    }
}

enum ArtistSortChoice: String, CaseIterable, Identifiable, SortChoiceProtocol {
    case nameAsc
    case nameDesc
    case countDesc
    case countAsc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nameAsc:   "Name (A→Z)"
        case .nameDesc:  "Name (Z→A)"
        case .countDesc: "Most Songs"
        case .countAsc:  "Fewest Songs"
        }
    }

    var field: ArtistSortField {
        switch self {
        case .nameAsc, .nameDesc:   .alphabetical
        case .countDesc, .countAsc: .trackCount
        }
    }

    var descending: Bool {
        switch self {
        case .nameDesc, .countDesc: true
        case .nameAsc, .countAsc:   false
        }
    }

    init(field: ArtistSortField, descending: Bool) {
        switch (field, descending) {
        case (.alphabetical, false): self = .nameAsc
        case (.alphabetical, true):  self = .nameDesc
        case (.trackCount, true):    self = .countDesc
        case (.trackCount, false):   self = .countAsc
        }
    }
}

// MARK: - ArtistPlaceholder

/// Fallback artwork for library artists whose `.artwork` is nil — Apple only
/// attaches artist images to library entries matched against the catalog, so
/// upload-only or obscure artists land here. Renders a colored circle with the
/// artist's initial; the hue is hashed from the name so the same artist gets
/// the same color across launches.
struct ArtistPlaceholder: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    private var color: Color {
        // djb2 hash → hue. Saturation/brightness fixed for a coherent palette
        // across the artist list.
        var hash: UInt64 = 5381
        for scalar in name.unicodeScalars {
            hash = hash &* 33 &+ UInt64(scalar.value)
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.5, brightness: 0.72)
    }
}
