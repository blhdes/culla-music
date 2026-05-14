import SwiftUI

struct PlaylistMembershipChips: View {
    let playlists: [Playlist]
    var dismissedAt: Date? = nil
    var maxVisible: Int = 3

    @AppStorage("lovedPlaylistID") private var lovedPlaylistID: String = ""

    var body: some View {
        if playlists.isEmpty && dismissedAt == nil {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                if let dismissedAt {
                    dismissedChip(date: dismissedAt)
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

    private func dismissedChip(date: Date) -> some View {
        Text("Dismissed \(Self.relativeAge(from: date))")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.red.opacity(0.15), in: Capsule())
    }

    /// Compact relative-age string: "just now", "3h ago", "5d ago", "2w ago",
    /// "5mo ago", "2y ago". Sub-day dismissals get an hours tier so a card
    /// dismissed an hour ago doesn't read the same as one dismissed yesterday.
    /// Future/clock-skew dates clamp to "just now".
    static func relativeAge(from date: Date) -> String {
        let seconds = max(Date().timeIntervalSince(date), 0)
        let hours = Int(seconds / 3_600)
        if hours < 1 { return "just now" }
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        if days < 30 { return "\(days / 7)w ago" }
        if days < 365 { return "\(days / 30)mo ago" }
        return "\(days / 365)y ago"
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

        let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)
        let threeMonthsAgo = Date().addingTimeInterval(-90 * 86_400)
        PlaylistMembershipChips(playlists: [], dismissedAt: twoDaysAgo)
        PlaylistMembershipChips(playlists: [p1, p2], dismissedAt: threeMonthsAgo)
    }
    .padding()
}
