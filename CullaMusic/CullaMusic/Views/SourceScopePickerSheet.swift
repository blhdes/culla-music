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
    /// disk snapshot is empty.
    @State private var artistTrackCounts: [String: Int] = [:]
    @State private var isLoadingCounts: Bool = false
    @State private var pickerMode: PickerMode = .playlists
    @State private var searchQuery: String = ""

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
                .padding(.vertical, 10)

                listBody
            }
            .navigationTitle("Sort From")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .automatic))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    sortMenu
                }
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
            }
        }
    }

    // MARK: - Sort menu

    private var sortMenu: some View {
        Menu {
            switch pickerMode {
            case .playlists:
                Picker("Sort By", selection: playlistSortFieldBinding) {
                    ForEach(PlaylistSortField.allCases, id: \.rawValue) { field in
                        Text(field.label).tag(field)
                    }
                }
                Picker("Sort Order", selection: $playlistSortDescending) {
                    Text(playlistDirectionLabel(descending: false)).tag(false)
                    Text(playlistDirectionLabel(descending: true)).tag(true)
                }
            case .artists:
                Picker("Sort By", selection: artistSortFieldBinding) {
                    ForEach(ArtistSortField.allCases, id: \.rawValue) { field in
                        Text(field.label).tag(field)
                    }
                }
                Picker("Sort Order", selection: $artistSortDescending) {
                    Text(artistDirectionLabel(descending: false)).tag(false)
                    Text(artistDirectionLabel(descending: true)).tag(true)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    /// Direction labels are field-aware: "Ascending / Descending" feels wrong
    /// for "Number of Songs" — users think "Most / Fewest" there. Same trick
    /// for dates ("Recent / Oldest").
    private func playlistDirectionLabel(descending: Bool) -> String {
        let field = PlaylistSortField(rawValue: playlistSortFieldRaw) ?? .alphabetical
        switch field {
        case .alphabetical: return descending ? "Z to A" : "A to Z"
        case .modifiedDate: return descending ? "Recent First" : "Oldest First"
        case .trackCount:   return descending ? "Most First" : "Fewest First"
        }
    }

    private func artistDirectionLabel(descending: Bool) -> String {
        let field = ArtistSortField(rawValue: artistSortFieldRaw) ?? .alphabetical
        switch field {
        case .alphabetical: return descending ? "Z to A" : "A to Z"
        case .trackCount:   return descending ? "Most First" : "Fewest First"
        }
    }

    /// Custom binding so switching sort fields auto-resets direction to that
    /// field's "natural" default (A-Z; Most/Recent first). Users can flip from
    /// there independently and the choice sticks via AppStorage.
    private var playlistSortFieldBinding: Binding<PlaylistSortField> {
        Binding(
            get: { PlaylistSortField(rawValue: playlistSortFieldRaw) ?? .alphabetical },
            set: { newField in
                let oldField = PlaylistSortField(rawValue: playlistSortFieldRaw) ?? .alphabetical
                playlistSortFieldRaw = newField.rawValue
                if oldField != newField {
                    playlistSortDescending = newField.defaultDescending
                }
            }
        )
    }

    private var artistSortFieldBinding: Binding<ArtistSortField> {
        Binding(
            get: { ArtistSortField(rawValue: artistSortFieldRaw) ?? .alphabetical },
            set: { newField in
                let oldField = ArtistSortField(rawValue: artistSortFieldRaw) ?? .alphabetical
                artistSortFieldRaw = newField.rawValue
                if oldField != newField {
                    artistSortDescending = newField.defaultDescending
                }
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

    private var filteredSortedPlaylists: [Playlist] {
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
        return rows
    }

    private var filteredSortedArtists: [Artist] {
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
        let rows = filteredSortedPlaylists
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
                Section("Playlists") {
                    ForEach(rows, id: \.id) { playlist in
                        playlistRow(playlist)
                    }
                }
            } else if !trimmedQuery.isEmpty {
                noMatchesRow
            }
        }
    }

    private var artistsList: some View {
        let rows = filteredSortedArtists
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

            if isLoadingArtists && libraryArtists.isEmpty {
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
                    HStack {
                        Text("Artists")
                        Spacer()
                        if isLoadingCounts && artistTrackCounts.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
            } else if !trimmedQuery.isEmpty {
                noMatchesRow
            }
        }
        .task {
            await loadArtistsIfNeeded()
            await loadArtistCountsIfNeeded()
        }
    }

    private var noMatchesRow: some View {
        Section {
            ContentUnavailableView.search(text: trimmedQuery)
                .listRowBackground(Color.clear)
        }
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

    /// Hydrates `artistTrackCounts` from disk first (instant render of any
    /// prior snapshot), then fires a fresh parallel batch if the snapshot is
    /// missing or stale. On success, persists the snapshot so subsequent opens
    /// skip the fetch.
    private func loadArtistCountsIfNeeded() async {
        if artistTrackCounts.isEmpty {
            let disk = await Task.detached(priority: .userInitiated) {
                MembershipIndex.diskArtistCountsSnapshot()
            }.value
            if !disk.isEmpty {
                artistTrackCounts = disk
            }
        }

        // Re-fetch when the snapshot looks stale: smaller than the current
        // artist list (older builds capped this at 100 before pagination
        // landed), or carrying 0-valued entries from before we started
        // dropping unknown counts. After one clean fetch neither condition
        // holds, so steady-state picker opens stay fast.
        let needsRefresh = artistTrackCounts.isEmpty
            || artistTrackCounts.count < libraryArtists.count
            || artistTrackCounts.values.contains(0)

        guard needsRefresh, !isLoadingCounts else { return }
        isLoadingCounts = true
        defer { isLoadingCounts = false }
        do {
            let fresh = try await MusicLibraryService.shared.fetchAllArtistTrackCounts()
            artistTrackCounts = fresh
            MembershipIndex.writeArtistCounts(fresh)
        } catch {
            print("SourceScopePickerSheet.loadArtistCounts failed: \(error)")
        }
    }

    // MARK: - Rows

    private var libraryRow: some View {
        let isSelected = selectedScope == nil
        return Button {
            onPick(nil)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: "music.note.list")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    )
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Text("All Library")
                    .foregroundStyle(.primary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Track count to show, or nil to omit the badge. Editable playlists are
    /// always walked, so a missing key means a true zero. Read-only playlists
    /// may be skipped when the curated toggle is off — in that case we'd rather
    /// show nothing than lie with "0".
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

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .font(.body.weight(.semibold))
                }
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

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sort fields

enum PlaylistSortField: String, CaseIterable {
    case alphabetical
    case modifiedDate
    case trackCount

    var label: String {
        switch self {
        case .alphabetical: "Name"
        case .modifiedDate: "Recently Modified"
        case .trackCount:   "Number of Songs"
        }
    }

    /// Direction picked automatically when the user switches to this field.
    /// Alphabetical wants A→Z; date/count fields read more naturally biggest-
    /// first ("Recent / Most"), so they default descending.
    var defaultDescending: Bool {
        switch self {
        case .alphabetical: false
        case .modifiedDate: true
        case .trackCount:   true
        }
    }
}

enum ArtistSortField: String, CaseIterable {
    case alphabetical
    case trackCount

    var label: String {
        switch self {
        case .alphabetical: "Name"
        case .trackCount:   "Number of Songs"
        }
    }

    var defaultDescending: Bool {
        switch self {
        case .alphabetical: false
        case .trackCount:   true
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
