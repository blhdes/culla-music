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
    @State private var showInsights = false

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
        case "light": String(localized: "Light")
        case "dark":  String(localized: "Dark")
        default:      String(localized: "System")
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
                    insightsRow
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
            // Full screen rather than a sheet — Insights reads as a focused
            // moment, mirroring the photo app. The cover is its own
            // presentation host, so it needs the theme pin too (same reason
            // as the Settings sheet itself, see `resolvedColorScheme`).
            .fullScreenCover(isPresented: $showInsights) {
                InsightsView()
                    .sheetColorScheme(resolvedColorScheme)
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
            SettingsToggleRow(
                title: "Match song artwork",
                subtitle: "Tint the app to match each cover",
                isOn: $useDynamicAccent
            )
            rowDivider
            SettingsToggleRow(
                title: "Show album on cards",
                subtitle: "Album name under the song title",
                isOn: $showAlbumOnHero
            )
        }
    }

    private var playbackCard: some View {
        SettingsCard(title: "Playback") {
            SettingsToggleRow(title: "Haptics", isOn: $hapticsEnabled)
            rowDivider
            SettingsToggleRow(
                title: "Auto play",
                subtitle: "Each new card starts playing on its own",
                isOn: $autoplayOnSwipe
            )
            rowDivider
            SettingsToggleRow(
                title: "Hot Preview",
                subtitle: "The hottest 30 seconds instead of the full song",
                isOn: $useHotPreview
            )
            rowDivider
            SettingsToggleRow(
                title: "Date jump",
                subtitle: "Jump to songs added around a date",
                isOn: $dateJumpEnabled
            )
        }
    }

    private var personalCard: some View {
        SettingsCard(title: "Personal") {
            lovedRow
            rowDivider
            languageRow
            rowDivider
            TextField("Your name", text: $authorDisplayName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(true)
                .font(.system(.body, design: .rounded))
                .padding(.vertical, 4)
        }
    }

    /// A standalone glass row rather than a titled card — Insights is a door
    /// to another screen, not a setting, so it skips the section header and
    /// keeps the same surface treatment as the cards around it.
    private var insightsRow: some View {
        Button {
            showInsights = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(appAccent)
                Text("Insights")
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text("Your sorting journey")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), interactive: true)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Deep-links to the system's per-app language page (Settings → CullaMusic),
    /// which appears automatically once the app ships ≥2 localizations. iOS
    /// relaunches the app in the chosen language — no custom picker needed.
    private var languageRow: some View {
        Button {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(appAccent)
                Text("Language")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Loved playlist")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("Where your loved songs land")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(selectedLovedPlaylist?.name ?? String(localized: "Auto"))
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

    private func menuRowLabel(title: LocalizedStringKey, value: String) -> some View {
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
        let year = Calendar.current.component(.year, from: Date())

        // One quiet line: the wordmark carries a touch of emphasis, the version
        // and copyright trail off in tertiary. Middle dots keep it elegant
        // instead of stacking three raw rows.
        let name = Text("CullaMusic")
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .foregroundStyle(.secondary)
        let trail = Text("  ·  \(version)  ·  © \(String(year))")
            .font(.system(.caption2, design: .rounded))
            .foregroundStyle(.tertiary)

        return (name + trail)
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
    }
}

#Preview {
    SettingsView()
        .environment(\.appAccent, .purple)
}
