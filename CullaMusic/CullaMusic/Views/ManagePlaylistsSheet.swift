import SwiftUI
import MusicKit

/// Two-segment "Playlists" sheet:
///   • **Sidebar** — which playlists appear in the right-swipe sidebar
///     (capped to `MusicSwipeViewModel.maxSidebar`). The original behavior.
///   • **Filter queue** — which playlists' tracks should disappear from a
///     `.library` swipe session. Persisted in `QueueFilterStore` and consumed
///     by `MusicLibraryService.deckExclusionSet`. Lenient: a song hides only
///     when *every* playlist it belongs to is selected here, so excluding one
///     playlist never silently culls cross-listed tracks.
struct ManagePlaylistsSheet: View {
    @Bindable var viewModel: MusicSwipeViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent
    @State private var showCreate = false
    @State private var segment: Segment = .sidebar

    /// The up-swipe loved target. Hidden from the sidebar list below since the
    /// up-swipe already covers that playlist and double-listing it implies a
    /// toggle that wouldn't add anything. Configured in Settings.
    @AppStorage("lovedPlaylistID") private var lovedPlaylistID: String = ""

    /// Comma-joined `appleMusicPlaylistID`s of playlists whose tracks should be
    /// hidden from `.library` sessions. The raw string lives in `@AppStorage`
    /// so the sheet, the service, and any future settings surface all stay in
    /// lockstep without a custom store. See `QueueFilterStore`.
    @AppStorage(QueueFilterStore.defaultsKey) private var rawExcluded: String = ""

    // Each segment persists its own sort choice (stored as the choice's raw
    // value) so sorting one doesn't reshuffle the other. Sidebar defaults to
    // its real displayOrder; queue filter to alphabetical.
    @AppStorage("managePlaylists.sidebarSort") private var sidebarSortRaw = SidebarSortChoice.sidebarOrder.rawValue
    @AppStorage("managePlaylists.filterSort") private var filterSortRaw = PlaylistSortChoice.nameAsc.rawValue

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

    // MARK: - Sorting

    private var sidebarSortChoice: Binding<SidebarSortChoice> {
        Binding(
            get: { SidebarSortChoice(rawValue: sidebarSortRaw) ?? .sidebarOrder },
            set: { sidebarSortRaw = $0.rawValue }
        )
    }

    private var filterSortChoice: Binding<PlaylistSortChoice> {
        Binding(
            get: { PlaylistSortChoice(rawValue: filterSortRaw) ?? .nameAsc },
            set: { filterSortRaw = $0.rawValue }
        )
    }

    private var sortedEditablePlaylists: [Playlist] {
        let choice = sidebarSortChoice.wrappedValue
        return sorted(editablePlaylists, field: choice.field, descending: choice.descending)
    }

    private var sortedFilterablePlaylists: [Playlist] {
        let choice = filterSortChoice.wrappedValue
        return sorted(filterablePlaylists, field: choice.field, descending: choice.descending)
    }

    /// Orders a list by a sort field. A `nil` field means "keep the source
    /// order" — for the sidebar that's the real displayOrder, since
    /// `viewModel.playlists` already arrives sorted by it. Counts come from the
    /// live `membershipIndex`, dates from the service.
    private func sorted(_ playlists: [Playlist], field: PlaylistSortField?, descending: Bool) -> [Playlist] {
        guard let field else { return playlists }
        var rows = playlists
        rows.sort { lhs, rhs in
            switch field {
            case .alphabetical:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .modifiedDate:
                // Missing-date rows sort last ascending / first descending —
                // out of the way regardless of direction.
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
                let l = viewModel.membershipIndex.trackCount(forPlaylistAMID: lhs.appleMusicPlaylistID) ?? 0
                let r = viewModel.membershipIndex.trackCount(forPlaylistAMID: rhs.appleMusicPlaylistID) ?? 0
                return l < r
            }
        }
        if descending { rows.reverse() }
        return rows
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
        }
    }

    /// Swaps the active segment's section inside one stable `List`. Switching
    /// the section (rather than swapping two whole `List`s) keeps the list
    /// mounted, so a segment change is a content crossfade, not a teardown.
    @ViewBuilder
    private var sections: some View {
        switch segment {
        case .sidebar: sidebarSection
        case .filter:  filterSection
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
            } else {
                ForEach(sortedEditablePlaylists, id: \.id) { playlist in
                    sidebarRow(for: playlist)
                }
            }
        } header: {
            sortHeader(
                "\(viewModel.sidebarCount) of \(maxSidebar) in your sidebar",
                selection: sidebarSortChoice,
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
            } else {
                ForEach(sortedFilterablePlaylists, id: \.id) { playlist in
                    filterRow(for: playlist)
                }
            }
        } header: {
            sortHeader(
                "\(count) playlist\(count == 1 ? "" : "s") filtered",
                selection: filterSortChoice,
                showsChip: !filterablePlaylists.isEmpty,
                countValue: count
            )
        } footer: {
            if viewModel.config.mode != .library {
                Text("Filter applies in Library mode — current session is \(viewModel.config.mode.title).")
            }
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
    private func sortHeader<Choice>(
        _ title: String,
        selection: Binding<Choice>,
        showsChip: Bool,
        countValue: Int
    ) -> some View where Choice: SortChoiceProtocol, Choice.AllCases: RandomAccessCollection {
        HStack {
            Text(title)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: false))
                .animation(.snappy, value: countValue)
            Spacer()
            if showsChip {
                SortChip(selection: selection)
            }
        }
        .textCase(nil)
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

// MARK: - Sidebar sort choices

/// Sort options for the **Sidebar** segment. Adds "Sidebar Order" — the
/// playlists' real `displayOrder`, i.e. the order they appear in the swipe
/// sidebar — and defaults to it, so opening the sheet doesn't reshuffle the
/// list. Kept separate from `PlaylistSortChoice` because displayOrder is
/// meaningless on the scope picker and queue filter, which share that enum.
enum SidebarSortChoice: String, CaseIterable, Identifiable, SortChoiceProtocol {
    case sidebarOrder
    case nameAsc
    case nameDesc
    case dateDesc
    case dateAsc
    case countDesc
    case countAsc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sidebarOrder: "Sidebar Order"
        case .nameAsc:      "Name (A→Z)"
        case .nameDesc:     "Name (Z→A)"
        case .dateDesc:     "Recently Modified"
        case .dateAsc:      "Oldest First"
        case .countDesc:    "Most Songs"
        case .countAsc:     "Fewest Songs"
        }
    }

    /// `nil` for `sidebarOrder` — the sort helper treats a nil field as "keep
    /// the source order", which is already displayOrder.
    var field: PlaylistSortField? {
        switch self {
        case .sidebarOrder:         nil
        case .nameAsc, .nameDesc:   .alphabetical
        case .dateDesc, .dateAsc:   .modifiedDate
        case .countDesc, .countAsc: .trackCount
        }
    }

    var descending: Bool {
        switch self {
        case .nameDesc, .dateDesc, .countDesc:             true
        case .sidebarOrder, .nameAsc, .dateAsc, .countAsc: false
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
