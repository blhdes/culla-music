import Foundation
import Observation
import SwiftData
import MusicKit

// MARK: - HomeViewModel

// `@MainActor`: this view model reads and writes the main-actor-bound SwiftData
// `ModelContext` (handed in from `@Environment`) and mutates `@Observable` state
// the view renders. Without it, the nonisolated `async` methods below ran on a
// background thread and touched that context *off* its owning actor — and the
// heavy first-launch path (inserting every playlist, then `save()`) hung the
// app there, which is the cold-launch freeze. Main isolation keeps every
// context access on the context's actor; the library walks inside are
// await/IO-bound, so they still yield the run loop to the UI between pages.
@MainActor
@Observable
final class HomeViewModel {
    var dismissedCount: Int? = nil  // nil = computing
    var unsortedCount: Int? = nil   // nil = computing
    var libraryCount: Int? = nil    // nil = computing
    var playlists: [Playlist] = []

    private let modelContext: ModelContext

    /// Tracks the in-flight recompute kicked off by `triggerRecompute()`.
    /// Cancelling it before starting a new one prevents two full library
    /// walks from racing when the user flips the toggle in rapid succession.
    private var pendingRecompute: Task<Void, Never>?

    /// UserDefaults keys for the day-scoped count caches. Named once so a read
    /// site and its matching write site can't drift apart on a typo — a
    /// mismatch would silently disable the cache and re-walk the whole library
    /// on every launch. Internal (not private) because Insights reads the
    /// cached library count too, for its coverage bar.
    enum CacheKey {
        static let libraryDate = "music.libraryCountDate"
        static let libraryFingerprint = "music.libraryCountFingerprint"
        static let libraryValue = "music.libraryCountCached"
        static let unsortedDate = "music.unsortedCountDate"
        static let unsortedFingerprint = "music.unsortedCountFingerprint"
        static let unsortedValue = "music.unsortedCountCached"
    }

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func loadCounts(onReady: (() -> Void)? = nil) async {
        // Local SwiftData fetch — paint the dismissed card immediately
        // instead of waiting on the Apple Music playlist sync round-trip.
        // Active rows only: voided rows (song deleted from the library) are
        // History tombstones and must not inflate the badge.
        let dismissedSnapshot = (try? modelContext.fetchCount(
            FetchDescriptor<DismissedSong>(predicate: DismissedSong.activePredicate)
        )) ?? 0
        dismissedCount = dismissedSnapshot
        await syncPlaylistsFromAppleMusic()
        // Playlists are in — Home can render real content now, so let the
        // launch splash dismiss. The library/unsorted walk below is unbounded
        // on a first launch and has its own in-card loaders, so we don't hold
        // the brand screen for it.
        onReady?()
        // Route through the cancellable slot so a toggle-flip arriving
        // mid-cold-start cancels this walk instead of racing it for the
        // cache. Previously the initial walk wasn't cancellable, so its
        // late write could clobber the toggled fingerprint's fresh value.
        triggerRecompute()
        await pendingRecompute?.value
    }

