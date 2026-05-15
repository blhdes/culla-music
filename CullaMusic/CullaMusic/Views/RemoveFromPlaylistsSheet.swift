import SwiftUI
import MusicKit

/// Long-press cleanup surface in Dismissed mode. Lets the user pick which of a
/// dismissed song's playlists to strip it from — all selected by default, so
/// the fast path is still a single confirmation tap.
struct RemoveFromPlaylistsSheet: View {
    let song: Song
    let memberships: [Playlist]
    let onRemove: ([Playlist]) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Tracks AM IDs the user has *opted out* of removing. Empty set = remove
    /// from all (the default). Storing exclusions instead of inclusions keeps
    /// the all-selected default trivial.
    @State private var excludedIDs: Set<String> = []

    private var selectedPlaylists: [Playlist] {
        memberships.filter(isSelected)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                songHeader
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                List {
                    Section {
                        ForEach(memberships, id: \.appleMusicPlaylistID) { playlist in
                            row(for: playlist)
                        }
                    } header: {
                        Text("Remove from")
                    } footer: {
                        Text("The song stays dismissed. These playlists are also updated in Apple Music.")
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Cleanup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(removeLabel, role: .destructive) {
                        onRemove(selectedPlaylists)
                        dismiss()
                    }
                    .disabled(selectedPlaylists.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var removeLabel: String {
        let count = selectedPlaylists.count
        return count > 0 ? "Remove (\(count))" : "Remove"
    }

    @ViewBuilder
    private var songHeader: some View {
        VStack(spacing: 8) {
            if let artwork = song.artwork {
                ArtworkImage(artwork, width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(spacing: 2) {
                Text(song.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(song.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func row(for playlist: Playlist) -> some View {
        let selected = isSelected(playlist)
        Button {
            toggle(playlist)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.red : Color.secondary)
                Text(playlist.name)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isSelected(_ playlist: Playlist) -> Bool {
        guard let amID = playlist.appleMusicPlaylistID else { return false }
        return !excludedIDs.contains(amID)
    }

    private func toggle(_ playlist: Playlist) {
        guard let amID = playlist.appleMusicPlaylistID else { return }
        if excludedIDs.contains(amID) {
            excludedIDs.remove(amID)
        } else {
            excludedIDs.insert(amID)
        }
    }
}
