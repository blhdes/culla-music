import SwiftUI
import SwiftData
import MusicKit
import LinkPresentation

struct MusicSwipeView: View {
    @Bindable var viewModel: MusicSwipeViewModel
    var onBack: (() -> Void)?
    /// Shared namespace for the Home → Swipe hero morph. Only the *current*
    /// card receives it — the preloaded next card never participates, so
    /// SwiftUI never sees two simultaneous sources for `heroStart`.
    var heroNamespace: Namespace.ID?
    /// True once the Home → Swipe hero morph has finished. Driven from
    /// `RootView` via `withAnimation(completion:)` so the play button's
    /// reveal is a consequence of the spring actually landing, not a fixed
    /// timer. Forwarded to the current `SongCardView` as `chromeRevealed`.
    var chromeRevealed: Bool = true

    @AppStorage("useDynamicAccent") private var useDynamicAccent: Bool = true
    /// When on (default), each new card's preview starts automatically on
    /// arrival — session entry and every swipe. The Settings toggle flips it
    /// off without disturbing what's currently playing; the policy only
    /// applies to *future* card changes.
    @AppStorage("autoplayOnSwipe") private var autoplayOnSwipe: Bool = true

    /// One-time discovery hint for the long-press cleanup menu. Flips to true
    /// the first time the user successfully long-presses in Dismissed mode (or
    /// taps the banner's close button).
    @AppStorage("hasSeenDismissedLongPressTip") private var hasSeenDismissedLongPressTip: Bool = false

    /// The swipe sidebar inherits whatever sort the user picked for the Sidebar
    /// segment in `ManagePlaylistsSheet` — same `@AppStorage` keys, read here so
    /// changing the sort there reorders the live sidebar. Default `sidebarOrder`
    /// keeps the as-added `displayOrder`, so nothing reshuffles out of the box.
    @AppStorage("managePlaylists.sidebarSortField") private var sidebarSortFieldRaw = SidebarSortField.sidebarOrder.rawValue
    @AppStorage("managePlaylists.sidebarSortDescending") private var sidebarSortDescending = false

    @Environment(\.appAccent) private var paletteAccent

    // Dynamic accent pair sampled from the current song's artwork. Nil → fall
    // back to the palette accent so the UI never goes uncolored.
    @State private var dynamicAccent: ArtworkAccent?

    // Drag state
    @State private var cardOffset: CGSize = .zero
    @State private var highlightedID: UUID?
    @State private var playlistFrames: [UUID: CGRect] = [:]

    // True while the user is scrubbing the progress bar. `cardDragSuppressed`
    // latches that fact for the lifetime of the card's own drag gesture, so the
    // whole gesture — onChanged *and* onEnded — is ignored and a scrub can never
    // be misread as a dismiss/assign swipe.
    @State private var isScrubbing = false
    @State private var cardDragSuppressed = false

    // Long-press preview — fully reveals the sidebar while held
    @State private var isLongPressing = false

    // Sheet
    @State private var showManageSheet = false
    /// Snapshot of the queue-filter set taken the instant `showManageSheet`
    /// flips on. Compared on dismiss; a difference triggers `viewModel.reload()`
    /// so the deck honors the new exclusion immediately. Snapshotting at the
    /// chrome layer (here) rather than passing a callback into the sheet keeps
    /// the sheet ignorant of who reloads — same pattern would work if a future
    /// settings surface edits the filter too.
    @State private var filterSnapshotOnOpen: Set<String> = []

    /// Artist hub sheet — non-nil identifies the song whose artist we want to
    /// inspect. `.sheet(item:)` re-keys on the song's id, so opening the hub
    /// on a different card after dismissal cleanly re-resolves instead of
    /// flashing stale state from the prior song.
    @State private var artistSheetSong: Song?

    /// Share sheet — non-nil presents the system share sheet for the current
    /// song (swipe DOWN). Mirrors the photo app's swipe-down-to-share, but the
    /// shared payload is the song's Apple Music link, not an image.
    @State private var shareItem: SongShareItem?

    // Destructive long-press menu in Dismissed mode
    @State private var showRemovalSheet = false

    @Environment(\.openURL) private var openURL

