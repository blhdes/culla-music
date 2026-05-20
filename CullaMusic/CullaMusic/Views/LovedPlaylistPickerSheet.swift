import SwiftUI

/// Sheet for picking which playlist up-swipe writes into.
/// Mirrors `SourcePlaylistPickerSheet`'s row layout for visual consistency.
/// Selection is keyed by `appleMusicPlaylistID`; empty string means
/// "auto-create Culla Loves on first up-swipe".
struct LovedPlaylistPickerSheet: View {
    let playlists: [Playlist]
    let selectedID: String                 // "" → auto-create default
    let onPick: (Playlist?) -> Void        // nil → clear setting

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    autoRow
                } footer: {
                    Text("Up-swipe adds the current song to this playlist. Leave on Auto to let Culla create and use a \"Culla Loves\" playlist for you.")
                }

                if !playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(playlists, id: \.id) { playlist in
                            playlistRow(playlist)
                        }
                    }
                }
            }
            .navigationTitle("Loved Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Rows

    private var autoRow: some View {
        let isSelected = selectedID.isEmpty
        return Button {
            onPick(nil)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(
                        Image(systemName: "heart.fill")
                            .font(.body)
                            .foregroundStyle(.pink)
                    )
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto (Culla Loves)")
                        .foregroundStyle(.primary)
                    Text("Created on first up-swipe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .font(.body.weight(.semibold))
                    .opacity(isSelected ? 1 : 0)
                    .scaleEffect(isSelected ? 1 : 0.4)
                    .animation(.snappy(duration: 0.22), value: isSelected)
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

                Text(playlist.name)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .font(.body.weight(.semibold))
                    .opacity(isSelected ? 1 : 0)
                    .scaleEffect(isSelected ? 1 : 0.4)
                    .animation(.snappy(duration: 0.22), value: isSelected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
