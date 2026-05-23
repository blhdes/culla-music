import Foundation
import SwiftData
import MusicKit

/// Lazy-paged song source backing `HomeArtCarouselView`. Parallel to
/// `MusicSwipeViewModel`'s queue — uses its own offset cursor so browsing
/// through the carousel doesn't consume the swipe-session paging state.
///
/// Three modes, each mirroring the matching swipe session's exclusion logic
/// so the carousel preview matches what the user is about to swipe:
/// - `.library`:   library songs minus sorted minus dismissed
/// - `.unsorted`:  library minus playlist memberships minus sorted minus dismissed
/// - `.dismissed`: every DismissedSong row, resolved up-front (bounded set)
@Observable
@MainActor
final class CarouselSongFeed {
    let mode: ReviewMode
    let sortOrder: SortOrder
    private let modelContext: ModelContext
    private let service: MusicLibraryService

    /// All loaded songs so far. Append-only — the carousel reads this directly
    /// for its `LazyHStack`. SwiftUI observes via `@Observable`.
    private(set) var songs: [Song] = []

    /// Loading state for the very first page. Drives the placeholder shown
    /// before the first window lands.
    private(set) var isInitialLoading: Bool = true

    /// True once the underlying source has nothing more to page. The carousel
    /// stops calling `loadMoreIfNeeded()` once this flips.
    private(set) var isExhausted: Bool = false

    /// In-flight pagination task — held so a fast scroll doesn't fire multiple
    /// pages in parallel against MusicKit.
    private var pagingTask: Task<Void, Never>?

    private var libraryOffset: Int = 0
    private var exclusionSet: Set<String> = []

    /// Target songs per page. Tuned for the carousel: small enough that the
    /// first window arrives quickly, large enough that the user typically
    /// scrolls a noticeable distance before triggering the next page.
    private let pageSize: Int = 30

    /// Trigger threshold — when the centered index is within this many items
    /// of the loaded tail, kick off the next page.
    let prefetchDistance: Int = 8

    init(mode: ReviewMode, sortOrder: SortOrder, modelContext: ModelContext) {
        self.mode = mode
        self.sortOrder = sortOrder
        self.modelContext = modelContext
        self.service = MusicLibraryService.shared
    }

    /// Loads the first window. Idempotent — re-entering the carousel won't
    /// re-fetch if songs are already present.
    func loadInitial() async {
        guard songs.isEmpty, !isExhausted else { return }
        switch mode {
        case .library, .unsorted:
            await buildExclusionSet()
            await loadNextLibraryPage()
        case .dismissed:
            await loadAllDismissed()
        }
        isInitialLoading = false
    }

    /// Requests one more page if we're not already paging and there's more
    /// to fetch. Coalesced — concurrent callers from rapid scroll all collapse
    /// into the single in-flight task.
    func loadMoreIfNeeded() {
        // Dismissed loads its bounded set up front — no incremental paging.
        guard mode != .dismissed else { return }
        guard !isExhausted, pagingTask == nil else { return }
        // No @MainActor annotation — the enclosing type is already
        // MainActor-isolated, so the Task inherits that isolation.
        pagingTask = Task { [weak self] in
            await self?.loadNextLibraryPage()
            self?.pagingTask = nil
        }
    }

    // MARK: - Library / Unsorted paging

    private func loadNextLibraryPage() async {
        var collected: [Song] = []
        let batchSize = 100
        while collected.count < pageSize && !isExhausted {
            do {
                var request = MusicLibraryRequest<Song>()
                request.limit = batchSize
                request.offset = libraryOffset
                request.sort(by: \.libraryAddedDate, ascending: sortOrder.ascending)
                let response = try await request.response()
                let page = response.items
                if page.isEmpty {
                    isExhausted = true
                    break
                }
                for song in page where !exclusionSet.contains(song.id.rawValue) {
                    collected.append(song)
                }
                libraryOffset += page.count
                if page.count < batchSize {
                    isExhausted = true
                }
            } catch {
                print("CarouselSongFeed pageLibrary failed: \(error)")
                isExhausted = true
                break
            }
        }
        songs.append(contentsOf: collected)
    }

    // MARK: - Dismissed (bounded, one-shot load)

    private func loadAllDismissed() async {
        let ascending = sortOrder.ascending
        let descriptor = FetchDescriptor<DismissedSong>(
            sortBy: [SortDescriptor(\.dismissedAt, order: ascending ? .forward : .reverse)]
        )
        guard
            let rows = try? modelContext.fetch(descriptor),
            !rows.isEmpty
        else {
            isExhausted = true
            return
        }
        let ids = rows.map(\.songID)
        do {
            songs = try await service.resolveSongs(ids: ids)
        } catch {
            print("CarouselSongFeed dismissed resolve failed: \(error)")
        }
        // Bounded by the SwiftData fetch — no more to load after this.
        isExhausted = true
    }

    // MARK: - Exclusion

    private func buildExclusionSet() async {
        // Shared with HomeHeroArtStack via MusicLibraryService so the carousel
        // and the hero can't drift on what counts as "next song" in each mode.
        exclusionSet = await service.deckExclusionSet(for: mode, modelContext: modelContext)
    }
}
