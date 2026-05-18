import SwiftUI

/// Sheet for picking which playlist (if any) to sort songs from.
/// Mirrors `ManagePlaylistsSheet`'s row layout so the two feel consistent.
struct SourcePlaylistPickerSheet: View {
    let playlists: [Playlist]
    let selectedID: String                 // "" → General Library
    let onPick: (Playlist?) -> Void        // nil → General Library

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    libraryRow
                } footer: {
                    Text("Pick a playlist to sort songs from, or use your full library.")
                }

                if !playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(playlists, id: \.id) { playlist in
                            playlistRow(playlist)
                        }
                    }
                }
            }
            .navigationTitle("Sort From")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Rows

    private var libraryRow: some View {
        let isSelected = selectedID.isEmpty
        return Button {
            onPick(nil)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: "music.note.list")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    )
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Text("All Library")
                    .foregroundStyle(.primary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        let isSelected = playlist.appleMusicPlaylistID == selectedID
        return Button {
            onPick(playlist)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                PlaylistCoverView(appleMusicPlaylistID: playlist.appleMusicPlaylistID)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .foregroundStyle(.primary)
                    if !playlist.isEditable {
                        Text("Read-only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
