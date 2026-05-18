import SwiftUI
import SafariServices

/// Thin SwiftUI wrapper around `SFSafariViewController`. Used by the artist
/// hub to open a Google search inside Culla rather than kicking the user out
/// to Safari, so they can dismiss back into the swipe deck in one tap.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: config)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
