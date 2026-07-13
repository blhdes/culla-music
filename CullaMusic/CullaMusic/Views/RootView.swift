import SwiftUI
import SwiftData
import MusicKit

struct RootView: View {
    /// Flipped true once the first real screen has its content — drives the
    /// launch splash crossfade up in `SplashGate`. The auth gate readies as
    /// soon as we know we're not showing Home; the authorized path waits for
    /// HomeView's first load (see the `onReady` handed to it below).
    @Binding var isReady: Bool

    @Environment(\.modelContext) private var modelContext
    @State private var authStatus: MusicAuthorization.Status = MusicAuthorization.currentStatus
    @State private var activeViewModel: MusicSwipeViewModel?

    /// Mode pile selection lifted out of HomeView so it survives RootView's
    /// home ⇄ swipe screen swap (each swap remounts HomeView, which would
    /// otherwise reset a local @State back to `.library`). Living on RootView
    /// scopes it to the app session — fresh launches start at `.library`, not
    /// "whatever the user happened to last pick" — which is the intended
    /// behavior. Don't promote to @AppStorage; that would persist across
    /// launches and lose the cold-start reset.
    @State private var selectedHomeMode: ReviewMode = .library

    /// Picked Sort-From scope (a specific playlist or artist), lifted out of
    /// HomeView for the same reason as `selectedHomeMode`: each home ⇄ swipe
    /// swap remounts HomeView, so a local @State would reset to `nil` and the
    /// user would lose their scoped source on every trip back. Living here
    /// scopes it to the app session — fresh launches start unscoped — matching
    /// the built-in modes' persistence. Don't promote to @AppStorage.
    @State private var selectedSourceScope: SourceScope?

    /// True once the entry spring has logically completed — i.e. the Home →
    /// Swipe crossfade has landed. Drives the play-button reveal (and the
    /// first-run guide) so they show as a *consequence* of the transition
    /// finishing, not on a fixed timer. Re-armed at the start of every
    /// session in `startSession`.
    @State private var entrySettled = false

    @AppStorage("appColorScheme") private var colorSchemeRaw: String = "system"
    @AppStorage("appAccentPalette") private var accentPaletteRaw: String = AccentPalette.blue.rawValue

    private var appColorScheme: ColorScheme? {
        switch colorSchemeRaw {
        case "light": .light
        case "dark":  .dark
        default:      nil
        }
    }

    private var palette: AccentPalette {
        AccentPalette(rawValue: accentPaletteRaw) ?? .blue
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            switch authStatus {
            case .authorized:
                ZStack {
                    if let vm = activeViewModel {
                        MusicSwipeView(
                            viewModel: vm,
                            onBack: endSession,
                            chromeRevealed: entrySettled
                        )
                            // Per-VM identity so the second swipe session starts
                            // with fresh @State (cardOffset, flyOffTask, sheet
                            // bindings…). Without this, SwiftUI was reusing the
                            // first session's state slot because the conditional
                            // resolves to the same view type at the same position,
                            // which left the back button's chromeOpacity stuck at
                            // zero from a half-finished prior gesture.
                            .id(ObjectIdentifier(vm))
                            .transition(.opacity)
                            .zIndex(1)
                    } else {
                        HomeView(
                            onStart: startSession,
                            selectedMode: $selectedHomeMode,
                            source: $selectedSourceScope,
                            onReady: { isReady = true }
                        )
                            .transition(.parallaxRecede)
                            .zIndex(0)
                    }
                }
            case .notDetermined, .denied, .restricted:
                AuthGateView(status: authStatus, onRequest: requestAuth)
            @unknown default:
                AuthGateView(status: authStatus, onRequest: requestAuth)
            }
        }
        .task {
            seedDefaults()
            authStatus = MusicAuthorization.currentStatus
            // Auth gate / denied screens are static, so they're ready the
            // instant we know Home isn't showing. The authorized path readies
            // itself from HomeView's `onReady` once its playlists have synced.
            if authStatus != .authorized {
                isReady = true
            }
        }
        .preferredColorScheme(appColorScheme)
        // Don't set a global .tint(palette.color) — that propagates the
        // accent onto every toggle, picker, segmented control, and checkmark,
        // which reads as visual noise and (on light theme) low-contrast for
        // brighter palettes. Critical surfaces opt in to the palette accent
        // explicitly by reading \.appAccent and applying .tint themselves.
        .environment(\.appAccent, palette.color)
    }

    // MARK: - Actions

    private func requestAuth() {
        Task {
            let status = await MusicLibraryService.shared.requestAuthorization()
            authStatus = status
        }
    }

    @MainActor
    private func startSession(config: SwipeConfig, anchorSongs: [Song] = []) {
        let vm = MusicSwipeViewModel(
            config: config,
            modelContext: modelContext,
            anchorSongs: anchorSongs
        )
        // ObjectIdentifier of the freshly minted VM — used to gate the
        // completion handler so a rapid back-out → re-enter can't let a stale
        // completion flash the play button on the new session prematurely.
        let sessionID = ObjectIdentifier(vm)
        entrySettled = false
        // One spring drives the whole hand-off: the swipe screen fades in
        // while HomeView steps back via parallaxRecede. The completion
        // handler fires when the spring logically lands, so the play button
        // reveal is a consequence of the transition finishing — not a
        // guessed timer.
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
            activeViewModel = vm
        } completion: {
            guard let active = activeViewModel,
                  ObjectIdentifier(active) == sessionID else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                entrySettled = true
            }
        }
        Task { @MainActor in
            await vm.loadInitial()
        }
    }

    private func endSession() {
        // The swipe screen fades out in place (its card's artwork tile is
        // already receding — MusicSwipeView flips that before calling here)
        // while HomeView settles forward via parallaxRecede. The play disc
        // just rides the tile + fade; no separate pull needed.
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
            activeViewModel = nil
        }
    }

    private func seedDefaults() {
        if UserDefaults.standard.object(forKey: "hapticsEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "hapticsEnabled")
        }
    }
}
