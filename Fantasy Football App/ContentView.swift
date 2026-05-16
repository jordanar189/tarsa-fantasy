import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            PlayersView()
                .tabItem { Label("Players", systemImage: "person.2.fill") }
                .tag(AppTab.players)

            RankingsView()
                .tabItem { Label("Rankings", systemImage: "star.fill") }
                .tag(AppTab.rankings)

            LeaguesView()
                .tabItem { Label("Leagues", systemImage: "trophy.fill") }
                .tag(AppTab.leagues)
        }
        .overlay {
            if let error = app.bootstrapError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Couldn't load NFL data")
                        .font(.headline)
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Retry") {
                        Task { await app.bootstrap(force: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding(40)
            }
        }
    }
}

#Preview {
    ContentView().environment(AppState.preview)
}
