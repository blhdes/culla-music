import SwiftUI

/// "All caught up" terminal state shown when the swipe queue empties. Earns a
/// celebratory beat — the user just finished a sorting session and the screen
/// should acknowledge that, not just sit there like a form. The checkmark
/// bounces once on appear; the rest of the screen stays calm so the moment
/// reads as completion, not a notification.
struct EmptyStateView: View {
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            HeroIconTile(
                systemName: "checkmark.circle.fill",
                foreground: .green,
                bounceOnAppear: true
            )

            VStack(spacing: 10) {
                Text("All caught up")
                    .font(.system(.title2, design: .rounded).weight(.bold))

                Text("No more songs to sort. Your library will be checked again when you tap below.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            GradientCapsuleButton(
                title: "Refresh library",
                icon: "arrow.clockwise",
                action: onRefresh
            )
            .padding(.horizontal, 32)
            .padding(.top, 4)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
