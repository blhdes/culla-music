import SwiftUI
import SwiftData
import MusicKit

// MARK: - HomeViewModel

@Observable
final class HomeViewModel {
    var dismissedCount: Int = 0
    var unsortedCount: Int? = nil   // nil = computing
    var libraryCount: Int? = nil    // nil = computing
    var playlists: [Playlist] = []

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func loadCounts() async {
        await syncPlaylistsFromAppleMusic()
        let dismissedSnapshot = (try? modelContext.fetchCount(FetchDescriptor<DismissedSong>())) ?? 0
        dismissedCount = dismissedSnapshot
        await recomputeCounts()
    }

    /// Recomputes (or reads from cache) the library and unsorted counts. Both
    /// modes need to walk the full library on a cache miss, so we do it in a
    /// single pass and tally each count from the same iteration.
    ///
    /// Library cache is fingerprinted by Sorted/Dismissed counts + calendar
    /// day. Unsorted adds the chip toggle to its fingerprint, so flipping the
    /// toggle invalidates only the unsorted slot — the library cache stays warm.
    func recomputeCounts() async {
        let sortedSnapshot = (try? modelContext.fetchCount(FetchDescriptor<SortedSong>())) ?? 0
        let dismissedSnapshot = (try? modelContext.fetchCount(FetchDescriptor<DismissedSong>())) ?? 0
        let today = todayString()
        let chipToggleOn = UserDefaults.standard.bool(forKey: "membershipIncludeCurated")

        // Library cache — count is unaffected by the chip toggle.
        let libraryFingerprint = "\(sortedSnapshot):\(dismissedSnapshot)"
        let libraryCachedDate = UserDefaults.standard.string(forKey: "music.libraryCountDate") ?? ""
        let libraryCachedFP = UserDefaults.standard.string(forKey: "music.libraryCountFingerprint") ?? ""
        let libraryCachedValue = UserDefaults.standard.integer(forKey: "music.libraryCountCached")
        let libraryFresh = (libraryCachedDate == today && libraryCachedFP == libraryFingerprint)

        // Unsorted cache — toggle-aware, so the scope swap forces a refetch.
        let unsortedFingerprint = "\(sortedSnapshot):\(dismissedSnapshot):curated=\(chipToggleOn)"
        let unsortedCachedDate = UserDefaults.standard.string(forKey: "music.unsortedCountDate") ?? ""
        let unsortedCachedFP = UserDefaults.standard.string(forKey: "music.unsortedCountFingerprint") ?? ""
        let unsortedCachedValue = UserDefaults.standard.integer(forKey: "music.unsortedCountCached")
        let unsortedFresh = (unsortedCachedDate == today && unsortedCachedFP == unsortedFingerprint)

        if libraryFresh { libraryCount = libraryCachedValue }
        if unsortedFresh { unsortedCount = unsortedCachedValue }

        guard !libraryFresh || !unsortedFresh else { return }

        // Cache miss — show the loader for whichever slot is stale so the user
        // sees the count update isn't stuck on a stale value.
        if !libraryFresh { libraryCount = nil }
        if !unsortedFresh { unsortedCount = nil }

        do {
            // Only fetch playlist memberships when unsorted needs them — saves
            // the round-trip on a toggle-only or library-only invalidation.
            let playlistIDs: Set<String>
            if !unsortedFresh {
                playlistIDs = try await MusicLibraryService.shared.fetchPlaylistSongIDs(
                    includeCurated: !chipToggleOn
                )
            } else {
                playlistIDs = []
            }
            let sortedIDs = Set((try? modelContext.fetch(FetchDescriptor<SortedSong>()))?.map(\.songID) ?? [])
            let dismissedIDs = Set((try? modelContext.fetch(FetchDescriptor<DismissedSong>()))?.map(\.songID) ?? [])
            let unsortedExclusion = playlistIDs.union(sortedIDs)
            let libraryExclusion = sortedIDs.union(dismissedIDs)

            var libCount = 0
            var unsCount = 0
            let pageSize = 100
            var offset = 0

            while true {
                var request = MusicLibraryRequest<Song>()
                request.limit = pageSize
                request.offset = offset
                let response = try await request.response()
                let page = response.items

                for song in page {
                    let id = song.id.rawValue
                    if !libraryFresh, !libraryExclusion.contains(id) {
                        libCount += 1
                    }
                    if !unsortedFresh, !unsortedExclusion.contains(id) {
                        unsCount += 1
                    }
                }

                offset += page.count
                if page.count < pageSize { break }
            }

            if !libraryFresh {
                libraryCount = libCount
                UserDefaults.standard.set(libCount, forKey: "music.libraryCountCached")
                UserDefaults.standard.set(today, forKey: "music.libraryCountDate")
                UserDefaults.standard.set(libraryFingerprint, forKey: "music.libraryCountFingerprint")
            }
            if !unsortedFresh {
                unsortedCount = unsCount
                UserDefaults.standard.set(unsCount, forKey: "music.unsortedCountCached")
                UserDefaults.standard.set(today, forKey: "music.unsortedCountDate")
                UserDefaults.standard.set(unsortedFingerprint, forKey: "music.unsortedCountFingerprint")
            }
        } catch {
            print("Recompute counts failed: \(error)")
        }
    }

