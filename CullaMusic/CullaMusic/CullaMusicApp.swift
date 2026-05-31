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
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(sharedModelContainer)
    }
}
