import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var appAccent

    @AppStorage("appColorScheme") private var colorSchemeRaw: String = "system"
    @AppStorage("appAccentPalette") private var accentPaletteRaw: String = AccentPalette.blue.rawValue
    @AppStorage("useDynamicAccent") private var useDynamicAccent: Bool = true
    @AppStorage("showAlbumOnHero") private var showAlbumOnHero: Bool = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled: Bool = true
    @AppStorage("useHotPreview") private var useHotPreview: Bool = false
    @AppStorage("autoplayOnSwipe") private var autoplayOnSwipe: Bool = true
    @AppStorage("dateJumpInSession") private var dateJumpEnabled: Bool = false
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

    // A sheet runs in its own presentation host, so a theme change doesn't
    // reliably restyle it live (UIKit's trait-driven surfaces — the background
    // and glass cards — lag behind, half-theming the sheet). `.sheetColorScheme`
    // pins the sheet host's appearance directly so the toggle takes effect
    // instantly and completely. See SheetColorScheme.swift.
    private var resolvedColorScheme: ColorScheme? {
        switch colorSchemeRaw {
        case "light": .light
        case "dark":  .dark
        default:      nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // GlassStack groups the cards in one GlassEffectContainer so
                // their glass reads as a coordinated family on iOS 26 (spacing
                // 22 matches the prior VStack, so nothing reflows). Stays within
                // the deliberately quiet Settings tier — no new color or mesh.
                GlassStack(spacing: 22) {
                    lookCard
                    playbackCard
                    personalCard
                    copyrightFooter
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            // The one tasteful iOS 26 nicety: content softly diffuses under the
            // nav bar instead of a hard cut — the Liquid Glass scroll feel,
            // calm enough for a settings screen.
            .softScrollEdge()
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
        .sheetColorScheme(resolvedColorScheme)
    }

    // MARK: - Cards

    private var lookCard: some View {
        SettingsCard(title: "Look") {
            themeMenuRow
            rowDivider
            colorRow
            rowDivider
            SettingsToggleRow(title: "Match song artwork", isOn: $useDynamicAccent)
            rowDivider
            SettingsToggleRow(title: "Show album on cards", isOn: $showAlbumOnHero)
        }
    }

    private var playbackCard: some View {
        SettingsCard(title: "Playback") {
            SettingsToggleRow(title: "Haptics", isOn: $hapticsEnabled)
            rowDivider
            SettingsToggleRow(title: "Auto play", isOn: $autoplayOnSwipe)
            rowDivider
            SettingsToggleRow(title: "Hot Preview", isOn: $useHotPreview)
            rowDivider
            SettingsToggleRow(title: "Date jump", isOn: $dateJumpEnabled)
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
                Image(systemName: "heart.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(appAccent)
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

    // MARK: - Copyright

    private var copyrightFooter: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let year = Calendar.current.component(.year, from: Date())
        let versionLine = build.isEmpty ? "Version \(version)" : "Version \(version) (\(build))"
        return VStack(spacing: 3) {
            Text("Culla Music")
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
            Text(versionLine)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("© \(String(year)) Culla Music")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

#Preview {
    SettingsView()
        .environment(\.appAccent, .purple)
}
