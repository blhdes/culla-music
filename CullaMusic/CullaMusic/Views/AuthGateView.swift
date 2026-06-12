import SwiftUI
import MusicKit

/// First-launch screen requesting Apple Music access. Kept deliberately calm and
/// brand-forward: a plain system background (no mesh), the adaptive `CullaLogo`
/// mark, the "CullaMusic" wordmark, a one-line access explanation, the CTA, and
/// an honest privacy reassurance backed by `PrivacyInfo.xcprivacy` (nothing is
/// collected, tracked, or sent off device).
struct AuthGateView: View {
    let status: MusicAuthorization.Status
    let onRequest: () -> Void

    @Environment(\.appAccent) private var appAccent

    var body: some View {
        ZStack {
            // Subtle top-to-bottom system fill — gives a hint of depth without
            // the busy mesh, and adapts to light/dark for free.
            LinearGradient(
                colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                // Brand identity — the logo glyph follows `.primary`, so it flips
                // black-on-light / white-on-dark, while the five accent dots keep
                // their brand colors in both appearances.
                VStack(spacing: 22) {
                    CullaLogo()
                        .frame(width: 96, height: 96)

                    VStack(spacing: 10) {
                        Text("CullaMusic")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))

                        Text(message)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                    }
                }

                Spacer(minLength: 0)

                VStack(spacing: 22) {
                    if let buttonTitle {
                        GradientCapsuleButton(
                            title: buttonTitle,
                            icon: buttonIcon,
                            iconEffect: status == .notDetermined ? .pulse : .none,
                            action: action
                        )
                        .padding(.horizontal, 32)
                    }

                    privacyFooter
                }
            }
            .padding(.vertical, 44)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Honest, plain-language privacy promise — every claim here is enforced by
    /// the privacy manifest, so it's safe to state plainly.
    private var privacyFooter: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)

            Text("Everything stays on your device.\nCullaMusic never collects, tracks, or shares your data.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
    }

    private var message: LocalizedStringKey {
        switch status {
        case .notDetermined:
            return "To swipe-sort your songs, CullaMusic needs to read your library and edit your playlists."
        case .denied, .restricted:
            return "Access was denied. Open Settings to grant CullaMusic permission to your Apple Music library."
        case .authorized:
            return ""
        @unknown default:
            return ""
        }
    }

    private var buttonTitle: LocalizedStringKey? {
        switch status {
        case .notDetermined:        return "Continue"
        case .denied, .restricted:  return "Open Settings"
        case .authorized:           return nil
        @unknown default:           return nil
        }
    }

    private var buttonIcon: String? {
        switch status {
        case .notDetermined:        return "arrow.right"
        case .denied, .restricted:  return "gearshape.fill"
        default:                    return nil
        }
    }

    private func action() {
        switch status {
        case .notDetermined:
            onRequest()
        case .denied, .restricted:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        default:
            break
        }
    }
}

#Preview {
    AuthGateView(status: .notDetermined, onRequest: {})
        .environment(\.appAccent, .blue)
}
