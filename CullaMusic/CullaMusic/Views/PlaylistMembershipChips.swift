import SwiftUI

struct PlaylistMembershipChips: View {
    let playlists: [Playlist]
    var maxVisible: Int = 3

    var body: some View {
        if playlists.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                ForEach(visiblePlaylists, id: \.id) { playlist in
                    chip(text: playlist.name)
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
    }
    .padding()
}
