import SwiftUI

/// Central registry of one-time onboarding flags. Each is an `@AppStorage` key
/// flipped to `true` once the user has seen (or dismissed) the hint, so it never
/// shows again. Naming the keys here keeps them from drifting across the views
/// that read them — `MusicSwipeView` and `HomeView` both point at these.
enum OnboardingFlags {
    /// First-run gesture guide over a populated swipe deck. The guide teaches
    /// all four swipe directions plus double-tap-to-skip, so it's the only
    /// swipe-screen tip — no separate double-tap / long-press capsules.
    static let swipeGuide = "hasSeenSwipeGuide"
    /// Home hero "drag to peek / tap to browse" capsule.
    static let homeHeroHint = "hasSeenHomeHeroHint"

    /// Every onboarding key, so a debug reset can clear them all in one place.
    /// Add new tips here as well as above.
    static var allKeys: [String] {
        [swipeGuide, homeHeroHint]
    }
}

/// A calm, dismissible coach-mark capsule — icon + one line + a close button, on
/// glass. The app's single hint style, factored out of `MusicSwipeView` so every
/// one-time tip looks and dismisses the same way.
///
/// The caller owns the `@AppStorage` flag and decides *when* to show it; this
/// view just renders and reports the close tap via `onClose`.
struct CoachTip: View {
    let icon: String
    let text: LocalizedStringKey
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassSurface(in: Capsule())
        // The whole capsule dismisses, not just the X — a tip is something you
        // acknowledge by touching, and a small target inside a small pill is
        // fussy. The X stays as the explicit affordance; taps anywhere else on
        // the pill route to the same `onClose`. `contentShape` makes the padded
        // transparent rim tappable too, so there's no dead zone.
        .contentShape(Capsule())
        .onTapGesture(perform: onClose)
    }
}
