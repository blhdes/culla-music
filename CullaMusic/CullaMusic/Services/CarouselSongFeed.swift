import Foundation
import SwiftData
import MusicKit

/// Lazy-paged song source backing `HomeArtCarouselView`. Parallel to
/// `MusicSwipeViewModel`'s queue — uses its own offset cursor so browsing
/// through the carousel doesn't consume the swipe-session paging state.
///
/// Sources, each mirroring the matching swipe session's exclusion logic so the
/// carousel preview matches what the user is about to swipe:
/// - `.library`:   library songs minus sorted minus dismissed
/// - `.unsorted`:  library minus playlist memberships minus sorted minus dismissed
/// - `.dismissed`: every DismissedSong row, resolved up-front (bounded set)
/// - **scoped** (a non-nil `source`, playlist or artist): every track in the
///   collection, ordered like the scoped walk, minus dismissed (unless the
///   user opted in). Sorted songs stay — scoped sessions re-categorize the
///   whole collection. Bounded like `.dismissed`, so no incremental paging.
@Observable
@MainActor
final class CarouselSongFeed {
    let mode: ReviewMode
    let sortOrder: SortOrder
    /// Picked playlist/artist scope. `nil` → unscoped library/unsorted/dismissed
    /// browsing. When set, the feed loads the scope as a bounded one-shot set.
    let source: SourceScope?
    /// Whether dismissed tracks surface inside a scoped session. Only meaningful
    /// when `source != nil`; ignored otherwise.
    private let includeDismissedInScope: Bool
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

    /// Reentrancy guard for `loadNextLibraryPage`. `loadUntil` pages by calling
    /// it directly in a loop (bypassing the `pagingTask` single-flight gate), so
    /// without this a scroll-triggered `loadMoreIfNeeded` firing during a jump's
    /// `await` could run a second page against the same `libraryOffset` —
    /// appending the same page twice (duplicate ids in the carousel's ForEach)
    /// and skipping the next offset. The flag makes any overlapping call a
    /// no-op; the in-progress paging covers the work.
    private var isPagingPage = false

    private var libraryOffset: Int = 0
    private var exclusionSet: Set<String> = []

    /// Target songs per page. Tuned for the carousel: small enough that the
    /// first window arrives quickly, large enough that the user typically
    /// scrolls a noticeable distance before triggering the next page.
    private let pageSize: Int = 30

    /// Trigger threshold — when the centered index is within this many items
    /// of the loaded tail, kick off the next page.
    let prefetchDistance: Int = 8

    init(
        mode: ReviewMode,
        sortOrder: SortOrder,
        source: SourceScope? = nil,
        includeDismissedInScope: Bool = false,
        modelContext: ModelContext
    ) {
        self.mode = mode
        self.sortOrder = sortOrder
        self.source = source
        self.includeDismissedInScope = includeDismissedInScope
        self.modelContext = modelContext
        self.service = MusicLibraryService.shared
    }

    /// Loads the first window. Idempotent — re-entering the carousel won't
    /// re-fetch if songs are already present.
    func loadInitial() async {
        guard songs.isEmpty, !isExhausted else { return }
        // A picked scope short-circuits the mode paths — it's a bounded
        // collection regardless of which mode tile is nominally selected.
        if let source {
            await loadScope(source)
            isInitialLoading = false
            return
        }
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
        // Dismissed and scoped collections load their bounded set up front —
        // no incremental paging.
        guard source == nil, mode != .dismissed else { return }
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
        guard !isPagingPage else { return }
        isPagingPage = true
        defer { isPagingPage = false }

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

    /// Pages forward until a loaded cover reaches the date boundary, then
    /// returns its id for the carousel to snap to. The timeline is never
    /// re-seeded — pre-date covers stay loaded and browsable; this just scrubs
    /// the scroll position to the first cover added on/around `date`. The
    /// boundary is the first eligible song that is NOT in the pre-date prefix
    /// (newest-first → first added on/before the day; oldest-first → first
    /// added on/after it), using the same `libraryAddDateIsPrefix` rule the
    /// swipe session walks by. Returns the last loaded id if the library
    /// exhausts before the date is reached. Only called for library/unsorted
    /// feeds — the date control is hidden in Dismissed.
    func loadUntil(date: Date) async -> String? {
        // Drain any scroll-triggered page so the cursor isn't advanced from
        // two places at once.
        await pagingTask?.value

        func boundaryID() -> String? {
            songs.first {
                !libraryAddDateIsPrefix($0.libraryAddedDate, day: date, ascending: sortOrder.ascending)
            }?.id.rawValue
        }

        if let id = boundaryID() { return id }
        while !isExhausted {
            await loadNextLibraryPage()
            if let id = boundaryID() { return id }
        }
        return songs.last?.id.rawValue
    }

    // MARK: - Scoped (bounded, one-shot load)

    /// Loads a picked playlist/artist scope as a bounded set — the collection's
    /// full track list is small enough to resolve up front. Ordered via the
    /// shared `scopeSongs` (so it matches the hero deck and the swipe walk) and
    /// filtered by `scopeExclusionSet` (dismissed only, unless opted in — sorted
    /// stays visible). One-shot: `isExhausted` flips immediately so the carousel
    /// never asks for more.
    private func loadScope(_ source: SourceScope) async {
        let exclusion = service.scopeExclusionSet(
            includeDismissed: includeDismissedInScope,
            modelContext: modelContext
        )
        do {
            let ordered = try await service.scopeSongs(for: source, sortOrder: sortOrder)
            songs = ordered.filter { !exclusion.contains($0.id.rawValue) }
        } catch {
            print("CarouselSongFeed scope load failed: \(error)")
        }
        isExhausted = true
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
        let catalogIDs = Set(rows.filter(\.isCatalogTrack).map(\.songID))
        do {
            songs = try await service.resolveSongs(orderedIDs: ids, catalogIDs: catalogIDs)
            // `resolveSongs` pages the whole library for the non-catalog IDs,
            // so a library row it didn't return is authoritatively gone —
            // same prune the swipe deck runs, kept here so browsing dismissed
            // covers also heals stale rows. Inside the do-block on purpose: a
            // FAILED resolve proves nothing and must never prune.
            DismissedSongReconciler.pruneOrphans(
                rows: rows,
                resolvedIDs: Set(songs.map { $0.id.rawValue }),
                in: modelContext
            )
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
