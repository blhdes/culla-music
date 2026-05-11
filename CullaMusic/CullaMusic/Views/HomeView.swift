import SwiftUI
import SwiftData
import MusicKit

// MARK: - HomeViewModel

@Observable
final class HomeViewModel {
    var dismissedCount: Int = 0
    var unsortedCount: Int? = nil   // nil = computing
    var playlists: [Playlist] = []

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func loadCounts() async {
        await syncPlaylistsFromAppleMusic()
        let sortedSnapshot = (try? modelContext.fetchCount(FetchDescriptor<SortedSong>())) ?? 0
        let dismissedSnapshot = (try? modelContext.fetchCount(FetchDescriptor<DismissedSong>())) ?? 0
        dismissedCount = dismissedSnapshot

        // Cache is invalidated by either a calendar-day rollover OR a change in
        // the local Sorted/Dismissed counts — so the count refreshes whenever
        // the user has actually done something in Culla, not just once per day.
        let cacheKey = "music.unsortedCountCached"
        let dateKey  = "music.unsortedCountDate"
        let fingerprintKey = "music.unsortedCountFingerprint"
        let today = todayString()
        // Include the chip toggle in the fingerprint so flipping it invalidates
        // the cached count — the exclusion scope changes with the toggle.
        let chipToggleOn = UserDefaults.standard.bool(forKey: "membershipIncludeCurated")
        let fingerprint = "\(sortedSnapshot):\(dismissedSnapshot):curated=\(chipToggleOn)"
        let cachedDate  = UserDefaults.standard.string(forKey: dateKey) ?? ""
        let cachedFingerprint = UserDefaults.standard.string(forKey: fingerprintKey) ?? ""
        let cachedCount = UserDefaults.standard.integer(forKey: cacheKey)

        if cachedDate == today, cachedFingerprint == fingerprint {
            unsortedCount = cachedCount
            return
        }

        do {
            let playlistIDs = try await MusicLibraryService.shared.fetchPlaylistSongIDs(
                includeCurated: !chipToggleOn
            )
            let sortedIDs = Set((try? modelContext.fetch(FetchDescriptor<SortedSong>()))?.map(\.songID) ?? [])
            let exclusion = playlistIDs.union(sortedIDs)

            var count = 0
            let pageSize = 100
            var offset = 0

            while true {
                var request = MusicLibraryRequest<Song>()
                request.limit = pageSize
                request.offset = offset
                let response = try await request.response()
                let page = response.items

                for song in page where !exclusion.contains(song.id.rawValue) {
                    count += 1
                }

                offset += page.count
                if page.count < pageSize { break }
            }

            unsortedCount = count
            UserDefaults.standard.set(count, forKey: cacheKey)
            UserDefaults.standard.set(today, forKey: dateKey)
            UserDefaults.standard.set(fingerprint, forKey: fingerprintKey)
        } catch {
            print("Unsorted count failed: \(error)")
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
                case .editorial, .personalMix, .replay:
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
                    let transferMode = SourceTransferMode(rawValue: sourceTransferModeRaw) ?? .copy
                    let source = selectedMode == .library ? selectedSourcePlaylist : nil
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
            .filter { $0.isEditable && $0.appleMusicPlaylistID != nil }
            .sorted { $0.displayOrder < $1.displayOrder }
    }

    private var selectedSourcePlaylist: Playlist? {
        sourcePlaylists.first { $0.appleMusicPlaylistID == sourcePlaylistID }
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
        VStack(spacing: 6) {
            Picker("Source behavior", selection: Binding(
                get: { SourceTransferMode(rawValue: sourceTransferModeRaw) ?? .copy },
                set: { sourceTransferModeRaw = $0.rawValue }
            )) {
                ForEach(SourceTransferMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text((SourceTransferMode(rawValue: sourceTransferModeRaw) ?? .copy) == .copy
                 ? "Sorted songs stay in the source playlist too."
                 : "Sorted songs are removed from the source playlist.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
    }

    private func count(for mode: ReviewMode) -> Int? {
        guard let vm = homeVM else { return nil }
        switch mode {
        case .library:   return nil
        case .unsorted:  return vm.unsortedCount
        case .dismissed: return vm.dismissedCount
        }
    }

    private func isLoadingCount(for mode: ReviewMode) -> Bool {
        guard homeVM != nil else { return false }
        switch mode {
        case .library:   return false
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
                        ProgressView().scaleEffect(0.7)
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
