import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

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
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Theme")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker("Theme", selection: $colorSchemeRaw) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Match song artwork", isOn: $useDynamicAccent)
                        Text("Sidebar accent")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            ForEach(AccentPalette.allCases) { palette in
                                paletteSwatch(palette)
                            }
                            Spacer()
                        }
                        .opacity(useDynamicAccent ? 0.5 : 1.0)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Pulls the sidebar accent from the current song's cover art. Falls back to the palette above when off.")
                }

                Section {
                    Toggle("Haptics", isOn: $hapticsEnabled)
                    Toggle("Start at song highlight", isOn: $useHotPreview)
                } header: {
                    Text("Behavior")
                } footer: {
                    Text("Plays Apple Music's curated preview clip (~30s) instead of starting from the beginning. Falls back to the full song when no preview is available.")
                }

                Section {
                    Toggle("Include read-only playlists", isOn: $membershipIncludeCurated)
                } header: {
                    Text("Playlist scope")
                } footer: {
                    Text("Show editorial, replay, auto-mix, and shared playlists in chips and Unsorted.")
                }

                Section {
                    lovedTargetRow
                } header: {
                    Text("Up-swipe")
                } footer: {
                    Text("Up-swipe on a song adds it to this playlist. Leave on Auto to use a \"Culla Loves\" playlist Culla creates for you.")
                }

                Section {
                    TextField("Your name", text: $authorDisplayName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(true)
                } header: {
                    Text("Playlists")
                } footer: {
                    Text("Used as the author of new playlists Culla creates in Apple Music. Leave empty to use the default.")
                }
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

    @ViewBuilder
    private var lovedTargetRow: some View {
        Button {
            showLovedPicker = true
        } label: {
            HStack {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                Text("Loved playlist")
                    .foregroundStyle(.primary)
                Spacer()
                Text(selectedLovedPlaylist?.name ?? "Auto")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func paletteSwatch(_ palette: AccentPalette) -> some View {
        let isSelected = accentPaletteRaw == palette.rawValue
        Button {
            accentPaletteRaw = palette.rawValue
        } label: {
            Circle()
                .fill(palette.color)
                .frame(width: 32, height: 32)
                .overlay {
                    Circle()
                        .stroke(.primary, lineWidth: isSelected ? 2 : 0)
                        .padding(-3)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(palette.label)
    }
}

#Preview {
    SettingsView()
}
