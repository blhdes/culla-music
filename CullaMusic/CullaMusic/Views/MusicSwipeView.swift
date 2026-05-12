import SwiftUI
import SwiftData
import MusicKit

struct MusicSwipeView: View {
    @Bindable var viewModel: MusicSwipeViewModel
    var onBack: (() -> Void)?

    @AppStorage("membershipIncludeCurated") private var membershipIncludeCurated: Bool = false

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
        .sheet(isPresented: $showManageSheet) {
            ManagePlaylistsSheet(viewModel: viewModel)
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
                if value.translation.width > 30 {
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
        let ptx = value.predictedEndTranslation.width

        // Right swipe — assign to highlighted playlist
        if tx > swipeThreshold || ptx > swipeThreshold {
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
        if tx < -swipeThreshold || ptx < -swipeThreshold {
            flyOff(x: -500) {
                viewModel.dismissCurrent()
                Haptics.swipeLeft()
            }
            return
        }

        snapBack()
    }

    private func flyOff(x: CGFloat = 0, y: CGFloat = 0, action: @escaping () -> Void) {
        withAnimation(.easeIn(duration: 0.25)) {
            cardOffset = CGSize(width: x, height: y)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            highlightedID = nil
            withAnimation(.easeOut(duration: 0.35)) {
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
