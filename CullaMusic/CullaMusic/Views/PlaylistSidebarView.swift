import SwiftUI

/// Right-edge panel that splits evenly among the user's selected playlists during a right-drag.
/// Capped externally — caller passes only the playlists already filtered to sidebar membership.
struct PlaylistSidebarView: View {
    let playlists: [Playlist]
    let highlightedID: UUID?
    let dragProgress: CGFloat

    private var isDragging: Bool { dragProgress > 0 }

    var body: some View {
        Group {
            if playlists.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(playlists.enumerated()), id: \.element.id) { _, playlist in
                        PlaylistSidebarItem(
                            playlist: playlist,
                            isHighlighted: playlist.id == highlightedID,
                            isDragging: isDragging,
                            dragProgress: dragProgress
                        )
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: PlaylistFramePreferenceKey.self,
                                    value: [playlist.id: geo.frame(in: .global)]
                                )
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .opacity(Double(dragProgress))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Add a playlist\nto sort songs")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 4) {
                Text("Tap Manage")
                    .font(.caption)
                Image(systemName: "arrow.down.right")
                    .font(.caption)
            }
            .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isDragging ? 0.6 + 0.4 * dragProgress : 0.55)
    }
}

// MARK: - Single playlist row

struct PlaylistSidebarItem: View {
    let playlist: Playlist
    let isHighlighted: Bool
    let isDragging: Bool
    let dragProgress: CGFloat

    @Environment(\.appAccent) private var appAccent

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(Double(dragProgress))

            // Soft accent highlight when this row is the drop target — neutral elsewhere.
            appAccent
                .opacity(isHighlighted ? 0.6 : 0)

            HStack(spacing: 12) {
                PlaylistCoverView(
                    appleMusicPlaylistID: playlist.appleMusicPlaylistID,
                    size: 52,
                    cornerRadius: 8
                )
                Text(playlist.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(textColor)
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .opacity(textOpacity)
            .scaleEffect(isHighlighted ? 1.06 : 1.0, anchor: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isHighlighted)
        .animation(.easeInOut(duration: 0.2), value: isDragging)
    }

    private var textColor: Color {
        if isHighlighted { return .white }
        return isDragging ? .primary : .secondary
    }

    private var textOpacity: Double {
        if !isDragging { return 0.5 }
        return isHighlighted ? 1.0 : 0.7
    }
}

// MARK: - Preference Key

struct PlaylistFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
