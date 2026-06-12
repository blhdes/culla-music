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
    /// Shared artist list + per-artist count cache. Owns the load/hydrate/refresh
    /// logic that the Playlists manager's artist filter reuses too.
    @State private var artistStore = ArtistLibraryStore()
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
        var label: String {
            self == .playlists ? String(localized: "Playlists") : String(localized: "Artists")
        }
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
                // Hug the search bar above it. The search field sits in the
                // nav-bar drawer; the only gap we control here is the picker's
                // top inset, so keep it small so the toggle reads as part of
                // the same header block instead of a floating control.
                // Mirrors `ManagePlaylistsSheet` so the two pickers stay
                // structurally identical.
                .padding(.top, 4)
                .padding(.bottom, 6)

                listBody
                    // Soft scroll edge so rows diffuse under the segmented
                    // header / search bar instead of a hard cut (iOS 26).
                    .softScrollEdge()
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
            .onChange(of: artistStore.artists) { _, _ in
                visibleArtists = computeFilteredSortedArtists()
            }
            .onChange(of: artistStore.trackCounts) { _, _ in
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
        case .playlists: SortChip(field: playlistSortFieldBinding, descending: $playlistSortDescending)
        case .artists:   SortChip(field: artistSortFieldBinding, descending: $artistSortDescending)
        }
    }

    /// Section header carrying the per-tab sort menu at its trailing edge.
    /// Anchoring the menu here — directly above the rows it reorders — replaces
    /// the old floating chip that sat in a detached band under the segmented
    /// control. `showsSpinner` surfaces the artist-count backfill inline.
    private func sortHeader(_ title: LocalizedStringKey, showsSpinner: Bool = false) -> some View {
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

    /// Bridges the raw-string `@AppStorage` field to the typed enum the chip
    /// wants; the sibling `…Descending` bool is bound directly. Storage is
    /// unchanged — already (field, direction), so no migration here.
    private var playlistSortFieldBinding: Binding<PlaylistSortField> {
        Binding(
            get: { PlaylistSortField(rawValue: playlistSortFieldRaw) ?? .alphabetical },
            set: { playlistSortFieldRaw = $0.rawValue }
        )
    }

    private var artistSortFieldBinding: Binding<ArtistSortField> {
        Binding(
            get: { ArtistSortField(rawValue: artistSortFieldRaw) ?? .alphabetical },
            set: { artistSortFieldRaw = $0.rawValue }
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
        return String(localized: "All Library").localizedStandardContains(trimmedQuery)
    }

    private func computeFilteredSortedPlaylists() -> [Playlist] {
        let field = PlaylistSortField(rawValue: playlistSortFieldRaw) ?? .alphabetical
        var rows = playlists
        if !trimmedQuery.isEmpty {
            rows = rows.filter { $0.name.localizedStandardContains(trimmedQuery) }
        }
        rows = rows.sortedBy(field: field, descending: playlistSortDescending) {
            ($0.appleMusicPlaylistID.flatMap { trackCounts[$0] }) ?? 0
        }
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
        var rows = artistStore.artists
        if !trimmedQuery.isEmpty {
            rows = rows.filter { $0.name.localizedStandardContains(trimmedQuery) }
        }
        rows.sort { lhs, rhs in
            switch field {
            case .alphabetical:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .trackCount:
                let l = artistStore.trackCounts[lhs.id.rawValue] ?? 0
                let r = artistStore.trackCounts[rhs.id.rawValue] ?? 0
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

            if (artistStore.isLoadingArtists && artistStore.artists.isEmpty) || artistStore.isAwaitingFirstCounts {
                Section {
                    SkeletonRows(count: 8, lead: .circle, leadSize: 44, subtitle: false, showsTrailing: true)
                }
            } else if !rows.isEmpty {
                Section {
                    ForEach(rows, id: \.id) { artist in
                        artistRow(artist)
                    }
                } header: {
                    sortHeader("Artists", showsSpinner: artistStore.isLoadingCounts && artistStore.trackCounts.isEmpty)
                }
            } else if !trimmedQuery.isEmpty {
                noMatchesRow
            }
        }
        .task {
            // The store runs disk-hydrate → list-load → stale-refresh in the
            // order that keeps the first sort stable (counts before the list,
            // so it doesn't snap into its real order a frame later).
            await artistStore.prime()
        }
    }

    private var noMatchesRow: some View {
        Section {
            ContentUnavailableView.search(text: trimmedQuery)
                .listRowBackground(Color.clear)
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

                if let count = artistStore.trackCounts[artist.id.rawValue] {
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

/// Underlying sort field — persisted via `@AppStorage` as a string, with a
/// sibling `…Descending` bool for direction. The `SortChip` lists these fields
/// once and flips the bool when you re-pick the active one.
enum PlaylistSortField: String, CaseIterable, Identifiable, SortFieldProtocol {
    case alphabetical
    case modifiedDate
    case trackCount

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alphabetical: String(localized: "Name")
        case .modifiedDate: String(localized: "Date Modified")
        case .trackCount:   String(localized: "Song Count")
        }
    }

    var defaultDescending: Bool? {
        switch self {
        case .alphabetical: false  // A→Z
        case .modifiedDate: true   // newest first
        case .trackCount:   true   // most first
        }
    }
}

enum ArtistSortField: String, CaseIterable, Identifiable, SortFieldProtocol {
    case alphabetical
    case trackCount

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alphabetical: String(localized: "Name")
        case .trackCount:   String(localized: "Song Count")
        }
    }

    var defaultDescending: Bool? {
        switch self {
        case .alphabetical: false  // A→Z
        case .trackCount:   true   // most first
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
