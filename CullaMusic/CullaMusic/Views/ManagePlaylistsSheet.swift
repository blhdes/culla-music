import SwiftUI

/// Lets the user pick which playlists appear in the swipe sidebar (capped to
/// `MusicSwipeViewModel.maxSidebar`) and create new ones.
struct ManagePlaylistsSheet: View {
    @Bindable var viewModel: MusicSwipeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCreate = false

    private var maxSidebar: Int { MusicSwipeViewModel.maxSidebar }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showCreate = true
                    } label: {
                        Label("New playlist", systemImage: "plus.circle.fill")
                    }
                }

                Section {
                    if viewModel.playlists.isEmpty {
                        Text("No playlists yet — create one above.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.playlists, id: \.id) { playlist in
                            row(for: playlist)
                        }
                    }
                } header: {
                    HStack {
                        Text("Sidebar")
                        Spacer()
                        Text("\(viewModel.sidebarCount) / \(maxSidebar)")
                            .monospacedDigit()
                    }
                } footer: {
                    Text("Tap a playlist to toggle it in the right-swipe sidebar. Up to \(maxSidebar) at a time.")
                }
            }
            .navigationTitle("Manage Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showCreate) {
                NewPlaylistSheet { name in
                    Task {
                        await viewModel.createPlaylist(
                            name: name,
                            addToSidebar: viewModel.canAddToSidebar
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for playlist: Playlist) -> some View {
        let isOn = playlist.isInSidebar
        let canEnable = viewModel.canAddToSidebar
        let isTappable = isOn || canEnable

        Button {
            if isOn {
                viewModel.setSidebar(playlist, included: false)
            } else if canEnable {
                viewModel.setSidebar(playlist, included: true)
            }
        } label: {
            HStack(spacing: 12) {
                PlaylistCoverView(appleMusicPlaylistID: playlist.appleMusicPlaylistID)
                Text(playlist.name)
                    .foregroundStyle(.primary)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
            .opacity(isTappable ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isTappable)
    }
}

// MARK: - Playlist cover thumbnail

private struct PlaylistCoverView: View {
    let appleMusicPlaylistID: String?

    private var artworkURL: URL? {
        guard let id = appleMusicPlaylistID else { return nil }
        return MusicLibraryService.shared.artworkURL(forPlaylistID: id, size: 88)
    }

    var body: some View {
        Group {
            if let url = artworkURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay(
                Image(systemName: "music.note.list")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            )
    }
}