    private func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: .now)
    }

    private func syncPlaylistsFromAppleMusic() async {
        do {
            let amPlaylists = try await MusicLibraryService.shared.refreshUserPlaylists()
            let local = fetchLocalPlaylists()
            let localByAMID = Dictionary(
                uniqueKeysWithValues: local.compactMap { playlist -> (String, Playlist)? in
                    guard let appleMusicPlaylistID = playlist.appleMusicPlaylistID else { return nil }
                    return (appleMusicPlaylistID, playlist)
                }
            )
            var nextOrder = (local.map(\.displayOrder).max() ?? -1) + 1

            for amPlaylist in amPlaylists {
                let editable: Bool
                switch amPlaylist.kind {
                case .editorial, .external, .personalMix, .replay:
                    editable = false
                default:
                    editable = true
                }

                if let existing = localByAMID[amPlaylist.id.rawValue] {
                    if !existing.isEditable {
                        existing.isEditable = editable
                    }
                    existing.name = amPlaylist.name
                } else {
                    let row = Playlist(
                        name: amPlaylist.name,
                        displayOrder: nextOrder,
                        appleMusicPlaylistID: amPlaylist.id.rawValue,
                        isEditable: editable
                    )
                    modelContext.insert(row)
                    nextOrder += 1
                }
            }

            try? modelContext.save()
            playlists = fetchLocalPlaylists()
        } catch {
            playlists = fetchLocalPlaylists()
            print("Playlist sync failed: \(error)")
        }
    }

    private func fetchLocalPlaylists() -> [Playlist] {
        let descriptor = FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.displayOrder)])
        return (try? modelContext.fetch(descriptor)) ?? []
    }
}

// MARK: - HomeView

struct HomeView: View {
    let onStart: (SwipeConfig) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var homeVM: HomeViewModel?
    @State private var selectedMode: ReviewMode = .library
    @State private var sourcePlaylistID: String = ""
    @State private var showSourcePicker = false
    @State private var showSettings = false
    @AppStorage("music.sortOrder") private var sortOrderRaw: String = SortOrder.newestFirst.rawValue
    @AppStorage("music.sourceTransferMode") private var sourceTransferModeRaw: String = SourceTransferMode.copy.rawValue
    // Observed so the unsorted count recomputes instantly when the toggle
    // flips in Settings — without this, the change would only land on next launch.
    @AppStorage("membershipIncludeCurated") private var membershipIncludeCurated: Bool = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Text("culla music")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(.secondary)
                    .padding(.top, 28)

                Spacer()

                VStack(spacing: 10) {
                    ForEach(ReviewMode.allCases) { mode in
                        ModeCard(
                            mode: mode,
                            isSelected: selectedMode == mode,
                            count: count(for: mode),
                            isLoadingCount: isLoadingCount(for: mode)
                        ) {
                            selectedMode = mode
                        }
                    }
                }
                .padding(.horizontal, 24)

                if selectedMode == .library {
                    sourceFilterButton
                        .padding(.top, 18)
                        .transition(.opacity)
                }

                Spacer()

