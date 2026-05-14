import SwiftUI
import MusicKit

/// Lets the user pick which playlists appear in the swipe sidebar (capped to
/// `MusicSwipeViewModel.maxSidebar`) and create new ones.
struct ManagePlaylistsSheet: View {
    @Bindable var viewModel: MusicSwipeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCreate = false

    /// The up-swipe loved target. Hidden from the sidebar list below since the
    /// up-swipe already covers that playlist and double-listing it implies a
    /// toggle that wouldn't add anything. Configured in Settings.
    @AppStorage("lovedPlaylistID") private var lovedPlaylistID: String = ""

    private var maxSidebar: Int { MusicSwipeViewModel.maxSidebar }

    private var editablePlaylists: [Playlist] {
        viewModel.playlists.filter { playlist in
            guard playlist.isEditable else { return false }
            if !lovedPlaylistID.isEmpty,
               playlist.appleMusicPlaylistID == lovedPlaylistID {
                return false
            }
            return true
        }
    }

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
                    if editablePlaylists.isEmpty {
                        Text("No playlists yet — create one above.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(editablePlaylists, id: \.id) { playlist in
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
            .opacity(isTappable ? 1.0 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!isTappable)
    }
}

// MARK: - Playlist cover thumbnail

struct PlaylistCoverView: View {
    let appleMusicPlaylistID: String?
    var size: CGFloat = 44
    var cornerRadius: CGFloat = 8

    private var artwork: Artwork? {
        guard let id = appleMusicPlaylistID else { return nil }
        return MusicLibraryService.shared.artwork(forPlaylistID: id)
    }

    var body: some View {
        Group {
            if let artwork {
                ArtworkImage(artwork, width: size, height: size)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay(
                Image(systemName: "music.note.list")
                    .font(size > 44 ? .body : .caption)
                    .foregroundStyle(.secondary)
            )
    }
}
