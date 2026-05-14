import SwiftUI

struct PlaylistMembershipChips: View {
    let playlists: [Playlist]
    var isDismissed: Bool = false
    var maxVisible: Int = 3

    @AppStorage("lovedPlaylistID") private var lovedPlaylistID: String = ""

    var body: some View {
        if playlists.isEmpty && !isDismissed {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                if isDismissed {
                    dismissedChip
                }
                ForEach(visiblePlaylists, id: \.id) { playlist in
                    chip(for: playlist)
                }
                if overflowCount > 0 {
                    chip(text: "+\(overflowCount)")
                }
            }
            .padding(.top, 2)
        }
    }

    private var visiblePlaylists: [Playlist] {
        Array(playlists.prefix(maxVisible))
    }

    private var overflowCount: Int {
        max(playlists.count - maxVisible, 0)
    }

    private var dismissedChip: some View {
        Text("Dismissed")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.red.opacity(0.85), in: Capsule())
    }

    @ViewBuilder
    private func chip(for playlist: Playlist) -> some View {
        let isLoved = !lovedPlaylistID.isEmpty
            && playlist.appleMusicPlaylistID == lovedPlaylistID

        HStack(spacing: 3) {
            if isLoved {
                Image(systemName: "heart.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.pink)
            }
            Text(playlist.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }

    private func chip(text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}

#Preview {
    VStack(spacing: 24) {
        PlaylistMembershipChips(playlists: [])
        Text("(empty — no row)")

        let p1 = Playlist(name: "Workout", displayOrder: 0)
        let p2 = Playlist(name: "Chill Evenings", displayOrder: 1)
        let p3 = Playlist(name: "Road Trip", displayOrder: 2)
        let p4 = Playlist(name: "Focus", displayOrder: 3)
        let p5 = Playlist(name: "Wedding", displayOrder: 4)

        PlaylistMembershipChips(playlists: [p1])
        PlaylistMembershipChips(playlists: [p1, p2])
        PlaylistMembershipChips(playlists: [p1, p2, p3, p4, p5])

        PlaylistMembershipChips(playlists: [], isDismissed: true)
        PlaylistMembershipChips(playlists: [p1, p2], isDismissed: true)
    }
    .padding()
}
