import SwiftUI
import UIKit

struct PlaylistMembershipChips: View {
    let playlists: [Playlist]
    var dismissedAt: Date? = nil
    var maxVisible: Int = 3

    /// Set to true on cold launch while the membership index is being built
    /// for the first time. When there's nothing to render yet, we show a
    /// single pulsing placeholder pill so the empty space doesn't read as
    /// "this song has no memberships." Ignored once we have anything to show.
    var isLoading: Bool = false

    @AppStorage("lovedPlaylistID") private var lovedPlaylistID: String = ""
    /// Album-derived tint when dynamic accent is on, palette accent otherwise —
    /// resolved upstream in `MusicSwipeView`, so the chips just read it.
    @Environment(\.appAccent) private var appAccent
    /// Non-nil only when the album-derived accent came from a monochrome cover:
    /// a pure-grey tint keyed to the cover's lightness. We prefer it over the
    /// colored accent so B&W artwork tints the pills white/grey/black, which
    /// reads more minimal than the steel/sand slate `appAccent` would carry.
    @Environment(\.appAccentNeutral) private var appAccentNeutral
    @State private var placeholderPulse: Bool = false

    var body: some View {
        if playlists.isEmpty && dismissedAt == nil {
            if isLoading {
                placeholderChip
                    .padding(.top, 2)
            } else {
                EmptyView()
            }
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
            // A cold card opens on the provisional (artwork-metadata) tint and
            // the real extraction can land while the chips are already on
            // screen — e.g. on the behind card mid-drag, where the change
            // arrives via a plain re-render with no animated transaction and
            // would snap. Scoped here (not on the card) so only the tint
            // refine blooms; a freshly mounted card still paints instantly.
            .animation(.easeInOut(duration: 0.45), value: chipTint)
        }
    }

    private var visiblePlaylists: [Playlist] {
        Array(playlists.prefix(maxVisible))
    }

    private var overflowCount: Int {
        max(playlists.count - maxVisible, 0)
    }

    /// The tint actually painted on the pills: the neutral grey for monochrome
    /// covers, the colored accent otherwise.
    private var chipTint: Color {
        appAccentNeutral ?? appAccent
    }

    /// Black or white — whichever contrasts the tinted pill better. The tint
    /// washing the glass can land genuinely dark: `AccentExtractor` clamps HSL
    /// *lightness* to [0.40, 0.58] for colored accents (and down to ~0.22 for
    /// the neutral grey), but a saturated hue at L=0.40 is still dark to the
    /// eye, so the old `.primary` label went black-on-dark and disappeared.
    /// Deriving the label from the tint's perceived luminance is scheme-
    /// independent — it flips correctly for dark *and* pale tints.
    private var accentLabelColor: Color {
        chipTint.contrastingLabel
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
        if hours < 1 { return String(localized: "just now") }
        if hours < 24 { return String(localized: "\(hours)h ago") }
        let days = hours / 24
        if days < 7 { return String(localized: "\(days)d ago") }
        if days < 30 { return String(localized: "\(days / 7)w ago") }
        if days < 365 { return String(localized: "\(days / 30)mo ago") }
        return String(localized: "\(days / 365)y ago")
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
                .foregroundStyle(accentLabelColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        // Accent rides on the tint + hairline border. The label color is
        // derived from the tint's luminance (see `accentLabelColor`) so it
        // stays legible whether the tint lands pale or dark.
        .glassSurface(in: Capsule(), tint: chipTint)
        .overlay(
            Capsule().strokeBorder(chipTint.opacity(0.35), lineWidth: 1)
        )
    }

    private func chip(text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(accentLabelColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .glassSurface(in: Capsule(), tint: chipTint)
            .overlay(
                Capsule().strokeBorder(chipTint.opacity(0.35), lineWidth: 1)
            )
    }

    /// Width-matched to a typical playlist name so the layout doesn't jump
    /// when real chips slide in. Pulse animation is subtle on purpose —
    /// loud enough to signal "loading," quiet enough not to draw the eye
    /// away from the song's title.
    private var placeholderChip: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 72, height: 20)
            .opacity(placeholderPulse ? 0.7 : 0.35)
            .animation(
                .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: placeholderPulse
            )
            .onAppear { placeholderPulse = true }
    }
}

#Preview {
    VStack(spacing: 24) {
        PlaylistMembershipChips(playlists: [])
        Text("(empty — no row)")

        PlaylistMembershipChips(playlists: [], isLoading: true)
        Text("(loading — pulsing placeholder)")

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
