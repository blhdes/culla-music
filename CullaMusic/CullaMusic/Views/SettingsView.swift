import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("appColorScheme") private var colorSchemeRaw: String = "system"
    @AppStorage("appAccentPalette") private var accentPaletteRaw: String = AccentPalette.blue.rawValue
    @AppStorage("hapticsEnabled") private var hapticsEnabled: Bool = true
    @AppStorage("useHotPreview") private var useHotPreview: Bool = false
    @AppStorage("authorDisplayName") private var authorDisplayName: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
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
                        Text("Sidebar accent")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            ForEach(AccentPalette.allCases) { palette in
                                paletteSwatch(palette)
                            }
                            Spacer()
                        }
                    }
                    .padding(.vertical, 4)
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
        }
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
