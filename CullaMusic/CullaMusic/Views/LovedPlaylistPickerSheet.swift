import SwiftUI

/// Sheet for picking which playlist up-swipe writes into.
/// Selection is keyed by `appleMusicPlaylistID`; empty string means
/// "auto-create Culla Loves on first up-swipe". The footer is gone because
/// the Up-swipe card in Settings already explains the behaviour — repeating
/// it here was just noise.
///
/// Visual tier matches the Settings parent: plain `systemBackground`, no
/// `LivingMeshBackground`, `SettingsCard` containers instead of `GlassPanel`.
struct LovedPlaylistPickerSheet: View {
    let playlists: [Playlist]
    let selectedID: String                 // "" → auto-create default
    let onPick: (Playlist?) -> Void        // nil → clear setting

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    SettingsCard(title: "Default") {
                        autoRow
                    }

                    if !playlists.isEmpty {
                        SettingsCard(title: "Playlists") {
                            VStack(spacing: 4) {
                                ForEach(Array(playlists.enumerated()), id: \.element.id) { index, playlist in
                                    playlistRow(playlist)
                                    if index < playlists.count - 1 {
                                        Divider().opacity(0.4)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .navigationTitle("Loved Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
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
                Text("Auto (Culla Loves)")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.primary)

                Spacer()

                pickOneCheckmark(isSelected: isSelected)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
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
                PlaylistCoverView(
                    appleMusicPlaylistID: playlist.appleMusicPlaylistID,
                    size: 40,
                    cornerRadius: 8
                )

                Text(playlist.name)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                pickOneCheckmark(isSelected: isSelected)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    /// Reserved-slot checkmark — fades in on the selected row, nothing on
    /// the rest. Per the project's pick-one-and-dismiss convention.
    private func pickOneCheckmark(isSelected: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.body.weight(.bold))
            .foregroundStyle(appAccent)
            .opacity(isSelected ? 1 : 0)
            .scaleEffect(isSelected ? 1 : 0.4)
            .animation(.snappy(duration: 0.22), value: isSelected)
            .frame(width: 20)
    }
}
