import SwiftUI

/// Generic glass-card primitive — rounded glass surface + small icon + uppercase
/// title header + caller-provided content. Today it carries the Insights
/// screen's stat cards; the quieter Settings tier uses `SettingsCard` instead.
///
/// `SettingsToggleRow` (the labelled toggle the Settings cards stack) lives
/// here too, so the row and the card family stay in one file.

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
    var subtitle: LocalizedStringKey? = nil
    @Binding var isOn: Bool

    @Environment(\.appAccent) private var appAccent

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(appAccent)
    }
}

#Preview("Panels") {
    ScrollView {
        VStack(spacing: 18) {
            GlassPanel(icon: "waveform", title: "Behavior") {
                SettingsToggleRow(title: "Haptics", isOn: .constant(true))
                SettingsToggleRow(title: "Start at song highlight", isOn: .constant(false))
            }
        }
        .padding(20)
    }
    .background(Color(.systemBackground))
    .environment(\.appAccent, .purple)
}
