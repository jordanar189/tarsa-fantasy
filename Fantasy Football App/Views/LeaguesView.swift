import SwiftUI

struct LeaguesView: View {
    @Environment(AppState.self) private var app
    @State private var showingCreate = false
    @State private var navPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navPath) {
            Group {
                if app.leagueSummaries.isEmpty {
                    ContentUnavailableView {
                        Label("No leagues yet", systemImage: "trophy")
                    } description: {
                        Text("Create one to set up rosters and run a season.")
                    } actions: {
                        Button("New League") { showingCreate = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        Section {
                            Button {
                                showingCreate = true
                            } label: {
                                Label("New League", systemImage: "plus.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        Section("Your leagues") {
                            ForEach(app.leagueSummaries) { lg in
                                NavigationLink(value: lg.id) {
                                    LeagueListRow(summary: lg)
                                }
                            }
                            .onDelete { offsets in
                                let ids = offsets.map { app.leagueSummaries[$0].id }
                                Task {
                                    for id in ids { await app.deleteLeague(id) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Leagues")
            .toolbar { SeasonPickerToolbar() }
            .navigationDestination(for: String.self) { id in
                LeagueDetailView(leagueID: id)
            }
            .sheet(isPresented: $showingCreate) {
                CreateLeagueView()
            }
            .task { await app.reloadLeagues() }
        }
    }
}

struct LeagueListRow: View {
    let summary: LeagueSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.name).font(.headline)
            HStack(spacing: 8) {
                Text(String(summary.season)).monospacedDigit()
                Text("•").foregroundStyle(.secondary)
                Text(summary.scoring.label)
                Text("•").foregroundStyle(.secondary)
                Text("\(summary.teamCount) teams")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
