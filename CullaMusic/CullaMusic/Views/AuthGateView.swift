import SwiftUI
import MusicKit

struct AuthGateView: View {
    let status: MusicAuthorization.Status
    let onRequest: () -> Void

    @Environment(\.appAccent) private var appAccent

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.list")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            Text("Apple Music access")
                .font(.title2.weight(.semibold))

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: action) {
                Text(buttonTitle)
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(appAccent, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        case .notDetermined: return "Continue"
        case .denied, .restricted: return "Open Settings"
        case .authorized: return ""
        @unknown default: return ""
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
