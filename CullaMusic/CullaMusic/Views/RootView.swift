import SwiftUI
import SwiftData
import MusicKit

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var authStatus: MusicAuthorization.Status = MusicAuthorization.currentStatus
    @State private var activeConfig: SwipeConfig?
    @State private var activeViewModel: MusicSwipeViewModel?
    @State private var isLoadingDeck = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            switch authStatus {
            case .authorized:
                if let vm = activeViewModel {
                    MusicSwipeView(viewModel: vm, onBack: endSession)
                } else if isLoadingDeck {
                    ProgressView("Loading…")
                } else {
                    HomeView(onStart: startSession)
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
        isLoadingDeck = true
        Task { @MainActor in
            let vm = MusicSwipeViewModel(config: config, modelContext: modelContext)
            await vm.loadInitial()
            activeViewModel = vm
            isLoadingDeck = false
        }
    }

    private func endSession() {
        activeViewModel = nil
        activeConfig = nil
    }

    private func seedDefaults() {
        if UserDefaults.standard.object(forKey: "hapticsEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "hapticsEnabled")
        }
    }
}