    /// Recomputes (or reads from cache) the library and unsorted counts. Both
    /// modes need to walk the full library on a cache miss, so we do it in a
    /// single pass and tally each count from the same iteration.
    ///
    /// Both counts share one fingerprint — Sorted/Dismissed counts + the
    /// calendar day — and are cached under separate keys because the two
    /// cached values are different numbers. A change to either snapshot, or a
    /// new day, invalidates both.
    func recomputeCounts() async {
        let sortedSnapshot = (try? modelContext.fetchCount(FetchDescriptor<SortedSong>())) ?? 0
        // ALL rows, voided included — the library walk below reconciles
        // `voidedAt` both ways (voids deleted songs, un-voids re-added ones),
        // so it needs the full set. The published count only tallies active.
        let dismissedRows = (try? modelContext.fetch(FetchDescriptor<DismissedSong>())) ?? []
        let dismissedSnapshot = dismissedRows.filter { $0.voidedAt == nil }.count
        dismissedCount = dismissedSnapshot
        let today = todayString()

        // One fingerprint, two cache slots (the values differ: library vs unsorted).
        // `var`: pruning orphaned dismissals after the walk shrinks the dismissed
        // count, and the corrected fingerprint is what must land in the cache.
        // "v3": versioned so a build that changes reconcile behavior forces one
        // fresh walk — a same-day cache written by the previous build would
        // otherwise skip the walk and the new reconcile logic with it (how the
        // bogus-flag heal sat idle behind a fresh cache for a whole day).
        // v3 = catalogPresence learned to read Apple's 404 as a verdict.
        var fingerprint = "v3:\(sortedSnapshot):\(dismissedSnapshot)"

        // Library cache.
        let libraryCachedDate = UserDefaults.standard.string(forKey: CacheKey.libraryDate) ?? ""
        let libraryCachedFP = UserDefaults.standard.string(forKey: CacheKey.libraryFingerprint) ?? ""
        let libraryCachedValue = UserDefaults.standard.integer(forKey: CacheKey.libraryValue)
        let libraryFresh = (libraryCachedDate == today && libraryCachedFP == fingerprint)

        // Unsorted cache.
        let unsortedCachedDate = UserDefaults.standard.string(forKey: CacheKey.unsortedDate) ?? ""
        let unsortedCachedFP = UserDefaults.standard.string(forKey: CacheKey.unsortedFingerprint) ?? ""
        let unsortedCachedValue = UserDefaults.standard.integer(forKey: CacheKey.unsortedValue)
        let unsortedFresh = (unsortedCachedDate == today && unsortedCachedFP == fingerprint)

        if libraryFresh { libraryCount = libraryCachedValue }
        if unsortedFresh { unsortedCount = unsortedCachedValue }

        guard !libraryFresh || !unsortedFresh else { return }

        // Cache miss — only show the loader if we have nothing to show yet.
        // If we already have a stale value, keep it visible during recompute
        // to avoid a count → loader → same-count flicker on toggle/invalidate.
        // The fresh value overwrites it when the walk completes.

        do {
            // Only fetch playlist memberships when unsorted needs them — saves
            // the round-trip on a toggle-only or library-only invalidation.
            let playlistIDs: Set<String>
            if !unsortedFresh {
                playlistIDs = try await MusicLibraryService.shared.fetchPlaylistSongIDs(
                    includeCurated: true
                )
            } else {
                playlistIDs = []
            }
            let sortedIDs = Set((try? modelContext.fetch(FetchDescriptor<SortedSong>()))?.map(\.songID) ?? [])
            let dismissedIDs = Set(dismissedRows.map(\.songID))
            // Unsorted = "still needs a decision": not in any playlist, not
            // already sorted, and not dismissed. Dismissed must be excluded
            // here — otherwise the unsorted cache fingerprint (which includes
            // dismissedSnapshot) invalidates without the count ever changing.
            let unsortedExclusion = playlistIDs.union(sortedIDs).union(dismissedIDs)
            let libraryExclusion = sortedIDs.union(dismissedIDs)

            var libCount = 0
            var unsCount = 0
            // Dismissed IDs actually encountered during the walk. Whatever is
            // left over afterwards no longer exists in the library.
            var seenDismissedIDs: Set<String> = []
            let pageSize = 100
            var offset = 0

            while true {
                try Task.checkCancellation()
                var request = MusicLibraryRequest<Song>()
                request.limit = pageSize
                request.offset = offset
                let response = try await request.response()
                let page = response.items

                for song in page {
                    let id = song.id.rawValue
                    if dismissedIDs.contains(id) {
                        seenDismissedIDs.insert(id)
                    }
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

            // The loop paged the ENTIRE library, so it's authoritative: a
            // non-catalog dismissed row whose song never appeared was deleted
            // from the library in Music. Reconcile `voidedAt` off that — voids
            // the deleted ones (they live on only as History tombstones),
            // un-voids any whose song came back — and fold the corrected
            // active count into the fingerprint BEFORE it's cached, so the
            // next recompute doesn't see a mismatch and re-walk the library
            // for nothing. (Voided rows never appeared in the walk, so
            // libCount/unsCount are unaffected either way.)
            //
            // `offset > 0` = the walk saw at least one song. A zero-song walk
            // is refused as evidence, same as SortedSongReconciler refuses an
            // empty membership map: on a cold open the library can read back
            // empty before it has synced, and voiding every dismissal against
            // that would grey out real records. The genuinely emptied-library
            // case is an accepted false-negative — rare, and the next
            // non-empty walk self-heals it.
            if offset > 0 {
                // Ground truth for the console when a phantom row survives:
                // every active row the full walk did NOT see, with the state
                // that decides which reconcile pass owns it.
                for row in dismissedRows where row.voidedAt == nil && !seenDismissedIDs.contains(row.songID) {
                    print("DismissedAudit: unresolved active row id=\(row.songID) catalog=\(row.isCatalogTrack) title=\(row.snapshotTitle ?? "-") dismissedAt=\(row.dismissedAt)")
                }
                DismissedSongReconciler.reconcile(
                    rows: dismissedRows,
                    resolvedIDs: seenDismissedIDs,
                    in: modelContext
                )
                // Catalog-flagged rows dodged the pass above by design; judge
                // the survivors (post-heal, so "i."-prefixed rows are already
                // out) on dual evidence: a strict catalog lookup plus this
                // walk's full library sweep. Nowhere = voided; back in either
                // store = un-voided. The lookup throwing means "proved
                // nothing" — the rows just wait for the next walk.
                let catalogRows = dismissedRows.filter(\.isCatalogTrack)
                if !catalogRows.isEmpty {
                    do {
                        let catalogPresent = try await MusicLibraryService.shared.catalogPresence(
                            ids: catalogRows.map(\.songID)
                        )
                        DismissedSongReconciler.reconcileCatalogRows(
                            rows: catalogRows,
                            catalogResolvedIDs: catalogPresent,
                            libraryResolvedIDs: seenDismissedIDs,
                            in: modelContext
                        )
                    } catch {
                        print("Dismissed catalog evidence pass failed: \(error)")
                    }
                }
                let activeAfter = dismissedRows.filter { $0.voidedAt == nil }.count
                if activeAfter != dismissedSnapshot {
                    dismissedCount = activeAfter
                    fingerprint = "v3:\(sortedSnapshot):\(activeAfter)"
                }
            }

            if !libraryFresh {
                libraryCount = libCount
                UserDefaults.standard.set(libCount, forKey: CacheKey.libraryValue)
                UserDefaults.standard.set(today, forKey: CacheKey.libraryDate)
                UserDefaults.standard.set(fingerprint, forKey: CacheKey.libraryFingerprint)
            }
            if !unsortedFresh {
                unsortedCount = unsCount
                UserDefaults.standard.set(unsCount, forKey: CacheKey.unsortedValue)
                UserDefaults.standard.set(today, forKey: CacheKey.unsortedDate)
                UserDefaults.standard.set(fingerprint, forKey: CacheKey.unsortedFingerprint)
            }
        } catch is CancellationError {
            // A newer recompute superseded this one — leave the counts as
            // they are. The replacement task will write the up-to-date values.
            return
        } catch {
            print("Recompute counts failed: \(error)")
        }
    }

    /// Kick off a recompute that cancels any prior in-flight one. Use this
    /// from event handlers (e.g. toggle changes) where rapid re-entry is
    /// possible. Internal callers that need to await completion should call
    /// `recomputeCounts()` directly.
    func triggerRecompute() {
        pendingRecompute?.cancel()
        // The class is @MainActor, so this task inherits main isolation. The
        // old `@MainActor` on the closure *looked* like it pinned the recompute
        // to main but didn't — calling a then-nonisolated async method hopped
        // straight back off the actor.
        pendingRecompute = Task { [weak self] in
            await self?.recomputeCounts()
        }
    }

    /// Fixed locale + calendar so the cache key is stable across users with
    /// Persian/Hebrew/Buddhist calendars or non-Arabic numerals. Built once —
    /// the format is constant, so there's no reason to reallocate per call.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    private func todayString() -> String {
        Self.dayFormatter.string(from: .now)
    }

    private func syncPlaylistsFromAppleMusic() async {
        do {
            // Shared routine (PlaylistSyncer) — same sync the swipe session
            // runs, so Home also demotes playlists that turned read-only and
            // the session also prunes deleted ones; the two inline copies had
            // drifted apart. No sidebar seeding here — that decision stays
            // with the first swipe session, as before.
            playlists = try await PlaylistSyncer.sync(modelContext: modelContext)
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
