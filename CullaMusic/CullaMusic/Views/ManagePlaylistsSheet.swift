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
                    // Animated binding centralizes the segment-change animation
                    // in one place. Previously the picker drove an implicit
                    // animation, the inner VStack added `.animation(value:)`,
                    // and the toolbar reconfigured — three contexts fighting
                    // produced ~1s of visible flicker on switch.
                    Picker("Section", selection: $segment.animation(.easeInOut(duration: 0.22))) {
                        ForEach(Segment.allCases) { seg in
                            Text(seg.label).tag(seg)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 18)
                    .padding(.top, 14)

                    ScrollView {
                        Group {
                            switch segment {
                            case .sidebar: sidebarSection
                            case .filter:  filterSection
                            }
                        }
                        .id(segment)
                        .padding(.horizontal, 18)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Always render the leading slot so the nav bar layout stays
                // identical across segments — conditionally inserting/removing
                // a ToolbarItem was triggering a NavigationStack reflow that
                // rippled into the ZStack on every switch.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel("New playlist")
                    .opacity(segment == .sidebar ? 1 : 0)
                    .allowsHitTesting(segment == .sidebar)
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

    private var sidebarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sidebarSubtitle
            sidebarSlab
            if isAtCapacity {
                capacityCaption
            }
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
            // `.thinMaterial` instead of `.glassSurface` deliberately. iOS 26's
            // Liquid Glass effect fails to composite reliably on top of the
            // animated `LivingMeshBackground` here — the slab renders
            // transparent at rest and only flashes its rows during scroll.
            // The bug is compositor-level, so it never shows up in screenshots
            // or ReplayKit recordings. `.thinMaterial` is the same fallback
            // `glassSurface` uses on iOS < 26 — reliable, identical between
            // segments, no glass refraction but the slab actually draws.
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

    /// Filter mirrors Sidebar's structure: one-line subtitle, the slab, then
    /// an optional caption *below* (parallel to Sidebar's `capacityCaption`).
    /// Keeping the above-slab footprint to a single line in both segments is
    /// what makes the mesh reveal identical and stops the brightness mismatch.
    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            filterSubtitle
            filterSlab
            if viewModel.config.mode != .library {
                filterModeCaption
            }
        }
    }

    /// One-line count summary. Structurally identical to `sidebarSubtitle` —
    /// the previous info-popover button was the only `Button` left in the
    /// scroll area and is gone now, so neither segment ships a tappable
    /// element outside the slab rows.
    private var filterSubtitle: some View {
        let count = excludedSet.count
        return Text("\(count) playlist\(count == 1 ? "" : "s") filtered")
            .font(.system(.footnote, design: .rounded))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: false))
            .animation(.snappy, value: count)
            .padding(.horizontal, 4)
    }

    /// Reminder that the filter is library-mode-only. Edits still persist,
    /// they just won't change the current deck until the user switches modes.
    /// Plain `Text` to mirror `capacityCaption` — no icon.
    private var filterModeCaption: some View {
        Text("Filter applies in Library mode — current session is \(viewModel.config.mode.title).")
            .font(.system(.footnote, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 2)
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
            // `.thinMaterial` instead of `.glassSurface` deliberately. iOS 26's
            // Liquid Glass effect fails to composite reliably on top of the
            // animated `LivingMeshBackground` here — the slab renders
            // transparent at rest and only flashes its rows during scroll.
            // The bug is compositor-level, so it never shows up in screenshots
            // or ReplayKit recordings. `.thinMaterial` is the same fallback
            // `glassSurface` uses on iOS < 26 — reliable, identical between
            // segments, no glass refraction but the slab actually draws.
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
