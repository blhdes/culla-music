import SwiftUI

/// 📸 Portfolio-screenshot toggle.
///
/// `false` → the real app: the sidebar renders the user's actual playlists and
/// the swipe deck behaves normally.
///
/// `true`  → screenshot-demo build: the sidebar shows hand-picked, dressed-up
/// sample playlists (genre names + photo covers) and `MusicSwipeView` blocks
/// every release from mutating the real library, so you can frame the shot
/// without losing songs. Requires the `shot_*` images in Assets.xcassets.
///
/// Flip this one flag to rebuild the screenshot sidebar in the future.
let cullaScreenshotMode = false

/// Right-edge panel that splits evenly among the user's selected playlists during a right-drag.
/// Capped externally — caller passes only the playlists already filtered to sidebar membership.
struct PlaylistSidebarView: View {
    let playlists: [Playlist]
    let highlightedID: UUID?
    let dragProgress: CGFloat

    @Environment(\.appAccent) private var appAccent
    @Environment(\.appAccentSecondary) private var accentSecondary

    private var isDragging: Bool { dragProgress > 0 }

    var body: some View {
        Group {
            if cullaScreenshotMode {
                screenshotBody
            } else if playlists.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(playlists, id: \.id) { playlist in
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
                .background(panelTint)
            }
        }
        .opacity(Double(dragProgress))
    }

    /// Very faint top-to-bottom wash using the secondary accent — gives the
    /// sidebar panel a tint that's tied to the song without competing with
    /// the drop-target glow on individual rows.
    @ViewBuilder
    private var panelTint: some View {
        if let accentSecondary {
            LinearGradient(
                colors: [accentSecondary.opacity(0.10), accentSecondary.opacity(0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }

    /// First-time empty state. Visually styled as a call-to-action tile, but
    /// the actual interaction lives in `MusicSwipeView.handleSwipeEnd` —
    /// releasing the right-drag while the sidebar is empty opens the Manage
    /// sheet. The sidebar overlay disables hit testing so a `Button` here
    /// would never receive taps; the gesture-release model is both more
    /// honest about how the screen works and more ergonomic (no need to lift
    /// the finger and re-tap).
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.title2)
                .foregroundStyle(appAccent)
                .symbolEffect(.pulse, options: .repeating, isActive: isDragging)
                .frame(width: 64, height: 64)
                .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(appAccent.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: appAccent.opacity(0.35), radius: 14, y: 6)

            Text("Add playlists")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)

            Text("Release to open Manage")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        // Multiplied by the outer .opacity(dragProgress) on the Group, so the
        // floor only matters once any drag exists. Ramp finishes the reveal
        // at 85% → 100% over the back half of the drag.
        .opacity(0.85 + 0.15 * dragProgress)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Screenshot-demo body (only used when `cullaScreenshotMode` is true)

    private struct SampleRow: Identifiable {
        let id = UUID()
        let name: String
        let genre: String
        let image: String
    }

    private let samples: [SampleRow] = [
        .init(name: "night drive",   genre: "darkwave",        image: "shot_drive"),
        .init(name: "after hours",   genre: "techno",          image: "shot_festival"),
        .init(name: "afterglow",     genre: "melodic techno",  image: "shot_golden"),
        .init(name: "static",        genre: "electronica",     image: "shot_jazz"),
        .init(name: "slow burn",     genre: "indie rock",      image: "shot_heartbreak"),
        .init(name: "deep focus",    genre: "minimal",         image: "shot_focus"),
        .init(name: "beast mode",    genre: "hard rock",       image: "shot_gym"),
        .init(name: "open road",     genre: "krautrock",       image: "shot_roadtrip"),
        .init(name: "warehouse",     genre: "acid techno",     image: "shot_coffee"),
        .init(name: "neon bloom",    genre: "electro",         image: "shot_friday"),
    ]

    // Index of the row shown in the "drop target" highlighted state.
    private let highlightedIndex = 2

    private var screenshotBody: some View {
        VStack(spacing: 0) {
            ForEach(Array(samples.enumerated()), id: \.element.id) { index, row in
                SampleSidebarItem(
                    name: row.name,
                    genre: row.genre,
                    image: row.image,
                    isHighlighted: index == highlightedIndex,
                    isDragging: isDragging,
                    dragProgress: dragProgress
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(panelTint)
    }
}

// MARK: - Single playlist row

struct PlaylistSidebarItem: View {
    let playlist: Playlist
    let isHighlighted: Bool
    let isDragging: Bool
    let dragProgress: CGFloat

    @Environment(\.appAccent) private var appAccent
    @Environment(\.appAccentSecondary) private var appAccentSecondary

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(Double(dragProgress))

            // Soft accent highlight when this row is the drop target — neutral elsewhere.
            // Gradient between the song's primary + secondary tones for richness;
            // collapses to a flat fill when no secondary is present.
            LinearGradient(
                colors: [appAccent, appAccentSecondary ?? appAccent],
                startPoint: .leading,
                endPoint: .trailing
            )
            .opacity(isHighlighted ? 0.6 : 0)

            // Complementary leading bar — independent of accent saturation so
            // pale song-derived accents still get an unambiguous "you're here"
            // cue. Sits on top of the gradient so it reads as a stronger edge.
            Rectangle()
                .fill(appAccent)
                .frame(width: 3)
                .opacity(isHighlighted ? 1.0 : 0.0)

            HStack(spacing: 12) {
                PlaylistCoverView(
                    appleMusicPlaylistID: playlist.appleMusicPlaylistID,
                    size: 44,
                    cornerRadius: 8
                )
                Text(playlist.name)
                    .font(.system(.headline, design: .rounded))
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

    /// Smoothly ramps with dragProgress instead of jumping when isDragging
    /// flips. At rest = 0.5; full drag, non-highlighted = 0.7; full drag,
    /// highlighted = 1.0. The previous version stepped 0.5 → 0.7 on the
    /// first millisecond of drag, which read as a small pop.
    private var textOpacity: Double {
        let p = Double(max(0, min(1, dragProgress)))
        let target: Double = isHighlighted ? 1.0 : 0.7
        return 0.5 + (target - 0.5) * p
    }
}

// MARK: - Screenshot-demo row (icon/photo cover + genre — only used in screenshot mode)

private struct SampleSidebarItem: View {
    let name: String
    let genre: String
    let image: String
    let isHighlighted: Bool
    let isDragging: Bool
    let dragProgress: CGFloat

    @Environment(\.appAccent) private var appAccent
    @Environment(\.appAccentSecondary) private var appAccentSecondary

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(Double(dragProgress))

            LinearGradient(
                colors: [appAccent, appAccentSecondary ?? appAccent],
                startPoint: .leading,
                endPoint: .trailing
            )
            .opacity(isHighlighted ? 0.6 : 0)

            Rectangle()
                .fill(appAccent)
                .frame(width: 3)
                .opacity(isHighlighted ? 1.0 : 0.0)

            HStack(spacing: 12) {
                cover
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(.headline, design: .rounded))
                        .lineLimit(1)
                    Text(genre)
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                }
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

    private var cover: some View {
        Image(image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }

    private var textColor: Color {
        if isHighlighted { return .white }
        return isDragging ? .primary : .secondary
    }

    private var textOpacity: Double {
        let p = Double(max(0, min(1, dragProgress)))
        let target: Double = isHighlighted ? 1.0 : 0.7
        return 0.5 + (target - 0.5) * p
    }
}

// MARK: - Preference Key

struct PlaylistFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
