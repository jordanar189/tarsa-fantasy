import SwiftUI

@main
struct FantasyFootballApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .task { await appState.bootstrap() }
        }
    }
}
