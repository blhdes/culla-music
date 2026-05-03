import SwiftUI
import SwiftData
import MusicKit

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var authStatus: MusicAuthorization.Status = MusicAuthorization.currentStatus
    @State private var viewModel: MusicSwipeViewModel?

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            switch authStatus {
            case .authorized:
                if let viewModel {
                    MusicSwipeView(viewModel: viewModel)
                } else {
                    ProgressView("Loading library…")
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
            if authStatus == .authorized, viewModel == nil {
                await loadVM()
            }
        }
    }

    private func requestAuth() {
        Task {
            let status = await MusicLibraryService.shared.requestAuthorization()
            authStatus = status
            if status == .authorized, viewModel == nil {
                await loadVM()
            }
        }
    }

    private func loadVM() async {
        let vm = MusicSwipeViewModel(modelContext: modelContext)
        viewModel = vm
        await vm.loadInitial()
    }

    /// First-launch defaults so Haptics actually fires (it gates on this key).
    private func seedDefaults() {
        if UserDefaults.standard.object(forKey: "hapticsEnabled") == nil {
            UserDefaults.standard.set(true, forKey: "hapticsEnabled")
        }
    }
}
