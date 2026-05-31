import SwiftUI
import MusicKit

/// Two-segment "Playlists" sheet:
///   • **Sidebar** — which playlists appear in the right-swipe sidebar
///     (capped to `MusicSwipeViewModel.maxSidebar`). The original behavior.
///   • **Filter queue** — what disappears from a `.library` swipe session.
///     Splits into two combinable sub-tabs, both consumed by
///     `MusicLibraryService.deckExclusionSet`:
///       – **Playlists** (`QueueFilterStore`) — lenient: a song hides only when
///         *every* playlist it belongs to is selected, so excluding one never
///         silently culls cross-listed tracks.
///       – **Artists** (`QueueFilterStore` artist key) — hard: any library
///         track crediting a selected artist is hidden outright.
///     The two unite, so each independently removes its matches.
struct ManagePlaylistsSheet: View {
    @Bindable var viewModel: MusicSwipeViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent
    @State private var showCreate = false
    @State private var segment: Segment = .sidebar
    /// Shared artist list + per-artist count cache for the Artists filter
    /// sub-tab. Same store the Sort-From picker uses, primed lazily the first
    /// time the user opens the sub-tab.
    @State private var artistStore = ArtistLibraryStore()
    @State private var searchQuery = ""
    /// Memoized filter+sort of the artist list — recomputed only when an input
    /// changes (search, sort, store data), not per render, so typing doesn't
    /// re-sort 500+ artists on every keystroke.
    @State private var visibleArtists: [Artist] = []

    /// The playlist a swipe-to-rename is targeting. Non-nil drives the rename
    /// alert; `renameText` holds the in-flight edited name (seeded from the
    /// playlist's current name when the swipe action fires).
    @State private var renameTarget: Playlist?
    @State private var renameText: String = ""

    /// The up-swipe loved target. Hidden from the sidebar list below since the
    /// up-swipe already covers that playlist and double-listing it implies a
    /// toggle that wouldn't add anything. Configured in Settings.
    @AppStorage("lovedPlaylistID") private var lovedPlaylistID: String = ""

    /// Comma-joined `appleMusicPlaylistID`s of playlists whose tracks should be
    /// hidden from `.library` sessions. The raw string lives in `@AppStorage`
    /// so the sheet, the service, and any future settings surface all stay in
    /// lockstep without a custom store. See `QueueFilterStore`.
    @AppStorage(QueueFilterStore.defaultsKey) private var rawExcluded: String = ""

    /// Comma-joined artist IDs whose tracks are hidden from `.library` sessions.
    /// Sibling of `rawExcluded`; consumed by the same `deckExclusionSet`. Hard
    /// exclude (any track by the artist), unlike the playlist filter's lenient
    /// rule. See `QueueFilterStore.readArtists`.
    @AppStorage(QueueFilterStore.artistDefaultsKey) private var rawExcludedArtists: String = ""

    // Each segment persists its own sort as a (field, direction) pair so sorting
    // one doesn't reshuffle the other. Sidebar defaults to its real displayOrder;
    // queue filters to Name A→Z. `SortPreferenceMigration` carries the old
    // combined keys ("nameAsc", …) into these on first launch.
    @AppStorage("managePlaylists.sidebarSortField") private var sidebarSortFieldRaw = SidebarSortField.sidebarOrder.rawValue
    @AppStorage("managePlaylists.sidebarSortDescending") private var sidebarSortDescending = false
    @AppStorage("managePlaylists.filterSortField") private var filterSortFieldRaw = PlaylistSortField.alphabetical.rawValue
    @AppStorage("managePlaylists.filterSortDescending") private var filterSortDescending = false
    @AppStorage("managePlaylists.artistFilterSortField") private var artistFilterSortFieldRaw = ArtistSortField.alphabetical.rawValue
    @AppStorage("managePlaylists.artistFilterSortDescending") private var artistFilterSortDescending = false
    /// Which list the Filter queue shows — playlists or artists. Persisted so
    /// re-opening the sheet keeps the user on their last sub-tab.
    @AppStorage("managePlaylists.filterScope") private var filterScopeRaw = FilterScope.playlists.rawValue

