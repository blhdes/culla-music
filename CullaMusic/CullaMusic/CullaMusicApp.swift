import SwiftUI
import SwiftData

@main
struct CullaMusicApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Playlist.self,
            SortedSong.self,
            DismissedSong.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        // Carry saved sorts from the old combined keys to the new
        // (field, direction) pair before any view reads them.
        SortPreferenceMigration.run()

        // DEBUG-only: replay the onboarding tips when the flag is set, before
        // any view reads the "have they seen this?" flags. No-op in Release.
        DebugFlags.resetOnboardingTipsIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            SplashGate()
        }
        .modelContainer(sharedModelContainer)
    }
}

/// Holds the Culla brand mark over the app on a cold launch, then crossfades
/// into `RootView`. Mirrors the photos app's `SplashGate`: a full-screen brand
/// splash sits above the live content, which is faded in once `isReady` flips.
/// RootView's own `.task` (seeding defaults, resolving Apple Music auth) runs
/// underneath during the hold, so the app is settled by the time it appears.
private struct SplashGate: View {
    @State private var isReady = false

    // Same key RootView reads — so a user's forced light/dark choice applies to
    // the splash too, instead of flashing the system scheme for the first beat.
    @AppStorage("appColorScheme") private var colorSchemeRaw: String = "system"

    // Same key and default as the photos app: the status bar stays hidden for
    // the immersive full-screen feel unless the user opts back in.
    @AppStorage("statusBarVisible") private var statusBarVisible: Bool = false

    private var appColorScheme: ColorScheme? {
        switch colorSchemeRaw {
        case "light": .light
        case "dark":  .dark
        default:      nil
        }
    }

    var body: some View {
        ZStack {
            RootView(isReady: $isReady)
                .opacity(isReady ? 1 : 0)

            if !isReady {
                splash
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.4), value: isReady)
        .preferredColorScheme(appColorScheme)
        .statusBarHidden(!statusBarVisible)
        .task {
            // Failsafe only — the real dismissal comes from RootView flipping
            // `isReady` once the first screen's content has actually loaded
            // (auth resolved, or Home's playlists synced). This timer just
            // guarantees a dead network can never trap the user on the splash.
            try? await Task.sleep(for: .seconds(8))
            isReady = true
        }
    }

    /// The same logo + two-tone wordmark as the home strip, scaled up and
    /// centered. The glyph follows `.primary` (flips per appearance); the five
    /// accent dots keep their fixed brand hues.
    private var splash: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                CullaLogo()
                    .frame(width: 92, height: 92)

                HStack(spacing: 5) {
                    Text("culla")
                        .foregroundStyle(.primary)
                    Text("music")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .tracking(0.5)
            }
        }
    }
}
