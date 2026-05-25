import SwiftUI

@main
struct TarsaFantasyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    init() {
        ImagePipelineConfig.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .task { await appState.bootstrap() }
                .onOpenURL { appState.handleInvite(url: $0) }
        }
    }
}
