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
    @AppStorage("autoplayOnSwipe") private var autoplayOnSwipe: Bool = true
    @AppStorage("membershipIncludeCurated") private var membershipIncludeCurated: Bool = false
    @AppStorage("authorDisplayName") private var authorDisplayName: String = ""
    @AppStorage("lovedPlaylistID") private var lovedPlaylistID: String = ""

    @Query(sort: \Playlist.displayOrder) private var allPlaylists: [Playlist]

    @State private var showLovedPicker = false
    @State private var showColorPicker = false

    private var pickablePlaylists: [Playlist] {
        allPlaylists.filter { $0.isEditable && $0.appleMusicPlaylistID != nil }
    }

    private var selectedLovedPlaylist: Playlist? {
        guard !lovedPlaylistID.isEmpty else { return nil }
        return pickablePlaylists.first { $0.appleMusicPlaylistID == lovedPlaylistID }
    }

    private var currentPalette: AccentPalette {
        AccentPalette(rawValue: accentPaletteRaw) ?? .blue
    }

    private var themeLabel: String {
        switch colorSchemeRaw {
        case "light": "Light"
        case "dark":  "Dark"
        default:      "System"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    lookCard
                    playbackCard
                    personalCard
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
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
            .sheet(isPresented: $showColorPicker) {
                AccentPalettePickerSheet(selectedRaw: $accentPaletteRaw)
            }
        }
    }

    // MARK: - Cards

    private var lookCard: some View {
        SettingsCard(title: "Look") {
            themeMenuRow
            rowDivider
            colorRow
            rowDivider
            SettingsToggleRow(title: "Match song artwork", isOn: $useDynamicAccent)
        }
    }

    private var playbackCard: some View {
        SettingsCard(title: "Playback") {
            SettingsToggleRow(title: "Haptics", isOn: $hapticsEnabled)
            rowDivider
            SettingsToggleRow(title: "Auto-play tracks", isOn: $autoplayOnSwipe)
            rowDivider
            SettingsToggleRow(title: "Start at song highlight", isOn: $useHotPreview)
            rowDivider
            SettingsToggleRow(title: "Include read-only playlists", isOn: $membershipIncludeCurated)
            Text("Editorial, replay, auto-mix, and shared.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        }
    }

    private var personalCard: some View {
        SettingsCard(title: "Personal") {
            lovedRow
            rowDivider
            TextField("Your name", text: $authorDisplayName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(true)
                .font(.system(.body, design: .rounded))
                .padding(.vertical, 4)
        }
    }

    // MARK: - Rows

    private var themeMenuRow: some View {
        Menu {
            Picker("Theme", selection: $colorSchemeRaw) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
        } label: {
            menuRowLabel(title: "Theme", value: themeLabel)
        }
        .buttonStyle(.plain)
    }

    private var colorRow: some View {
        Button {
            showColorPicker = true
        } label: {
            HStack(spacing: 12) {
                Text("Color")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
                Circle()
                    .fill(currentPalette.color)
                    .frame(width: 16, height: 16)
                Text(currentPalette.label)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var lovedRow: some View {
        Button {
            showLovedPicker = true
        } label: {
            HStack(spacing: 12) {
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

    private func menuRowLabel(title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
    }
}

// MARK: - SettingsCard

/// Quieter sibling of `GlassPanel`. No icon, sentence-case title in a calmer
/// weight, tighter row stacking — used only by SettingsView so the rest of the
/// app's glass vocabulary (Manage, LovedPicker, AccentPicker) stays untouched.
private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 12) {
                content()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
    }
}

#Preview {
    SettingsView()
        .environment(\.appAccent, .purple)
}
