import SwiftUI
import SwiftData
import MusicKit

// MARK: - HomeViewModel

@Observable
final class HomeViewModel {
    var dismissedCount: Int = 0
    var unsortedCount: Int? = nil   // nil = computing

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func loadCounts() async {
        dismissedCount = (try? modelContext.fetchCount(FetchDescriptor<DismissedSong>())) ?? 0

        // Read cache from UserDefaults inline — no stored properties needed,
        // which avoids the @Observable macro collision on property names.
        let cacheKey = "music.unsortedCountCached"
        let dateKey  = "music.unsortedCountDate"
        let today = todayString()
        let cachedDate  = UserDefaults.standard.string(forKey: dateKey) ?? ""
        let cachedCount = UserDefaults.standard.integer(forKey: cacheKey)

        if cachedDate == today {
            unsortedCount = cachedCount
            return
        }

        do {
            let editableIDs = try await MusicLibraryService.shared.fetchEditablePlaylistSongIDs()
            let sortedIDs = Set((try? modelContext.fetch(FetchDescriptor<SortedSong>()))?.map(\.songID) ?? [])
            let exclusion = editableIDs.union(sortedIDs)

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
        } catch {
            print("Unsorted count failed: \(error)")
        }
    }

    private func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: .now)
    }
}

// MARK: - HomeView

struct HomeView: View {
    let onStart: (SwipeConfig) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var homeVM: HomeViewModel?
    @State private var selectedMode: ReviewMode = .library
    @AppStorage("music.sortOrder") private var sortOrderRaw: String = SortOrder.newestFirst.rawValue

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

                Spacer()

                Divider()
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)

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
                    onStart(SwipeConfig(mode: selectedMode, order: order))
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
        .task {
            let vm = HomeViewModel(modelContext: modelContext)
            homeVM = vm
            await vm.loadCounts()
        }
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
