import SwiftUI
import SwiftData
import MusicKit

struct MusicSwipeView: View {
    @Bindable var viewModel: MusicSwipeViewModel
    var onBack: (() -> Void)?

    @AppStorage("membershipIncludeCurated") private var membershipIncludeCurated: Bool = false
    @AppStorage("useDynamicAccent") private var useDynamicAccent: Bool = true

    @Environment(\.appAccent) private var paletteAccent

    // Dynamic accent pair sampled from the current song's artwork. Nil → fall
    // back to the palette accent so the UI never goes uncolored.
    @State private var dynamicAccent: ArtworkAccent?

    // Drag state
    @State private var cardOffset: CGSize = .zero
    @State private var highlightedID: UUID?
    @State private var playlistFrames: [UUID: CGRect] = [:]

    // Long-press preview — fully reveals the sidebar while held
    @State private var isLongPressing = false

    // Sheet
    @State private var showManageSheet = false

    // Toast / undo timers
    @State private var toastTimer: Task<Void, Never>?
    @State private var showUndo = false
    @State private var undoHideTask: Task<Void, Never>?

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
        .animation(.easeOut(duration: 0.45), value: viewModel.isLoading)
        .animation(.easeOut(duration: 0.35), value: viewModel.isEmpty)
        .environment(\.appAccent, effectiveAccent.primary)
        .environment(\.appAccentSecondary, effectiveAccent.secondary)
        .sheet(isPresented: $showManageSheet) {
            ManagePlaylistsSheet(viewModel: viewModel)
        }
        .task(id: viewModel.currentSong?.id.rawValue) {
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
        .onChange(of: viewModel.actionHistory.count) { _, _ in
            flashUndo()
        }
        .onChange(of: membershipIncludeCurated) { _, _ in
            Task {
                await viewModel.rebuildMembershipIndex()
                await viewModel.refreshUnsortedExclusion()
            }
        }
        .onChange(of: viewModel.toastMessage) { _, message in
            guard message != nil else { return }
            toastTimer?.cancel()
            toastTimer = Task {
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.3)) {
                        viewModel.toastMessage = nil
                    }
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var swipeContent: some View {
        GeometryReader { geo in
            cardStack
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    flyOff(y: 700) {
                        viewModel.skipCurrent()
                        Haptics.skip()
                    }
                }
                .gesture(longPressGesture)
                .highPriorityGesture(dragGesture)
                .overlay {
                    let progress = isLongPressing ? 1.0 : sidebarProgress
                    HStack(spacing: 0) {
                        Spacer()
                        PlaylistSidebarView(
                            playlists: viewModel.sidebarPlaylists,
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
                .overlay(alignment: .topLeading) {
                    if let onBack {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.title3.weight(.medium))
                                .frame(width: 24, height: 24)
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 16)
                        .padding(.top, 8)
                        .opacity(chromeOpacity)
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
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 12)
                    .opacity(chromeOpacity)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .overlay(alignment: .bottom) {
            undoButton
                .padding(.bottom, 32)
                .opacity(chromeOpacity)
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
                    isDismissed: viewModel.isDismissed(next),
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
                let isPlayingThis = service.isPlayingPreview &&
                                    service.nowPlayingSongID == current.id.rawValue

                SongCardView(
                    song: current,
                    offset: cardOffset,
                    isPlaying: isPlayingThis,
                    playbackPosition: isPlayingThis ? service.playbackPosition : 0,
                    playbackDuration: isPlayingThis ? service.playbackDuration : 0,
                    memberships: viewModel.playlistMemberships(for: current),
                    isDismissed: viewModel.isDismissed(current),
                    onTogglePlay: { viewModel.togglePreview() },
                    onSeek: { service.seek(to: $0) }
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
                handleSwipeEnd(value)
            }
    }

    private func handleSwipeEnd(_ value: DragGesture.Value) {
        let tx = value.translation.width
        let ty = value.translation.height
        let ptx = value.predictedEndTranslation.width
        let pty = value.predictedEndTranslation.height

        // Sidebar claims the gesture: while the finger is parked over a
        // playlist row, only right-swipe-onto-playlist applies. Vertical
        // motion across rows must not trigger Loved or Dismiss.
        if isLocationInSidebar(value.location) {
            if let id = findPlaylist(at: value.location),
               let playlist = viewModel.sidebarPlaylists.first(where: { $0.id == id }),
               tx > swipeThreshold || ptx > swipeThreshold {
                flyOff(x: 500) {
                    viewModel.assignToPlaylist(playlist)
                    Haptics.swipeRight()
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
                Haptics.swipeRight()
            }
            return
        }

        // Right swipe — assign to highlighted playlist
        if horizontalDominant, tx > swipeThreshold || ptx > swipeThreshold {
            if let id = highlightedID,
               let playlist = viewModel.sidebarPlaylists.first(where: { $0.id == id }) {
                flyOff(x: 500) {
                    viewModel.assignToPlaylist(playlist)
                    Haptics.swipeRight()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + flyDuration) {
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
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var undoButton: some View {
        if viewModel.canUndo, showUndo {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.undo()
                }
                flashUndo()
            } label: {
                let count = viewModel.actionHistory.count
                Label(
                    count > 1 ? "Undo (\(count))" : "Undo",
                    systemImage: "arrow.uturn.backward"
                )
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func flashUndo() {
        undoHideTask?.cancel()
        withAnimation(.spring) { showUndo = true }
        undoHideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) { showUndo = false }
            }
        }
    }
}
