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
    /// excluding them is a legitimate power-user move. Sorted alphabetically
    /// because the sidebar's `displayOrder` is meaningless here.
    private var filterablePlaylists: [Playlist] {
        viewModel.playlists
            .filter { $0.appleMusicPlaylistID != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var excludedSet: Set<String> { QueueFilterStore.decode(rawExcluded) }

    private var isAtCapacity: Bool {
        !viewModel.canAddToSidebar && !editablePlaylists.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LivingMeshBackground()

                VStack(spacing: 12) {
                    Picker("Section", selection: $segment) {
                        ForEach(Segment.allCases) { seg in
                            Text(seg.label).tag(seg)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            switch segment {
                            case .sidebar: sidebarSection
                            case .filter:  filterSection
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                        .animation(.snappy(duration: 0.22), value: segment)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if segment == .sidebar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showCreate = true
                        } label: {
                            Image(systemName: "plus")
                                .fontWeight(.semibold)
                        }
                        .accessibilityLabel("New playlist")
                    }
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

    // MARK: - Sidebar segment

    @ViewBuilder
    private var sidebarSection: some View {
        sidebarSubtitle
        sidebarSlab
        if isAtCapacity {
            capacityCaption
        }
    }

    /// Quiet count line above the slab. The digits tick via
    /// `.contentTransition(.numericText)` so toggling a row reads as a single
    /// motion (row bounce + count tick) without needing a floating chip.
    private var sidebarSubtitle: some View {
        Text("\(viewModel.sidebarCount) of \(maxSidebar) in your sidebar")
            .font(.system(.footnote, design: .rounded))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: false))
            .animation(.snappy, value: viewModel.sidebarCount)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var sidebarSlab: some View {
        if editablePlaylists.isEmpty {
            emptyState(
                title: "No playlists yet",
                detail: "Tap + to create your first one.",
                icon: "music.note.list"
            )
        } else {
            VStack(spacing: 4) {
                ForEach(Array(editablePlaylists.enumerated()), id: \.element.id) { index, playlist in
                    sidebarRow(for: playlist)
                    if index < editablePlaylists.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 1)
            )
        }
    }

    /// Soft "you've maxed the sidebar" line below the slab. Replaces silent
    /// `.opacity` dimming with a sentence so the user understands *why*
    /// unselected rows are inert.
    private var capacityCaption: some View {
        Text("Sidebar full — turn one off to add another.")
            .font(.system(.footnote, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 2)
    }

    @ViewBuilder
    private func sidebarRow(for playlist: Playlist) -> some View {
        let isOn = playlist.isInSidebar
        let canEnable = viewModel.canAddToSidebar
        let isTappable = isOn || canEnable

        Button {
            if isOn {
                viewModel.setSidebar(playlist, included: false)
            } else if canEnable {
                viewModel.setSidebar(playlist, included: true)
            }
        } label: {
            HStack(spacing: 12) {
                PlaylistCoverView(
                    appleMusicPlaylistID: playlist.appleMusicPlaylistID,
                    size: 40,
                    cornerRadius: 8
                )

                Text(playlist.name)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                // Only editable rows reach this sheet, so a nil from the
                // index means "truly empty playlist" — render "0" rather
                // than dropping the badge.
                let count = viewModel.membershipIndex.trackCount(
                    forPlaylistAMID: playlist.appleMusicPlaylistID
                ) ?? 0
                Text(count, format: .number)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                // Multi-select toggle idiom: always-rendered `circle` ↔
                // `checkmark.circle.fill` swap. Empty circle telegraphs
                // "this can be toggled," the swap-with-bounce makes
                // toggling feel landed.
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? appAccent : Color.secondary.opacity(0.4))
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isOn)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
            .opacity(isTappable ? 1.0 : 0.4)
            .animation(.snappy(duration: 0.22), value: isOn)
        }
        .buttonStyle(.plain)
        .disabled(!isTappable)
    }

    // MARK: - Filter segment

    @ViewBuilder
    private var filterSection: some View {
        filterSubtitle
        if viewModel.config.mode != .library {
            filterModeCaption
        }
        filterSlab
    }

    /// Two-line subtitle: first line is the count summary, second line spells
    /// out the lenient rule so users don't worry that hiding a "Workout"
    /// playlist also yanks tracks that happen to live in their "Chill" list.
    private var filterSubtitle: some View {
        let count = excludedSet.count
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(count) playlist\(count == 1 ? "" : "s") filtered")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: false))
                .animation(.snappy, value: count)
            Text("Hide tracks that live *only* in selected playlists — still shown if also in an unselected one.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.85))
        }
        .padding(.horizontal, 4)
    }

    /// Reminder that the filter is library-mode-only. Edits still persist,
    /// they just won't change the current deck until the user switches modes.
    private var filterModeCaption: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Filter applies in Library mode — current session is \(viewModel.config.mode.title).")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var filterSlab: some View {
        if filterablePlaylists.isEmpty {
            emptyState(
                title: "No playlists to filter",
                detail: "Once you have playlists in your library, you can hide their tracks here.",
                icon: "line.3.horizontal.decrease.circle"
            )
        } else {
            VStack(spacing: 4) {
                ForEach(Array(filterablePlaylists.enumerated()), id: \.element.id) { index, playlist in
                    filterRow(for: playlist)
                    if index < filterablePlaylists.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func filterRow(for playlist: Playlist) -> some View {
        let amID = playlist.appleMusicPlaylistID ?? ""
        let isFiltered = !amID.isEmpty && excludedSet.contains(amID)

        Button {
            toggleFilter(amID: amID)
        } label: {
            HStack(spacing: 12) {
                PlaylistCoverView(
                    appleMusicPlaylistID: playlist.appleMusicPlaylistID,
                    size: 40,
                    cornerRadius: 8
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !playlist.isEditable {
                        Text("Apple Music")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                }

                Spacer()

                // `nil` from `trackCount` means the playlist wasn't walked in
                // this mode's index pass (curated playlists in `.library`
                // mode skip the walk). Render nothing rather than a misleading
                // "0" — the toggle still works because the filter calculation
                // happens server-side in `deckExclusionSet`.
                if let count = viewModel.membershipIndex.trackCount(
                    forPlaylistAMID: playlist.appleMusicPlaylistID
                ) {
                    Text(count, format: .number)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
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
        }
        .buttonStyle(.plain)
        .disabled(amID.isEmpty)
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

    // MARK: - Shared empty state

    private func emptyState(title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 18)
        .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
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

    var body: some View {
        Group {
            if let artwork {
                ArtworkImage(artwork, width: size, height: size)
            } else {
                placeholder
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
