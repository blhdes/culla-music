import SwiftUI

/// Generic glass-card primitive used across the redesigned screens (Settings,
/// LovedPlaylistPickerSheet, ManagePlaylistsSheet). Provides a consistent
/// container vocabulary: rounded glass surface + small icon + uppercase title
/// header + caller-provided content.
///
/// Sibling helpers in this file are Settings-specific (they're the screen that
/// drove the original extraction): `SettingsToggleRow` for labelled toggles
/// and `ThemeChipPicker` for the three-option theme selector. They live here
/// so the visual family stays in one file.

// MARK: - GlassPanel

struct GlassPanel<Trailing: View, Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Spacer(minLength: 4)
                trailing()
            }
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
    }
}

extension GlassPanel where Trailing == EmptyView {
    init(
        icon: String,
        title: LocalizedStringKey,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.trailing = { EmptyView() }
        self.content = content
    }
}

// MARK: - SettingsToggleRow

struct SettingsToggleRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    @Environment(\.appAccent) private var appAccent

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.primary)
        }
        .tint(appAccent)
    }
}

// MARK: - ThemeChipPicker

/// Three glass capsules — System / Light / Dark. Replaces `.pickerStyle(.segmented)`
/// so the theme picker shares the screen's glass vocabulary instead of dropping
/// to a stock UIKit segmented control. The selected chip picks up the accent
/// tint + border, mirroring the mode-tile pattern on Home.
struct ThemeChipPicker: View {
    @Binding var selection: String

    @Environment(\.appAccent) private var appAccent

    private struct Option: Identifiable {
        let id: String
        let label: String
        let icon: String
    }

    private let options: [Option] = [
        Option(id: "system", label: "System", icon: "circle.lefthalf.filled"),
        Option(id: "light",  label: "Light",  icon: "sun.max.fill"),
        Option(id: "dark",   label: "Dark",   icon: "moon.fill")
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                chip(option)
            }
        }
    }

    @ViewBuilder
    private func chip(_ option: Option) -> some View {
        let isSelected = selection == option.id
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                selection = option.id
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: option.icon)
                    .font(.caption.weight(.bold))
                    .symbolEffect(.bounce, value: isSelected)
                Text(option.label)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .contentShape(Capsule())
            .glassSurface(in: Capsule(), tint: isSelected ? appAccent : nil, interactive: true)
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? appAccent.opacity(0.45) : .white.opacity(0.06),
                        lineWidth: isSelected ? 1.4 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: isSelected)
    }
}

#Preview("Panels") {
    ScrollView {
        VStack(spacing: 18) {
            GlassPanel(icon: "paintbrush.fill", title: "Appearance") {
                ThemeChipPicker(selection: .constant("dark"))
            }
            GlassPanel(icon: "waveform", title: "Behavior") {
                SettingsToggleRow(title: "Haptics", isOn: .constant(true))
                SettingsToggleRow(title: "Start at song highlight", isOn: .constant(false))
            }
        }
        .padding(20)
    }
    .background(LivingMeshBackground())
    .environment(\.appAccent, .purple)
}
