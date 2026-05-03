import SwiftUI

/// Right-edge panel that splits evenly among the user's playlists during a right-drag.
/// The last slot is always a "New playlist" row that fires a creation flow on drop.
struct PlaylistSidebarView: View {
    let playlists: [Playlist]
    let highlightedID: UUID?
    let dragProgress: CGFloat

    /// Sentinel UUID for the "+ create new playlist" sidebar slot.
    static let createSlotID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private var isDragging: Bool { dragProgress > 0 }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(playlists.enumerated()), id: \.element.id) { _, playlist in
                PlaylistSidebarItem(
                    playlist: playlist,
                    neonColor: playlist.color,
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

            PlaylistSidebarCreateItem(
                isHighlighted: highlightedID == Self.createSlotID,
                isDragging: isDragging,
                dragProgress: dragProgress
            )
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: PlaylistFramePreferenceKey.self,
                        value: [Self.createSlotID: geo.frame(in: .global)]
                    )
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Single playlist row

struct PlaylistSidebarItem: View {
    let playlist: Playlist
    let neonColor: Color
    let isHighlighted: Bool
    let isDragging: Bool
    let dragProgress: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(Double(dragProgress))

            neonColor
                .opacity(backgroundOpacity)

            HStack(spacing: 10) {
                Image(systemName: playlist.iconName)
                    .font(.body.weight(.semibold))
                Text(playlist.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isDragging ? .white : .secondary)
            .shadow(color: isDragging ? .black.opacity(0.25) : .clear, radius: 2, x: 0, y: 1)
            .padding(.leading, 20)
            .opacity(textOpacity)
            .scaleEffect(isHighlighted ? 1.08 : 1.0, anchor: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isHighlighted)
        .animation(.easeInOut(duration: 0.2), value: isDragging)
    }

    private var backgroundOpacity: Double {
        guard isDragging else { return 0 }
        return isHighlighted ? 0.85 : 0.2 + 0.4 * dragProgress
    }

    private var textOpacity: Double {
        if !isDragging { return 0.5 }
        return isHighlighted ? 1.0 : 0.65
    }
}

// MARK: - "+ New playlist" row

struct PlaylistSidebarCreateItem: View {
    let isHighlighted: Bool
    let isDragging: Bool
    let dragProgress: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(Double(dragProgress))

            Color.accentColor
                .opacity(isHighlighted ? 0.7 : 0)

            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3.weight(.bold))
                Text("New playlist")
                    .font(.title3.weight(.semibold))
            }
            .foregroundStyle(isDragging ? .white : .secondary)
            .padding(.leading, 20)
            .opacity(isDragging ? (isHighlighted ? 1.0 : 0.7) : 0.5)
            .scaleEffect(isHighlighted ? 1.08 : 1.0, anchor: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isHighlighted)
        .animation(.easeInOut(duration: 0.2), value: isDragging)
    }
}

// MARK: - Preference Key

struct PlaylistFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