                Divider()
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)

                if selectedMode == .library, !sourcePlaylistID.isEmpty {
                    sourceTransferPicker
                        .padding(.bottom, 16)
                        .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                }

                // Shared order picker — binds directly to sortOrderRaw to avoid
                // a computed-property setter that Swift treats as mutating in closures.
                HStack {
                    Text("Order")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Order", selection: Binding(
                        get: { SortOrder(rawValue: sortOrderRaw) ?? .newestFirst },
                        set: { sortOrderRaw = $0.rawValue }
                    )) {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)

                Button {
                    let order = SortOrder(rawValue: sortOrderRaw) ?? .newestFirst
                    let storedMode = SourceTransferMode(rawValue: sourceTransferModeRaw) ?? .copy
                    let source = selectedMode == .library ? selectedSourcePlaylist : nil
                    // Force `.copy` for read-only sources — we can't remove
                    // from Apple-curated, smart Favorites, or shared playlists.
                    let transferMode: SourceTransferMode =
                        (source?.isEditable ?? true) ? storedMode : .copy
                    onStart(SwipeConfig(
                        mode: selectedMode,
                        order: order,
                        sourcePlaylistID: source?.appleMusicPlaylistID,
                        sourcePlaylistName: source?.name,
                        sourceTransferMode: transferMode
                    ))
                } label: {
                    Text("Start Cullaing")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .padding(.top, 18)
        }
        .task {
            let vm = HomeViewModel(modelContext: modelContext)
            homeVM = vm
            await vm.loadCounts()
        }
        .onChange(of: selectedMode) { _, newValue in
            if newValue != .library {
                sourcePlaylistID = ""
            }
        }
        .onChange(of: membershipIncludeCurated) { _, _ in
            Task { await homeVM?.recomputeCounts() }
        }
        .sheet(isPresented: $showSourcePicker) {
            SourcePlaylistPickerSheet(
                playlists: sourcePlaylists,
                selectedID: sourcePlaylistID
            ) { picked in
                sourcePlaylistID = picked?.appleMusicPlaylistID ?? ""
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .animation(.easeInOut(duration: 0.18), value: selectedMode)
        .animation(.easeInOut(duration: 0.18), value: sourcePlaylistID)
    }

    private var sourcePlaylists: [Playlist] {
        (homeVM?.playlists ?? [])
            .filter { $0.appleMusicPlaylistID != nil }
            .sorted { $0.displayOrder < $1.displayOrder }
    }

    private var selectedSourcePlaylist: Playlist? {
        sourcePlaylists.first { $0.appleMusicPlaylistID == sourcePlaylistID }
    }

    /// True when the user has picked a Sort From source that we can't remove
    /// songs from (Apple-curated, smart Favorites, shared-by-others, etc.).
    /// Forces the transfer mode to `.copy` so we never attempt a doomed write.
    private var selectedSourceIsReadOnly: Bool {
        guard let p = selectedSourcePlaylist else { return false }
        return !p.isEditable
    }

    private var sourceFilterButton: some View {
        Button {
            showSourcePicker = true
        } label: {
            HStack {
                Image(systemName: "music.note.list")
                if let playlist = selectedSourcePlaylist {
                    Text(playlist.name)
                    Spacer()
                    Button {
                        sourcePlaylistID = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("General Library")
                    Spacer()
                    Text("Sort from a playlist")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .modifier(GlassOrQuaternaryRounded())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
    }

    private var sourceTransferPicker: some View {
        // For read-only sources the picker is forced to Keep — Apple doesn't
        // let us remove songs from those, so Move would silently fail.
        let isReadOnly = selectedSourceIsReadOnly
        let storedMode = SourceTransferMode(rawValue: sourceTransferModeRaw) ?? .copy
        let displayMode: SourceTransferMode = isReadOnly ? .copy : storedMode

        return VStack(spacing: 6) {
            Picker("Source behavior", selection: Binding(
                get: { displayMode },
                set: { sourceTransferModeRaw = $0.rawValue }
            )) {
                ForEach(SourceTransferMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isReadOnly)

            Text(transferModeFooter(isReadOnly: isReadOnly, mode: displayMode))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
    }

    private func transferModeFooter(isReadOnly: Bool, mode: SourceTransferMode) -> String {
        if isReadOnly {
            return "This playlist is read-only — sorted songs stay where they are."
        }
        return mode == .copy
            ? "Sorted songs stay in the source playlist too."
            : "Sorted songs are removed from the source playlist."
    }

    private func count(for mode: ReviewMode) -> Int? {
        guard let vm = homeVM else { return nil }
        switch mode {
        case .library:   return vm.libraryCount
        case .unsorted:  return vm.unsortedCount
        case .dismissed: return vm.dismissedCount
        }
    }

    private func isLoadingCount(for mode: ReviewMode) -> Bool {
        guard homeVM != nil else { return false }
        switch mode {
        case .library:   return homeVM?.libraryCount == nil
        case .unsorted:  return homeVM?.unsortedCount == nil
        case .dismissed: return false
        }
    }
}

// MARK: - ModeCard

private struct ModeCard: View {
    let mode: ReviewMode
    let isSelected: Bool
    let count: Int?
    let isLoadingCount: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Use Color types so both branches of the ternary share the same type.
                Image(systemName: isSelected ? "record.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .animation(.spring(response: 0.3), value: isSelected)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(mode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Group {
                    if isLoadingCount {
                        LinearLoader()
                    } else if let count {
                        Text(count.formatted())
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(width: 48, alignment: .trailing)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected
                        ? Color.accentColor.opacity(0.08)
                        : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.35) : .clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - Glass / Quaternary background modifier

/// Pill-style background: liquid glass on iOS 26+, falls back to a soft
/// quaternary fill on older OS versions. Mirrors the photo Culla helper
/// so the source button looks identical across both apps.
private struct GlassOrQuaternaryRounded: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(in: RoundedRectangle(cornerRadius: 10))
        } else {
            content.background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