    enum Segment: String, CaseIterable, Identifiable {
        case sidebar
        case filter
        var id: String { rawValue }
        var label: String {
            switch self {
            case .sidebar: "Sidebar"
            case .filter:  "Filter queue"
            }
        }
    }

    /// The Filter queue's two sub-tabs. Mirrors the Sort-From picker's
    /// `[Playlists | Artists]` vocabulary so the two sheets read as one family.
    enum FilterScope: String, CaseIterable, Identifiable {
        case playlists
        case artists
        var id: String { rawValue }
        var label: String { self == .playlists ? "Playlists" : "Artists" }
        var icon: String { self == .playlists ? "music.note.list" : "music.mic" }
    }

    private var filterScope: Binding<FilterScope> {
        Binding(
            get: { FilterScope(rawValue: filterScopeRaw) ?? .playlists },
            set: { filterScopeRaw = $0.rawValue }
        )
    }

    private var maxSidebar: Int { MusicSwipeViewModel.maxSidebar }

    private var editablePlaylists: [Playlist] {
        viewModel.playlists.filter { playlist in
            guard playlist.isEditable else { return false }
            if !lovedPlaylistID.isEmpty,
               playlist.appleMusicPlaylistID == lovedPlaylistID {
                return false
            }
            return true
        }
    }

    /// Every known playlist, surfaced for the filter list. Apple-generated
    /// playlists (Heavy Rotation Mix, replay, personal mixes) stay in —
    /// excluding them is a legitimate power-user move. Ordering is applied by
    /// the user's sort choice (`sortedFilterablePlaylists`), not here.
    private var filterablePlaylists: [Playlist] {
        viewModel.playlists.filter { $0.appleMusicPlaylistID != nil }
    }

    private var excludedSet: Set<String> { QueueFilterStore.decode(rawExcluded) }
    private var excludedArtistSet: Set<String> { QueueFilterStore.decode(rawExcludedArtists) }

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Applies the shared search box to a playlist list. No-op when the query is
    /// empty so the sorted order is untouched.
    private func searchFiltered(_ playlists: [Playlist]) -> [Playlist] {
        guard !trimmedQuery.isEmpty else { return playlists }
        return playlists.filter { $0.name.localizedStandardContains(trimmedQuery) }
    }

    // MARK: - Sorting

    private var sidebarSortField: Binding<SidebarSortField> {
        Binding(
            get: { SidebarSortField(rawValue: sidebarSortFieldRaw) ?? .sidebarOrder },
            set: { sidebarSortFieldRaw = $0.rawValue }
        )
    }

    private var filterSortField: Binding<PlaylistSortField> {
        Binding(
            get: { PlaylistSortField(rawValue: filterSortFieldRaw) ?? .alphabetical },
            set: { filterSortFieldRaw = $0.rawValue }
        )
    }

    private var artistFilterSortField: Binding<ArtistSortField> {
        Binding(
            get: { ArtistSortField(rawValue: artistFilterSortFieldRaw) ?? .alphabetical },
            set: { artistFilterSortFieldRaw = $0.rawValue }
        )
    }

    private var sortedEditablePlaylists: [Playlist] {
        searchFiltered(sorted(editablePlaylists,
                              field: sidebarSortField.wrappedValue.playlistField,
                              descending: sidebarSortDescending))
    }

    private var sortedFilterablePlaylists: [Playlist] {
        searchFiltered(sorted(filterablePlaylists,
                              field: filterSortField.wrappedValue,
                              descending: filterSortDescending))
    }

    /// Search + sort for the artist filter list. Mirrors the Sort-From picker's
    /// artist sort (alphabetical / track count) so both browse identically.
    private func computeFilteredSortedArtists() -> [Artist] {
        let field = artistFilterSortField.wrappedValue
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
        if artistFilterSortDescending { rows.reverse() }
        return rows
    }

    /// Orders a list by a sort field via the shared `sortedBy` helper, injecting
    /// counts from the live `membershipIndex`. A `nil` field means "keep the
    /// source order" — for the sidebar that's the real displayOrder, since
    /// `viewModel.playlists` already arrives sorted by it.
    private func sorted(_ playlists: [Playlist], field: PlaylistSortField?, descending: Bool) -> [Playlist] {
        playlists.sortedBy(field: field, descending: descending) {
            viewModel.membershipIndex.trackCount(forPlaylistAMID: $0.appleMusicPlaylistID) ?? 0
        }
    }

