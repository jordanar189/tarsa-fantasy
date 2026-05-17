import SwiftUI

@main
struct TarsaFantasyApp: App {
    @State private var appState = AppState()

    init() {
        ImagePipelineConfig.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .task { await appState.bootstrap() }
        }
    }
}
