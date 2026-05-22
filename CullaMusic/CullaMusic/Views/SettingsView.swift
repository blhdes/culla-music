import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent

    @AppStorage("appColorScheme") private var colorSchemeRaw: String = "system"
    @AppStorage("appAccentPalette") private var accentPaletteRaw: String = AccentPalette.blue.rawValue
    @AppStorage("useDynamicAccent") private var useDynamicAccent: Bool = true
    @AppStorage("hapticsEnabled") private var hapticsEnabled: Bool = true
    @AppStorage("useHotPreview") private var useHotPreview: Bool = false
    @AppStorage("membershipIncludeCurated") private var membershipIncludeCurated: Bool = false
    @AppStorage("authorDisplayName") private var authorDisplayName: String = ""
    @AppStorage("lovedPlaylistID") private var lovedPlaylistID: String = ""

    @Query(sort: \Playlist.displayOrder) private var allPlaylists: [Playlist]

    @State private var showLovedPicker = false

    private var pickablePlaylists: [Playlist] {
        allPlaylists.filter { $0.isEditable && $0.appleMusicPlaylistID != nil }
    }

    private var selectedLovedPlaylist: Playlist? {
        guard !lovedPlaylistID.isEmpty else { return nil }
        return pickablePlaylists.first { $0.appleMusicPlaylistID == lovedPlaylistID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LivingMeshBackground()

                ScrollView {
                    VStack(spacing: 18) {
                        appearanceCard
                        behaviorCard
                        playlistScopeCard
                        upSwipeCard
                        authorCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showLovedPicker) {
                LovedPlaylistPickerSheet(
                    playlists: pickablePlaylists,
                    selectedID: lovedPlaylistID
                ) { picked in
                    lovedPlaylistID = picked?.appleMusicPlaylistID ?? ""
                }
            }
        }
    }

    // MARK: - Cards

    private var appearanceCard: some View {
        GlassPanel(icon: "paintbrush.fill", title: "Appearance") {
            ThemeChipPicker(selection: $colorSchemeRaw)

            SettingsToggleRow(
                icon: "wand.and.stars",
                title: "Match song artwork",
                isOn: $useDynamicAccent
            )

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 44), spacing: 14)],
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(AccentPalette.allCases) { palette in
                    paletteSwatch(palette)
                }
            }
            .opacity(useDynamicAccent ? 0.5 : 1.0)
            .disabled(useDynamicAccent)
            .animation(.snappy(duration: 0.2), value: useDynamicAccent)
        }
    }

    private var behaviorCard: some View {
        GlassPanel(icon: "waveform", title: "Behavior") {
            VStack(spacing: 14) {
                SettingsToggleRow(icon: "hand.tap.fill", title: "Haptics", isOn: $hapticsEnabled)
                SettingsToggleRow(icon: "bolt.heart.fill", title: "Start at song highlight", isOn: $useHotPreview)
                cardFooter("Starts at the curated 30s preview when available.")
            }
        }
    }

    private var playlistScopeCard: some View {
        GlassPanel(icon: "music.note.list", title: "Playlist scope") {
            VStack(spacing: 12) {
                SettingsToggleRow(icon: "lock.fill", title: "Include read-only playlists", isOn: $membershipIncludeCurated)
                cardFooter("Editorial, replay, auto-mix, and shared.")
            }
        }
    }

    private var upSwipeCard: some View {
        GlassPanel(icon: "arrow.up.heart.fill", title: "Up-swipe") {
            VStack(spacing: 12) {
                lovedTargetRow
                cardFooter("Auto uses a Culla Loves playlist.")
            }
        }
    }

    private var authorCard: some View {
        GlassPanel(icon: "pencil.tip", title: "Playlists") {
            VStack(spacing: 12) {
                TextField("Your name", text: $authorDisplayName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled(true)
                    .font(.system(.body, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                cardFooter("Author shown on new Apple Music playlists.")
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var lovedTargetRow: some View {
        Button {
            showLovedPicker = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.pink.opacity(0.18))
                        .frame(width: 30, height: 30)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.pink)
                }
                Text("Loved playlist")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
                Text(selectedLovedPlaylist?.name ?? "Auto")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cardFooter(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func paletteSwatch(_ palette: AccentPalette) -> some View {
        let isSelected = accentPaletteRaw == palette.rawValue
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                accentPaletteRaw = palette.rawValue
            }
        } label: {
            Circle()
                .fill(palette.color)
                .frame(width: 32, height: 32)
                .shadow(color: palette.color.opacity(isSelected ? 0.55 : 0.0), radius: 10, y: 4)
                .overlay {
                    Circle()
                        .stroke(.primary, lineWidth: isSelected ? 2 : 0)
                        .padding(-3)
                }
                .scaleEffect(isSelected ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(palette.label)
    }
}

#Preview {
    SettingsView()
        .environment(\.appAccent, .purple)
}
