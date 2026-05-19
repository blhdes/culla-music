import SwiftUI
import SwiftData
import MusicKit

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var authStatus: MusicAuthorization.Status = MusicAuthorization.currentStatus
    @State private var activeConfig: SwipeConfig?
    @State private var activeViewModel: MusicSwipeViewModel?

    /// Shared namespace for the Home → Swipe hero morph. The "Start Cullaing"
    /// button on Home and the artwork on the current SongCard tag the same
    /// `heroStart` id; SwiftUI interpolates the frame between them so the
    /// button visibly grows into the card (and shrinks back on dismiss).
    @Namespace private var heroNamespace

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
                        MusicSwipeView(viewModel: vm, onBack: endSession, heroNamespace: heroNamespace)
                            .transition(.opacity)
                            .zIndex(1)
                    } else {
                        HomeView(onStart: startSession, heroNamespace: heroNamespace)
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
        }
        .preferredColorScheme(appColorScheme)
        .tint(palette.color)
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
    private func startSession(config: SwipeConfig) {
        let vm = MusicSwipeViewModel(config: config, modelContext: modelContext)
        // withAnimation here (not on the conditional) drives both the matched
        // hero morph and HomeView's parallaxRecede transition off the same spring.
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
            activeViewModel = vm
        }
        Task { @MainActor in
            await vm.loadInitial()
        }
    }

    private func endSession() {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
            activeViewModel = nil
            activeConfig = nil
        }
    }

    private func seedDefaults() {
        if UserDefaults.standard.object(forKey: "hapticsEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "hapticsEnabled")
        }
    }
}