    private var isAtCapacity: Bool {
        !viewModel.canAddToSidebar && !editablePlaylists.isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Animated binding centralizes the segment-change animation in
                // one place — previously three contexts (picker, inner VStack,
                // toolbar) drove it at once and produced visible flicker.
                Picker("Section", selection: $segment.animation(.easeInOut(duration: 0.22))) {
                    ForEach(Segment.allCases) { seg in
                        Text(seg.label).tag(seg)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)

                // The Filter queue's Playlists/Artists split no longer rides a
                // second segmented control here — switching scope now lives in
                // the list's section header (`filterScopeChip`), so the sheet
                // never stacks two pickers and the filter stops reading as a
                // bolted-on sub-sheet.

                // Plain grouped List — same presentation as `SourceScopePickerSheet`
                // so the two playlist pickers read as one UI form. No mesh, no
                // material slabs, no custom borders: the List owns every surface.
                // That stack of hand-built surfaces (mesh + `.thinMaterial` slab +
                // stroke) is exactly what flickered on segment switches and over
                // the animated background; one List has none of it.
                List {
                    sections
                }
            }
            .navigationTitle("Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .automatic))
            // Seed + keep the memoized artist list in sync. Same explicit-trigger
            // approach as the Sort-From picker: recompute only on real input
            // changes, never per body render.
            .onAppear { visibleArtists = computeFilteredSortedArtists() }
            .onChange(of: searchQuery) { _, _ in visibleArtists = computeFilteredSortedArtists() }
            .onChange(of: artistFilterSortFieldRaw) { _, _ in visibleArtists = computeFilteredSortedArtists() }
            .onChange(of: artistFilterSortDescending) { _, _ in visibleArtists = computeFilteredSortedArtists() }
            .onChange(of: artistStore.artists) { _, _ in visibleArtists = computeFilteredSortedArtists() }
            .onChange(of: artistStore.trackCounts) { _, _ in visibleArtists = computeFilteredSortedArtists() }
            .toolbar {
                // Create is available in both segments — a new playlist is just
                // as valid a queue-filter target as a sidebar one. The slot is
                // always present (never conditionally inserted) so switching
                // segments doesn't trigger a NavigationStack reflow into the
                // ZStack below.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel("New playlist")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showCreate) {
                NewPlaylistSheet { name in
                    Task {
                        await viewModel.createPlaylist(
                            name: name,
                            addToSidebar: viewModel.canAddToSidebar
                        )
                    }
                }
            }
            // Native rename alert — the standard iOS rename idiom (Files, Notes).
            // The text field is seeded with the current name by the swipe action;
            // an empty/unchanged name no-ops inside `renamePlaylist`.
            .alert("Rename Playlist", isPresented: renameAlertPresented) {
                TextField("Playlist name", text: $renameText)
                    .textInputAutocapitalization(.words)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    guard let target = renameTarget else { return }
                    let newName = renameText
                    Task { await viewModel.renamePlaylist(target, to: newName) }
                }
            }
        }
    }

    /// Swaps the active segment's section inside one stable `List`. Switching
    /// the section (rather than swapping two whole `List`s) keeps the list
    /// mounted, so a segment change is a content crossfade, not a teardown.
    @ViewBuilder
    private var sections: some View {
        switch segment {
        case .sidebar:
            sidebarSection
        case .filter:
            switch filterScope.wrappedValue {
            case .playlists: filterSection
            case .artists:   artistFilterSection
            }
        }
    }

    // MARK: - Sidebar segment

    /// Sidebar list: the count summary + `SortChip` ride in the section header,
    /// the capacity note in the footer, and rows are plain list rows. Mirrors
    /// `SourceScopePickerSheet`'s header/footer/rows shape exactly.
    private var sidebarSection: some View {
        Section {
            if editablePlaylists.isEmpty {
                emptyRow(
                    title: "No playlists yet",
                    detail: "Tap + to create your first one.",
                    icon: "music.note.list"
                )
            } else if sortedEditablePlaylists.isEmpty {
                noMatchesRow
            } else {
                ForEach(sortedEditablePlaylists, id: \.id) { playlist in
                    sidebarRow(for: playlist)
                }
            }
        } header: {
            sortHeader(
                "\(viewModel.sidebarCount) of \(maxSidebar) in your sidebar",
                field: sidebarSortField,
                descending: $sidebarSortDescending,
                showsChip: !editablePlaylists.isEmpty,
                countValue: viewModel.sidebarCount
            )
        } footer: {
            if isAtCapacity {
                Text("Sidebar full — turn one off to add another.")
            }
        }
    }

    @ViewBuilder
    private func sidebarRow(for playlist: Playlist) -> some View {
        let isOn = playlist.isInSidebar
        let canEnable = viewModel.canAddToSidebar
        let isTappable = isOn || canEnable

        // Sidebar shows only editable playlists, so a nil from the index
        // means "truly empty playlist" — keep the "0" rendering by passing
        // `countShownWhenNil: true`.
        //
        // We deliberately avoid wrapping the row in a `Button`. On iOS 26
        // the system applies a Liquid Glass press highlight to every Button
        // when iOS thinks a touch *might* be a tap — including the moment
        // before a scroll gesture is recognized. That highlight is rendered
        // at the compositor layer (so it never shows up in screenshots or
        // screen recordings) and flashes across each row your finger passes
        // over during a scroll. `.buttonStyle(.plain)` doesn't suppress it.
        // Using `.onTapGesture` on a plain HStack avoids the system button
        // path entirely, so no glass press shape appears. Accessibility is
        // restored manually with `.isButton` + `.accessibilityAction`.
        rowContent(
            playlist: playlist,
            isOn: isOn,
            countShownWhenNil: true
        )
        .opacity(isTappable ? 1.0 : 0.4)
        .animation(.snappy(duration: 0.22), value: isOn)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isTappable else { return }
            if isOn {
                viewModel.setSidebar(playlist, included: false)
            } else if canEnable {
                viewModel.setSidebar(playlist, included: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(playlist.name)
        .accessibilityValue(isOn ? "In sidebar" : "Not in sidebar")
        .accessibilityHint(isTappable ? "Toggles sidebar membership" : "Sidebar is full")
        // Swipe left to rename — but only on playlists Culla created. Apple's
        // `edit` API rejects every other library playlist, so gating to
        // `createdByApp` means the swipe reveals nothing (a clean no-op) on
        // imported / Apple Music playlists instead of offering a doomed action.
        // `allowsFullSwipe: false`: rename needs the name field, so a long swipe
        // shouldn't commit on its own — the user taps the revealed button.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if playlist.createdByApp {
                Button {
                    renameText = playlist.name
                    renameTarget = playlist
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(appAccent)
            }
        }
    }

    /// Drives the rename alert off `renameTarget`: presented while a target is
    /// set, dismissed (target cleared) when the alert closes.
    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    // MARK: - Filter segment

    /// Filter list: structurally identical to `sidebarSection` — count + chip in
    /// the header, the library-mode reminder in the footer, rows below.
    private var filterSection: some View {
        let count = excludedSet.count
        return Section {
            if filterablePlaylists.isEmpty {
                emptyRow(
                    title: "No playlists to filter",
                    detail: "Once you have playlists in your library, you can hide their tracks here.",
                    icon: "line.3.horizontal.decrease.circle"
                )
            } else if sortedFilterablePlaylists.isEmpty {
                noMatchesRow
            } else {
                ForEach(sortedFilterablePlaylists, id: \.id) { playlist in
                    filterRow(for: playlist)
                }
            }
        } header: {
            filterScopeHeader(
                field: filterSortField,
                descending: $filterSortDescending,
                showsChip: !filterablePlaylists.isEmpty
            )
        } footer: {
            filterFooter(count: count, noun: "playlist")
        }
    }

    @ViewBuilder
    private func filterRow(for playlist: Playlist) -> some View {
        let amID = playlist.appleMusicPlaylistID ?? ""
        let isFiltered = !amID.isEmpty && excludedSet.contains(amID)
        let isTappable = !amID.isEmpty

        // Tap gesture instead of `Button` — see `sidebarRow` for the rationale
        // around iOS 26's compositor-rendered Liquid Glass press highlight.
        // `countShownWhenNil: false` keeps the count slot present but invisible
        // when `trackCount` returns nil (curated playlists in `.library` mode
        // skip the walk).
        rowContent(
            playlist: playlist,
            isOn: isFiltered,
            countShownWhenNil: false
        )
        .opacity(isTappable ? 1.0 : 0.4)
        .animation(.snappy(duration: 0.22), value: isFiltered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isTappable else { return }
            toggleFilter(amID: amID)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(playlist.name)
        .accessibilityValue(isFiltered ? "Filtered out" : "Visible")
        .accessibilityHint(isTappable ? "Toggles filter for this playlist" : "")
    }

    private func toggleFilter(amID: String) {
        guard !amID.isEmpty else { return }
        var set = excludedSet
        if set.contains(amID) {
            set.remove(amID)
        } else {
            set.insert(amID)
        }
        rawExcluded = QueueFilterStore.encode(set)
    }

    // MARK: - Artist filter segment

    /// Artist filter list — structurally mirrors `filterSection`. Lazily primes
    /// the shared artist store the first time the user opens this sub-tab, so we
    /// don't walk the library for artists they may never filter. Loading /
    /// empty / no-matches states match the Sort-From picker's artist tab.
    private var artistFilterSection: some View {
        let count = excludedArtistSet.count
        return Section {
            if (artistStore.isLoadingArtists && artistStore.artists.isEmpty) || artistStore.isAwaitingFirstCounts {
                loadingRow
            } else if artistStore.artists.isEmpty {
                emptyRow(
                    title: "No artists to filter",
                    detail: "Once your library has artists, you can hide their tracks here.",
                    icon: "music.mic"
                )
            } else if !visibleArtists.isEmpty {
                ForEach(visibleArtists, id: \.id) { artist in
                    artistFilterRow(for: artist)
                }
            } else if !trimmedQuery.isEmpty {
                // Only "no results" when actually searching. An empty memo with
                // no query is the one-frame gap before `onChange` reseeds it
                // after the list lands — render nothing rather than flash this.
                noMatchesRow
            }
        } header: {
            filterScopeHeader(
                field: artistFilterSortField,
                descending: $artistFilterSortDescending,
                showsChip: !artistStore.artists.isEmpty
            )
        } footer: {
            filterFooter(count: count, noun: "artist")
        }
        .task { await artistStore.prime() }
    }

    @ViewBuilder
    private func artistFilterRow(for artist: Artist) -> some View {
        let amID = artist.id.rawValue
        let isFiltered = excludedArtistSet.contains(amID)

        // Tap gesture instead of `Button` — see `sidebarRow` for the iOS 26
        // Liquid Glass press-highlight rationale.
        HStack(spacing: 12) {
            Group {
                if let artwork = artist.artwork {
                    ArtworkImage(artwork, width: 40, height: 40)
                } else {
                    ArtistPlaceholder(name: artist.name, size: 40)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())

            Text(artist.name)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            // Reserved width keeps the Spacer from twitching as counts resolve.
            // Artists with a nil count (uploaded-only, fuzzy metadata) show no
            // badge — same as the Sort-From picker.
            if let trackCount = artistStore.trackCounts[amID] {
                Text(trackCount, format: .number)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, alignment: .trailing)
            }

            Image(systemName: isFiltered ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isFiltered ? appAccent : Color.secondary.opacity(0.4))
                .font(.title3)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: isFiltered)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
        .animation(.snappy(duration: 0.22), value: isFiltered)
        .onTapGesture {
            toggleArtistFilter(amID: amID)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(artist.name)
        .accessibilityValue(isFiltered ? "Filtered out" : "Visible")
        .accessibilityHint("Toggles filter for this artist")
    }

    private func toggleArtistFilter(amID: String) {
        guard !amID.isEmpty else { return }
        var set = excludedArtistSet
        if set.contains(amID) {
            set.remove(amID)
        } else {
            set.insert(amID)
        }
        rawExcludedArtists = QueueFilterStore.encode(set)
    }

    /// Skeleton artist rows shown while the artist list / counts load — the
    /// placeholder fills the same geometry as the real rows, so the reveal
    /// reads as the list sharpening into focus instead of a spinner on empty
    /// space. Shared `SkeletonRows` keeps every sheet's loading state identical.
    private var loadingRow: some View {
        SkeletonRows(count: 8, lead: .circle, leadSize: 40, subtitle: false, showsTrailing: true)
    }

    /// Native "no results" row for the shared search box — same vocabulary as
    /// `SourceScopePickerSheet`.
    private var noMatchesRow: some View {
        ContentUnavailableView.search(text: trimmedQuery)
            .listRowBackground(Color.clear)
    }

    // MARK: - Shared row layout

    /// Single row template used by both segments. Keeping the structure
    /// identical eliminates the "padded vs plain" height mismatch the user
    /// flagged: every row is exactly one line of `.body` text + a 40pt cover.
    ///
    /// Apple-generated playlists pick up a small inline `sparkles` glyph next
    /// to the title instead of a second-line "Apple Music" subtitle, so the
    /// row height stays uniform.
    ///
    /// `countShownWhenNil` controls how a `nil` from the membership index is
    /// rendered: sidebar wants "0" (nil means truly empty), filter wants the
    /// slot present but invisible (nil means "not walked in this mode").
    /// In both cases the slot occupies the same space so scrolling never
    /// reflows the row.
    @ViewBuilder
    private func rowContent(
        playlist: Playlist,
        isOn: Bool,
        countShownWhenNil: Bool
    ) -> some View {
        let rawCount = viewModel.membershipIndex.trackCount(
            forPlaylistAMID: playlist.appleMusicPlaylistID
        )
        let displayCount = rawCount ?? 0
        let countVisible = rawCount != nil || countShownWhenNil

        HStack(spacing: 12) {
            PlaylistCoverView(
                appleMusicPlaylistID: playlist.appleMusicPlaylistID,
                size: 40,
                cornerRadius: 8
            )

            // Sparkles is *always rendered*, with opacity driven by
            // `isEditable`. Conditionally inserting/removing it (an `if`) makes
            // the inner HStack widen/narrow whenever SwiftData republishes the
            // playlist (e.g., a background sync touching `isEditable`), and
            // that micro-reflow shows up as a flash on the title row during
            // scroll. Keeping the symbol in the layout permanently locks the
            // width.
            HStack(spacing: 5) {
                Text(playlist.name)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.7))
                    .opacity(playlist.isEditable ? 0 : 1)
                    .accessibilityLabel(playlist.isEditable ? "" : "Apple Music")
                    .accessibilityHidden(playlist.isEditable)
            }

            Spacer()

            // Reserved width keeps the Spacer from twitching when the number
            // changes width (1 → 2 → 3 digits) as the membership index resolves
            // mid-scroll.
            Text(displayCount, format: .number)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .trailing)
                .opacity(countVisible ? 1 : 0)

            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn ? appAccent : Color.secondary.opacity(0.4))
                .font(.title3)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: isOn)
        }
        // The 40pt cover already anchors the HStack's intrinsic height, so we
        // don't need an explicit minHeight here — defensive overrides on
        // `sparkles` opacity and the count width above are what actually keep
        // the row from reflowing mid-scroll.
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }

    // MARK: - Shared header + empty state

    /// Section header carrying the count summary and the per-segment `SortChip`.
    /// Mirrors `SourceScopePickerSheet.sortHeader` so both pickers anchor sort
    /// the same way. The chip hides when there's nothing to sort. `countValue`
    /// drives the numeric tick so toggling a row reads as one motion.
    private func sortHeader<Field>(
        _ title: String,
        field: Binding<Field>,
        descending: Binding<Bool>,
        showsChip: Bool,
        countValue: Int
    ) -> some View where Field: SortFieldProtocol, Field.AllCases: RandomAccessCollection {
        HStack {
            Text(title)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: false))
                .animation(.snappy, value: countValue)
            Spacer()
            if showsChip {
                SortChip(field: field, descending: descending)
            }
        }
        .textCase(nil)
    }

    // MARK: - Filter scope control

    /// Compact glass menu chip that switches the Filter queue between its
    /// Playlists and Artists lists. Replaces the full-width segmented control
    /// that used to stack beneath the top mode switch and read as a bolted-on
    /// sub-sheet. Mirrors `SortChip`'s glass-capsule chrome so the scope switcher
    /// and the sort control read as one matched pair of header chips. The label
    /// crossfades on switch so the change reads as one motion, not a hard cut.
    private var filterScopeChip: some View {
        Menu {
            Picker("Filter scope", selection: filterScope.animation(.easeInOut(duration: 0.22))) {
                ForEach(FilterScope.allCases) { scope in
                    Label(scope.label, systemImage: scope.icon).tag(scope)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: filterScope.wrappedValue.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(filterScope.wrappedValue.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.22), value: filterScope.wrappedValue)
        }
        .modifier(FilterScopeChipChrome())
        .accessibilityLabel("Filter scope")
        .accessibilityValue(filterScope.wrappedValue.label)
        .accessibilityHint("Switches between filtering playlists and artists")
    }

    /// Filter-queue section header: the scope switcher on the leading edge, the
    /// per-scope `SortChip` on the trailing edge. The two glass chips replace the
    /// old stacked segmented control; the filtered count moves to the footer so
    /// the header stays a clean two-chip row.
    private func filterScopeHeader<Field>(
        field: Binding<Field>,
        descending: Binding<Bool>,
        showsChip: Bool
    ) -> some View where Field: SortFieldProtocol, Field.AllCases: RandomAccessCollection {
        HStack {
            filterScopeChip
            Spacer()
            if showsChip {
                SortChip(field: field, descending: descending)
            }
        }
        .textCase(nil)
    }

    /// Filter-queue footer: the live filtered count (numeric tick on toggle) plus
    /// the "filter is paused outside Library mode" note. Folding the count down
    /// here keeps the header to its two chips.
    private func filterFooter(count: Int, noun: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(count) \(noun)\(count == 1 ? "" : "s") hidden in Library mode")
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: false))
                .animation(.snappy, value: count)
            if viewModel.config.mode != .library {
                Text("Current session is \(viewModel.config.mode.title).")
            }
        }
    }

    /// Native empty state rendered as a clear list row — same vocabulary as
    /// `SourceScopePickerSheet`'s no-results row, replacing the old custom glass
    /// card so the sheet keeps no bespoke surfaces.
    private func emptyRow(title: String, detail: String, icon: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(detail)
        }
        .listRowBackground(Color.clear)
    }
}

