import SwiftUI
import MusicKit

/// First-launch screen requesting Apple Music access. Sets the visual tone for
/// the rest of the app — uses the same Living-Glass vocabulary as HomeView
/// (mesh background + glass hero tile + gradient CTA) so this is recognizably
/// "Culla" before the user has even seen their library.
struct AuthGateView: View {
    let status: MusicAuthorization.Status
    let onRequest: () -> Void

    @Environment(\.appAccent) private var appAccent

    var body: some View {
        ZStack {
            LivingMeshBackground()

            VStack(spacing: 28) {
                HeroIconTile(
                    systemName: heroSymbol,
                    foreground: heroColor,
                    pulse: status == .notDetermined
                )

                VStack(spacing: 12) {
                    Text("Apple Music access")
                        .font(.system(.title2, design: .rounded).weight(.bold))

                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                if !buttonTitle.isEmpty {
                    GradientCapsuleButton(
                        title: buttonTitle,
                        icon: buttonIcon,
                        iconEffect: status == .notDetermined ? .pulse : .none,
                        action: action
                    )
                    .padding(.horizontal, 32)
                    .padding(.top, 8)
                }
            }
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// SF symbol shown in the hero tile. Swaps to a lock when access has been
    /// denied so the user understands why we can't proceed — the music.note
    /// icon would read as "we're loading something" instead of "we need you
    /// to flip a setting."
    private var heroSymbol: String {
        switch status {
        case .denied, .restricted: return "lock.shield"
        default:                   return "music.note.list"
        }
    }

    private var heroColor: Color {
        switch status {
        case .denied, .restricted: return .orange
        default:                   return appAccent
        }
    }

    private var message: String {
        switch status {
        case .notDetermined:
            return "Culla Music needs to read your library and edit your playlists to let you swipe-sort songs."
        case .denied, .restricted:
            return "Access was denied. Open Settings to grant permission."
        case .authorized:
            return ""
        @unknown default:
            return ""
        }
    }

    private var buttonTitle: String {
        switch status {
        case .notDetermined:        return "Continue"
        case .denied, .restricted:  return "Open Settings"
        case .authorized:           return ""
        @unknown default:           return ""
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
