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

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(sharedModelContainer)
    }
}
