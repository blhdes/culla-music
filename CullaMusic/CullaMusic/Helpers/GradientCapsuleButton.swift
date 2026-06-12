import SwiftUI

/// The app's primary call-to-action vocabulary. Bold accent-gradient capsule
/// with a soft accent shadow halo — used on HomeView's "Start Cullaing",
/// AuthGateView's "Continue", EmptyStateView's "Refresh library", and any
/// future hero CTA. Centralizing this prevents the three buttons from drifting
/// apart visually as the design evolves.
///
/// Deliberately not glass: on a Liquid-Glass-heavy screen the CTA needs to be
/// bold and opaque so it wins the visual hierarchy. The glass surfaces frame
/// the *path* to the CTA, not the CTA itself.
struct GradientCapsuleButton: View {
    let title: LocalizedStringKey
    var icon: String? = nil
    var iconEffect: IconEffect = .none
    let action: () -> Void

    @Environment(\.appAccent) private var appAccent

    /// Optional repeating SF symbol effect applied to the leading icon. Use
    /// `.pulse` for inviting CTAs (Start, Continue); leave `.none` for action
    /// buttons (Refresh, Save) where motion would feel restless.
    enum IconEffect { case none, pulse }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .bold))
                        .symbolEffect(
                            .pulse,
                            options: .repeating,
                            isActive: iconEffect == .pulse
                        )
                }
                Text(title)
                    .font(.system(.headline, design: .rounded).weight(.bold))
            }
            // Computed contrast foreground, not hardcoded white — the accent
            // palette includes light swatches (Amber, Rose) where white text
            // fails contrast. Same helper the selected ModeTile uses, so the
            // CTA and tiles flip to near-black on the same swatches.
            .foregroundStyle(appAccent.idealForeground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
                Capsule()
                    .fill(LinearGradient(
                        colors: [appAccent, appAccent.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            }
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: appAccent.opacity(0.30), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 24) {
        GradientCapsuleButton(title: "Start Cullaing", icon: "play.fill", iconEffect: .pulse) {}
        GradientCapsuleButton(title: "Refresh library", icon: "arrow.clockwise") {}
        GradientCapsuleButton(title: "Continue") {}
    }
    .padding(24)
    .environment(\.appAccent, .blue)
}
