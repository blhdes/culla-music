import SwiftUI
import SwiftData
import MusicKit

struct MusicSwipeView: View {
    @Bindable var viewModel: MusicSwipeViewModel

    // Drag state
    @State private var cardOffset: CGSize = .zero
    @State private var highlightedID: UUID?
    @State private var playlistFrames: [UUID: CGRect] = [:]

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

            if viewModel.isLoading {
                ProgressView("Loading library…")
            } else if viewModel.isEmpty {
                EmptyStateView(onRefresh: { Task { await viewModel.reload() } })
            } else {
                swipeContent
            }
        }
        .sheet(isPresented: $showManageSheet) {
            ManagePlaylistsSheet(viewModel: viewModel)
        }
        .onChange(of: viewModel.actionHistory.count) { _, _ in
            flashUndo()
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
                .gesture(dragGesture)
                .overlay {
                    HStack(spacing: 0) {
                        Spacer()
                        PlaylistSidebarView(
                            playlists: viewModel.sidebarPlaylists,
                            highlightedID: highlightedID,
                            dragProgress: rightDragProgress
                        )
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: (1.0 - rightDragProgress) * 30)
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
                    onTogglePlay: {}
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
                    onTogglePlay: { viewModel.togglePreview() }
                )
                .id(current.id.rawValue)
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

    private func flyOff(x: CGFloat, action: @escaping () -> Void) {
        withAnimation(.easeIn(duration: 0.25)) {
            cardOffset = CGSize(width: x, height: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            cardOffset = .zero
            highlightedID = nil
            action()
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

    private var chromeOpacity: Double {
        Double(1.0 - rightDragProgress)
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
