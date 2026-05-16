import SwiftUI

struct PlayersView: View {
    @Environment(AppState.self) private var app
    @State private var query: String = ""
    @State private var position: Position = .all
    @State private var selectedPlayerID: String? = nil

    private var results: [PlayerSummary] {
        Fantasy.search(
            players: app.selectedPlayers(),
            query: query,
            position: position,
            scoring: .ppr,
            limit: 150
        )
    }

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            VStack(spacing: 0) {
                ChipRow(
                    items: Position.allCases,
                    selection: $position
                ) { Text($0.label) }
                .padding(.vertical, 8)

                if app.isLoadingSeason && app.selectedPlayers().isEmpty {
                    Spacer()
                    ProgressView("Loading \(app.selectedSeason) stats…")
                    Spacer()
                } else if results.isEmpty {
                    Spacer()
                    ContentUnavailableView(
                        "No players",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text(query.isEmpty
                            ? "Try a different position."
                            : "No players match “\(query)”.")
                    )
                    Spacer()
                } else {
                    List(results) { row in
                        Button {
                            selectedPlayerID = row.id
                        } label: {
                            PlayerRow(summary: row)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search players, teams")
            .navigationTitle("Players")
            .toolbar { SeasonPickerToolbar() }
            .sheet(item: $selectedPlayerID.asIdentifiable) { id in
                PlayerDetailView(playerID: id.id)
                    .presentationDetents([.large])
            }
        }
    }
}

struct PlayerRow: View {
    let summary: PlayerSummary

    var body: some View {
        HStack(spacing: 12) {
            PlayerAvatar(url: summary.headshotURL, fallback: summary.name.initialsFromName)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name).font(.headline)
                HStack(spacing: 6) {
                    PositionPill(position: summary.position)
                    Text(summary.team).font(.caption).foregroundStyle(.secondary)
                    Text("• \(summary.gamesPlayed) GP")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            PointsBadge(points: summary.points,
                        subtitle: "\(summary.pointsPerGame.fpString)/g")
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

struct SeasonPickerToolbar: ToolbarContent {
    @Environment(AppState.self) private var app

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            @Bindable var app = app
            Menu {
                Picker("Season", selection: $app.selectedSeason) {
                    ForEach(app.seasons, id: \.self) { season in
                        Text(String(season)).tag(season)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(String(app.selectedSeason))
                        .monospacedDigit()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
            }
            .onChange(of: app.selectedSeason) { _, new in
                Task { await app.loadSeason(new) }
            }
        }
    }
}

// Bridge an optional String? to a Sheet's `item:` binding so we can present
// detail sheets keyed by player id.
struct IdentifiableString: Identifiable, Hashable {
    let id: String
}

extension Binding where Value == String? {
    var asIdentifiable: Binding<IdentifiableString?> {
        Binding<IdentifiableString?>(
            get: { wrappedValue.map(IdentifiableString.init(id:)) },
            set: { wrappedValue = $0?.id }
        )
    }
}
