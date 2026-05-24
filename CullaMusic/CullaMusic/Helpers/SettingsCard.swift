import SwiftUI

/// Quieter sibling of `GlassPanel`. No icon, sentence-case title in a calmer
/// weight, tighter row stacking. Used by the Settings tier (SettingsView and
/// the sheets it presents) so the utility surface stays calm — the rest of the
/// app's louder glass vocabulary (Home, ManagePlaylists, ArtistDetail) keeps
/// using `GlassPanel`.
struct SettingsCard<Content: View>: View {
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