// MARK: - Filter scope chip chrome

/// Press/menu chrome for the Filter queue's scope chip — the capsule sibling of
/// `SortChipChrome`. On iOS 26 the native `.glass` button means the system
/// morphs that exact capsule into the menu (no separate lift platter to crop);
/// pre-26 falls back to a flat `.thinMaterial` capsule. Kept neutral
/// (`.tint(.secondary)`) to match the app's restrained-accent treatment on
/// chrome.
private struct FilterScopeChipChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .menuStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(.secondary)
        } else {
            content
                .menuStyle(.button)
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
        }
    }
}

// MARK: - Playlist cover thumbnail

struct PlaylistCoverView: View {
    let appleMusicPlaylistID: String?
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 8

    private var artwork: Artwork? {
        guard let id = appleMusicPlaylistID else { return nil }
        return MusicLibraryService.shared.artwork(forPlaylistID: id)
    }

    /// Placeholder is layered *behind* `ArtworkImage` rather than swapped with
    /// it via `Group { if/else }`. `ArtworkImage` is transparent while it
    /// decodes/fetches the bytes, so a Group-style swap means the row briefly
    /// reveals whatever sits underneath the cover (mesh + glass material in
    /// the playlist sheets) → a visible flash as each row scrolls into view.
    /// A ZStack keeps an opaque tile underneath so the decode is invisible.
    var body: some View {
        ZStack {
            placeholder
            if let artwork {
                ArtworkImage(artwork, width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay(
                Image(systemName: "music.note.list")
                    .font(size > 44 ? .body : .caption)
                    .foregroundStyle(.secondary)
            )
    }
}