    // Toast / undo timers
    @State private var toastTimer: Task<Void, Never>?
    @State private var showUndo = false
    @State private var undoHideTask: Task<Void, Never>?
    /// Cancellation handle for the in-flight fly-off hand-off. A second
    /// flyOff (e.g. rapid double-tap-to-skip) cancels the prior so its
    /// scheduled slide-back doesn't fire after the new card is in place.
    @State private var flyOffTask: Task<Void, Never>?

    private let swipeThreshold: CGFloat = 100

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            if !viewModel.isLoading {
                if viewModel.isEmpty {
                    EmptyStateView(onRefresh: { Task { await viewModel.reload() } })
                        .transition(.opacity)
                } else {
                    swipeContent
                        .transition(.opacity)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if let onBack {
                Button {
                    // Cut the preview the instant the user taps back — the
                    // exit spring runs ~0.55s, and `.onDisappear` only fires
                    // at the end of it. Without this explicit stop the
                    // user hears their song bleed into the Home transition.
                    MusicLibraryService.shared.stopPreview()
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.medium))
                        .frame(width: 24, height: 24)
                        .padding(10)
                        // Explicit hit shape BEFORE the glass effect — without
                        // it, iOS 26's `.glassEffect(in: Circle())` was
                        // shrinking the tappable area to the inscribed circle,
                        // so taps near the corners of the visible button
                        // missed. Matches the settings-gear pattern.
                        .contentShape(Rectangle())
                        .glassSurface(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)
                .padding(.top, 8)
                .opacity(chromeOpacity)
                // Stay hittable even when chromeOpacity drives the visual to
                // zero during a right-swipe — opacity 0 still receives taps
                // in SwiftUI, but layering this above the card stack removes
                // any chance the drag gesture claims an edge-case tap first.
                .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.45), value: viewModel.isLoading)
        .animation(.easeOut(duration: 0.35), value: viewModel.isEmpty)
        .environment(\.appAccent, effectiveAccent.primary)
        .environment(\.appAccentSecondary, effectiveAccent.secondary)
        .environment(\.appAccentNeutral, effectiveAccent.neutralTint)
        .sheet(isPresented: $showManageSheet) {
            ManagePlaylistsSheet(viewModel: viewModel)
        }
        .sheet(item: $artistSheetSong) { song in
            ArtistDetailSheet(song: song)
        }
        .sheet(item: $shareItem) { item in
            SongShareSheet(url: item.url, title: item.title)
        }
        .task(id: viewModel.currentSong?.id.rawValue) {
            // Autoplay fires first because it's synchronous — audio kicks off
            // the same frame the new card is presented, then the accent
            // extraction continues in the background. Re-fires on every
            // current-song change (session entry, swipe, undo).
            autoplayCurrentIfEnabled()
            await refreshDynamicAccent()
        }
        .task(id: viewModel.nextSong?.id.rawValue) {
            // Warm the accent cache for the upcoming card so its color
            // transition is instant when it slides in. Result is discarded —
            // we just want the cache populated before refreshDynamicAccent
            // asks for it.
            guard useDynamicAccent, let next = viewModel.nextSong else { return }
            _ = await AccentExtractor.shared.accent(for: next)
        }
        .onChange(of: useDynamicAccent) { _, enabled in
            if !enabled {
                withAnimation(.easeInOut(duration: 0.35)) { dynamicAccent = nil }
            } else {
                Task { await refreshDynamicAccent() }
            }
        }
        .onChange(of: viewModel.actionCount) { _, _ in
            flashUndo()
        }
        .onChange(of: showManageSheet) { _, isOpen in
            if isOpen {
                filterSnapshotOnOpen = QueueFilterStore.read()
            } else if QueueFilterStore.read() != filterSnapshotOnOpen {
                // Filter changed — rebuild the deck so freshly-excluded
                // playlists drop out of the queue (and previously-excluded
                // ones return) without waiting for the next session start.
                Task { await viewModel.reload() }
            }
        }
        .onChange(of: viewModel.toastMessage) { _, message in
            guard message != nil else { return }
            toastTimer?.cancel()
            let duration: Duration = viewModel.toastUndoable ? .seconds(6) : .seconds(1.4)
            toastTimer = Task {
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.3)) {
                        viewModel.toastMessage = nil
                        viewModel.toastUndoable = false
                    }
                }
            }
        }
        // Safety net for any exit path that bypasses the back button (e.g.
        // a future swipe-to-dismiss gesture, or programmatic teardown).
        // Idempotent — `stopPreview` is a no-op when nothing is playing.
        .onDisappear {
            MusicLibraryService.shared.stopPreview()
        }
    }

    // MARK: - Content

    /// `viewModel.sidebarPlaylists` (the in-sidebar set, in `displayOrder`)
    /// reordered by the user's saved Sidebar sort. `.sidebarOrder` maps to a nil
    /// field, so the shared sorter returns that displayOrder untouched.
    private var orderedSidebarPlaylists: [Playlist] {
        let field = SidebarSortField(rawValue: sidebarSortFieldRaw) ?? .sidebarOrder
        return viewModel.sidebarPlaylists.sortedBy(
            field: field.playlistField,
            descending: sidebarSortDescending
        ) {
            viewModel.membershipIndex.trackCount(forPlaylistAMID: $0.appleMusicPlaylistID) ?? 0
        }
    }

    @ViewBuilder
    private var swipeContent: some View {
        GeometryReader { geo in
            cardStackWithGestures
                .overlay {
                    let progress = isLongPressing ? 1.0 : sidebarProgress
                    HStack(spacing: 0) {
                        Spacer()
                        PlaylistSidebarView(
                            playlists: orderedSidebarPlaylists,
                            highlightedID: highlightedID,
                            dragProgress: progress
                        )
                        .frame(width: geo.size.width * 0.8)
                        .offset(x: (1.0 - progress) * 80)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .onPreferenceChange(PlaylistFramePreferenceKey.self) { frames in
                        playlistFrames = frames
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    manageButton
                        .padding(.leading, 16)
                        .padding(.bottom, 16)
                        .opacity(chromeOpacity)
                }
        }
        .overlay(alignment: .top) {
            if let toast = viewModel.toastMessage {
                toastCapsule(message: toast)
                    .padding(.top, 12)
                    .opacity(chromeOpacity)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            }
        }
        .overlay(alignment: .bottom) {
            undoButton
                .padding(.bottom, 32)
                .opacity(chromeOpacity)
        }
        .overlay(alignment: .top) {
            if shouldShowDismissedLongPressTip {
                dismissedLongPressTip
                    .padding(.top, 60)
                    .padding(.horizontal, 20)
                    .opacity(chromeOpacity)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var shouldShowDismissedLongPressTip: Bool {
        viewModel.config.mode == .dismissed
            && !hasSeenDismissedLongPressTip
            && !viewModel.isEmpty
            && !viewModel.isLoading
    }

    @ViewBuilder
    private var dismissedLongPressTip: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.tap.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Long-press a card for cleanup options")
                .font(.footnote)
                .foregroundStyle(.primary)
            Button {
                withAnimation(.easeOut(duration: 0.25)) {
                    hasSeenDismissedLongPressTip = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassSurface(in: Capsule())
    }

    /// Card stack with the right gesture set for the current mode. Dismissed
    /// mode swaps the long-press sidebar preview for a `.contextMenu` so the
    /// destructive long-press menu can fire without competing with a 0.3s
    /// LongPressGesture claiming the touch first.
    @ViewBuilder
    private var cardStackWithGestures: some View {
        let base = cardStack
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                flyOff(y: 700) {
                    viewModel.skipCurrent()
                    Haptics.skip()
                }
            }
            .highPriorityGesture(dragGesture)

        if viewModel.config.mode == .dismissed {
            base
                // `contentShape(.contextMenuPreview, …)` defines the shape iOS
                // uses for the press-in lift, separately from the view's hit
                // area. Without it, the lift snapshots the full-bleed
                // SongCardView (which `.ignoresSafeArea()`s) and clips
                // against the screen edges. A rounded rect over the whole
                // card gives a clean card-like silhouette. We can't shrink
                // it to just the cover — iOS clips the entire source view
                // to this shape during the press, which would hide the
                // title/artist/chips for the duration of the hold.
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 28))
                .contextMenu {
                    dismissedMenuItems
                } preview: {
                    if let current = viewModel.currentSong {
                        removalPreview(
                            song: current,
                            memberships: viewModel.playlistMemberships(for: current)
                        )
                    }
                }
                .simultaneousGesture(
                    // Fires alongside the system context menu's own long-press
                    // recognizer. 0.45s lines up with when the menu actually
                    // appears, so the heavy impact reads as the menu's own
                    // opening feedback. Doubles as the signal to retire the
                    // one-time discoverability tip.
                    LongPressGesture(minimumDuration: 0.45)
                        .onEnded { _ in
                            Haptics.contextMenuOpen()
                            if !hasSeenDismissedLongPressTip {
                                withAnimation(.easeOut(duration: 0.3)) {
                                    hasSeenDismissedLongPressTip = true
                                }
                            }
                        }
                )
                .sheet(isPresented: $showRemovalSheet) {
                    if let current = viewModel.currentSong {
                        RemoveFromPlaylistsSheet(
                            song: current,
                            memberships: viewModel.playlistMemberships(for: current),
                            onRemove: { selected in
                                viewModel.removeFromPlaylists(selected)
                            }
                        )
                    }
                }
        } else {
            base.gesture(longPressGesture)
        }
    }

    /// Shown above the dismissed-mode context menu so the user can see what
    /// they're about to act on — the song plus every playlist it lives in —
    /// before tapping "Remove from all".
    @ViewBuilder
    private func removalPreview(song: Song, memberships: [Playlist]) -> some View {
        VStack(spacing: 14) {
            if let artwork = song.artwork {
                ArtworkImage(artwork, width: 140, height: 140)
                    .frame(width: 140, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            VStack(spacing: 4) {
                Text(song.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(song.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if memberships.isEmpty {
                Text("Not in any of your playlists")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    Text("In \(memberships.count) playlist\(memberships.count == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(memberships.map(\.name).joined(separator: " · "))
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 320)
    }

    @ViewBuilder
    private var dismissedMenuItems: some View {
        if let current = viewModel.currentSong {
            let memberships = viewModel.playlistMemberships(for: current)
            if !memberships.isEmpty {
                Button(role: .destructive) {
                    showRemovalSheet = true
                } label: {
                    Label(
                        "Remove from playlists… (\(memberships.count))",
                        systemImage: "trash"
                    )
                }
            }
            Button {
                viewModel.forgetCurrentDismissal()
            } label: {
                Label("Forget dismissal", systemImage: "tray.and.arrow.up")
            }
            Button {
                openSongInAppleMusic(current)
            } label: {
                Label("Open in Apple Music", systemImage: "arrow.up.right.square")
            }
        }
    }

    private func openSongInAppleMusic(_ song: Song) {
        if let url = song.url {
            openURL(url)
        } else {
            viewModel.toastMessage = "Couldn't open in Apple Music"
        }
    }

    @ViewBuilder
    private var cardStack: some View {
        ZStack {
            // Next card (behind, no interaction)
            if let next = viewModel.nextSong {
                SongCardView(
                    song: next,
                    offset: .zero,
                    isPlaying: false,
                    playbackPosition: 0,
                    playbackDuration: 0,
                    memberships: viewModel.playlistMemberships(for: next),
                    isLoadingMemberships: viewModel.membershipIndex.showsLoadingPlaceholder,
                    dismissedAt: viewModel.dismissedDate(for: next),
                    onTogglePlay: {},
                    onSeek: { _ in }
                )
                .id(next.id.rawValue)
                .allowsHitTesting(false)
            }

            // Opaque divider — hides next card at rest, revealed as the current card slides
            Color(.systemBackground).ignoresSafeArea()

            if let current = viewModel.currentSong {
                let service = MusicLibraryService.shared
                // "Loaded" = this card's song is the one the player holds, whether
                // it's actively playing or paused. We feed position/duration for
                // the whole loaded lifetime so the bar can stay visible (dimmed)
                // while paused; `isPlaying` alone drives the play/pause icon.
                let isLoadedSong = service.nowPlayingSongID == current.id.rawValue
                let isPlayingThis = service.isPlayingPreview && isLoadedSong

                SongCardView(
                    song: current,
                    offset: cardOffset,
                    isPlaying: isPlayingThis,
                    playbackPosition: isLoadedSong ? service.playbackPosition : 0,
                    playbackDuration: isLoadedSong ? service.playbackDuration : 0,
                    memberships: viewModel.playlistMemberships(for: current),
                    isLoadingMemberships: viewModel.membershipIndex.showsLoadingPlaceholder,
                    dismissedAt: viewModel.dismissedDate(for: current),
                    onTogglePlay: { viewModel.togglePreview() },
                    onSeek: { service.seek(to: $0) },
                    onShowArtist: { artistSheetSong = current },
                    onScrubbingChanged: { isScrubbing = $0 },
                    heroNamespace: heroNamespace,
                    chromeRevealed: chromeRevealed
                )
                .id(current.id.rawValue)
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .identity
                ))
            }
        }
    }

    // MARK: - Long Press

    private var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .onEnded { _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isLongPressing = true
                }
            }
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onEnded { _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isLongPressing = false
                }
            }
    }

    // MARK: - Drag

    private var dragGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                // A scrub on the progress bar must not sort the card. Once a
                // scrub is live, latch the whole drag as suppressed and keep the
                // card pinned at rest — the bar's own gesture handles seeking.
                if isScrubbing || cardDragSuppressed {
                    cardDragSuppressed = true
                    if cardOffset != .zero { cardOffset = .zero }
                    return
                }
                cardOffset = value.translation
                let dx = value.translation.width
                let dy = value.translation.height
                // Once the finger is inside the sidebar, keep highlighting the
                // row underneath even if motion turns vertical — the user is
                // sliding between rows, not signaling a Loved swipe.
                if isLocationInSidebar(value.location) || (dx > 30 && abs(dx) >= abs(dy)) {
                    highlightedID = findPlaylist(at: value.location)
                } else {
                    highlightedID = nil
                }
            }
            .onEnded { value in
                // Suppressed means this drag was a scrub — consume it without
                // firing any swipe action, then re-arm for the next gesture.
                if cardDragSuppressed {
                    cardDragSuppressed = false
                    return
                }
                handleSwipeEnd(value)
            }
    }

    private func handleSwipeEnd(_ value: DragGesture.Value) {
        let tx = value.translation.width
        let ty = value.translation.height
        let ptx = value.predictedEndTranslation.width
        let pty = value.predictedEndTranslation.height

        // Empty-sidebar shortcut: the user dragged far enough to reveal the
        // "Add playlists" tile, and they have no sidebar playlists to drop
        // into. Treat the release as their entry into Manage — the only
        // useful next action — instead of a silent snap-back. Without this
        // a first-time user has no in-context path forward; the bottom-left
        // Manage button is hidden during drag.
        if viewModel.sidebarPlaylists.isEmpty && sidebarProgress > 0.5 {
            snapBack()
            Haptics.tap()
            showManageSheet = true
            return
        }

        // Sidebar claims the gesture: while the finger is parked over a
        // playlist row, only right-swipe-onto-playlist applies. Vertical
        // motion across rows must not trigger Loved or Dismiss.
        if isLocationInSidebar(value.location) {
            if let id = findPlaylist(at: value.location),
               let playlist = viewModel.sidebarPlaylists.first(where: { $0.id == id }),
               tx > swipeThreshold || ptx > swipeThreshold {
                flyOff(x: 500) {
                    viewModel.assignToPlaylist(playlist)
                    Haptics.sidebarDrop()
                }
                return
            }
            snapBack()
            return
        }

        // Direction lock — pick the dominant axis from whichever value (actual
        // or predicted) crossed the threshold first. Prevents a fast right-up
        // flick from cross-triggering Loved when the user meant playlist-add.
        let horizontalMagnitude = max(abs(tx), abs(ptx))
        let verticalMagnitude = max(abs(ty), abs(pty))
        let horizontalDominant = horizontalMagnitude >= verticalMagnitude

        // Up swipe — Loved. Requires vertical to be dominant.
        if !horizontalDominant, ty < -swipeThreshold || pty < -swipeThreshold {
            flyOff(y: -700) {
                viewModel.loveCurrent()
                Haptics.loved()
            }
            return
        }

        // Down swipe — Share. Requires vertical to be dominant. The card stays
        // put (snap back) rather than flying off: sharing isn't a sort action,
        // so the same song should still be on screen behind the share sheet.
        if !horizontalDominant, ty > swipeThreshold || pty > swipeThreshold {
            snapBack()
            Haptics.share()
            presentShareForCurrent()
            return
        }

        // Right swipe — assign to highlighted playlist
        if horizontalDominant, tx > swipeThreshold || ptx > swipeThreshold {
            if let id = highlightedID,
               let playlist = viewModel.sidebarPlaylists.first(where: { $0.id == id }) {
                flyOff(x: 500) {
                    viewModel.assignToPlaylist(playlist)
                    Haptics.sidebarDrop()
                }
                return
            }
            // Right swipe with no target highlighted — snap back, no action
            snapBack()
            return
        }

        // Left swipe — dismiss
        if horizontalDominant, tx < -swipeThreshold || ptx < -swipeThreshold {
            flyOff(x: -500) {
                viewModel.dismissCurrent()
                Haptics.swipeLeft()
            }
            return
        }

        snapBack()
    }

    /// True when `point` sits inside the sidebar's row region AND the sidebar
    /// is actually revealed. The progress gate is essential: at rest the row
    /// frames still occupy the right ~60% of the screen (the panel is parked
    /// offscreen by only 80pt), so without it any up-swipe ending on the
    /// right half of the card would be incorrectly claimed as a sidebar
    /// gesture and Loved would never fire.
    private func isLocationInSidebar(_ point: CGPoint) -> Bool {
        guard isLongPressing || sidebarProgress > 0,
              let leftEdge = playlistFrames.values.map(\.minX).min() else { return false }
        return point.x >= leftEdge
    }

    private func flyOff(x: CGFloat = 0, y: CGFloat = 0, action: @escaping () -> Void) {
        // easeOut continues the drag's velocity instead of restarting from rest —
        // easeIn paused at the release point before accelerating, which made
        // partial drags look like two separate motions.
        let flyDuration: Double = 0.18
        let slideInDuration: Double = 0.25
        // Pre-divide y by the card's vertical damping so the up-swipe actually
        // clears the screen — otherwise the card only travels 40% of the
        // requested distance and the next song appears to snap in instead of
        // sliding, while the right-swipe (undampened) reads as a clean
        // transition. The slide-back-to-zero then mirrors the right-swipe by
        // pulling the new card in from off-screen.
        let targetY = y / SongCardView.yVisualDamping
        withAnimation(.easeOut(duration: flyDuration)) {
            cardOffset = CGSize(width: x, height: targetY)
        }
        // Cancellable hand-off: a fresh flyOff (rapid double-tap, gesture
        // collision) cancels the prior, so its slide-back doesn't snap the
        // new card's offset back to zero a beat after it's already in place.
        flyOffTask?.cancel()
        flyOffTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(flyDuration))
            guard !Task.isCancelled else { return }
            highlightedID = nil
            withAnimation(.easeOut(duration: slideInDuration)) {
                cardOffset = .zero
                action()
            }
        }
    }

    private func snapBack() {
        withAnimation(.interpolatingSpring(stiffness: 150, damping: 15)) {
            cardOffset = .zero
        }
        highlightedID = nil
    }

    // MARK: - Share

    /// Builds the share payload for the current song and triggers the sheet.
    /// Sharing a song means sharing its Apple Music link — `song.url` when the
    /// catalog gave us one, otherwise an Apple Music *search* link (the same
    /// fallback the Artist hub uses), so library-only songs still share a
    /// link that opens the right place.
    private func presentShareForCurrent() {
        guard let song = viewModel.currentSong else { return }
        shareItem = SongShareItem(
            url: appleMusicURL(for: song),
            title: "\(song.title) · \(song.artistName)"
        )
    }

    private func appleMusicURL(for song: Song) -> URL {
        if let url = song.url { return url }
        var components = URLComponents(string: "https://music.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(song.title) \(song.artistName)")
        ]
        return components?.url ?? URL(string: "https://music.apple.com")!
    }

    // MARK: - Dynamic accent

    private var effectiveAccent: ArtworkAccent {
        if useDynamicAccent, let dynamicAccent { return dynamicAccent }
        return .flat(paletteAccent)
    }

    private func refreshDynamicAccent() async {
        guard useDynamicAccent, let song = viewModel.currentSong else { return }
        let extracted = await AccentExtractor.shared.accent(for: song)
        // Bail if the song changed under us while we were sampling.
        guard viewModel.currentSong?.id.rawValue == song.id.rawValue else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            dynamicAccent = extracted
        }
    }

    /// Starts the current card's preview when `autoplayOnSwipe` is on, unless
    /// it's already playing. The "already playing" guard avoids a tear-and-
    /// restart click when the user lands on the swipe view with a preview
    /// the carousel started (same song, no reason to reset playback).
    /// Toggling the setting off mid-session doesn't stop a playing track —
    /// the policy only affects subsequent card arrivals.
    private func autoplayCurrentIfEnabled() {
        guard autoplayOnSwipe, let song = viewModel.currentSong else { return }
        let service = MusicLibraryService.shared
        if service.isPlayingPreview, service.nowPlayingSongID == song.id.rawValue {
            return
        }
        service.playPreview(for: song)
    }

    // MARK: - Helpers

    private var rightDragProgress: CGFloat {
        min(max(cardOffset.width / swipeThreshold, 0), 1.0)
    }

    /// Deadzoned, ramped progress used to drive the sidebar reveal.
    /// Stays at 0 until the user has clearly committed to a right-swipe,
    /// so the sidebar doesn't crowd the card on small drags.
    private var sidebarProgress: CGFloat {
        let deadzone: CGFloat = 0.35
        guard rightDragProgress > deadzone else { return 0 }
        return min((rightDragProgress - deadzone) / (1.0 - deadzone), 1.0)
    }

    private var chromeOpacity: Double {
        if isLongPressing { return 0 }
        return Double(1.0 - rightDragProgress)
    }

    private func findPlaylist(at point: CGPoint) -> UUID? {
        for (id, frame) in playlistFrames where frame.contains(point) {
            return id
        }
        return nil
    }

    @ViewBuilder
    private var manageButton: some View {
        Button {
            showManageSheet = true
        } label: {
            Text("Manage")
                .font(.footnote.weight(.regular))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassSurface(in: Capsule(), interactive: true)
                .opacity(0.85)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func toastCapsule(message: String) -> some View {
        // A pure status pill — undo lives in the single bottom Undo button so
        // it isn't duplicated here. Single line + tail truncation keeps every
        // toast the same slim height; the long "Added to <playlist>" case just
        // clips (the playlist was tapped a moment ago, so context is fresh).
        Text(message)
            .font(.footnote.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.opacity)
            .padding(.horizontal, 12)
            .padding(.vertical, 6.5)
            .frame(maxWidth: 260)
            .glassSurface(in: Capsule())
            .animation(.easeInOut(duration: 0.2), value: message)
    }

    @ViewBuilder
    private var undoButton: some View {
        if viewModel.canUndo, showUndo {
            Button {
                Haptics.undo()
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.undo()
                }
                flashUndo()
            } label: {
                let count = viewModel.actionCount
                Label(
                    count > 1 ? "Undo (\(count))" : "Undo",
                    systemImage: "arrow.uturn.backward"
                )
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassSurface(in: Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func flashUndo() {
        undoHideTask?.cancel()
        withAnimation(.spring) { showUndo = true }
        // Destructive multi-playlist actions get a longer undo window (matching
        // the old 6s inline-toast undo); routine actions stay a quick 2.5s.
        let lingers = viewModel.toastUndoable
        undoHideTask = Task {
            try? await Task.sleep(for: .seconds(lingers ? 6 : 2.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) { showUndo = false }
            }
        }
    }
}

// MARK: - Share Sheet

struct SongShareItem: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

/// Feeds the share sheet a song's Apple Music link plus a human title. The
/// custom item source (rather than handing `UIActivityViewController` the bare
/// URL) lets us set the message subject and the rich link-preview title, so
/// shares to Messages/Mail read as "Song · Artist" instead of a raw link.
final class SongShareSource: NSObject, UIActivityItemSource {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        url
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        title
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = url
        metadata.url = url
        return metadata
    }
}

struct SongShareSheet: UIViewControllerRepresentable {
    let url: URL
    let title: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let source = SongShareSource(url: url, title: title)
        return UIActivityViewController(activityItems: [source], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
