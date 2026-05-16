import SwiftUI

struct RankingsView: View {
    @Environment(AppState.self) private var app
    @State private var scope: Fantasy.RankScope = .season
    @State private var scoring: Scoring = .ppr
    @State private var position: Position = .all
    @State private var week: Int = 1
    @State private var selectedPlayerID: String? = nil

    private var weeks: [Int] { app.availableWeeks(season: app.selectedSeason) }

    private var rows: [Rank] {
        Fantasy.rank(
            players: app.selectedPlayers(),
            scope: scope,
            week: scope == .week ? week : nil,
            position: position,
            scoring: scoring,
            limit: 100
        )
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Rankings")
                .toolbar { SeasonPickerToolbar() }
                .onAppear {
                    if scope == .week, let first = weeks.first { week = first }
                }
                .onChange(of: weeks) { _, new in
                    if !new.contains(week), let f = new.first { week = f }
                }
                .sheet(item: $selectedPlayerID.asIdentifiable) { id in
                    PlayerDetailView(playerID: id.id)
                        .presentationDetents([.large])
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            scopePicker
            if scope == .week { weekPicker.padding(.horizontal).padding(.vertical, 8) }
            scoringPicker
            ChipRow(items: Position.allCases, selection: $position) { Text($0.label) }
                .padding(.vertical, 8)
            list
        }
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $scope) {
            ForEach(Fantasy.RankScope.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var scoringPicker: some View {
        Picker("Scoring", selection: $scoring) {
            ForEach(Scoring.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var list: some View {
        if app.isLoadingSeason && app.selectedPlayers().isEmpty {
            Spacer()
            ProgressView("Loading \(app.selectedSeason) stats…")
            Spacer()
        } else if rows.isEmpty {
            Spacer()
            ContentUnavailableView(
                "No results",
                systemImage: "list.number",
                description: Text("No players match the selected filters.")
            )
            Spacer()
        } else {
            List(rows) { row in
                Button {
                    selectedPlayerID = row.id
                } label: {
                    RankingRow(row: row, scope: scope)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private var weekPicker: some View {
        HStack {
            Text("Week").foregroundStyle(.secondary)
            Spacer()
            Menu {
                Picker("Week", selection: $week) {
                    ForEach(weeks, id: \.self) { w in
                        Text("Week \(w)").tag(w)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Week \(week)").monospacedDigit()
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
            }
        }
    }
}

struct RankingRow: View {
    let row: Rank
    let scope: Fantasy.RankScope

    var body: some View {
        HStack(spacing: 12) {
            Text("\(row.rank)")
                .font(.system(.subheadline, design: .rounded)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 26, alignment: .trailing)
            PlayerAvatar(url: row.headshotURL, fallback: row.name.initialsFromName)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.headline)
                metaRow
            }
            Spacer()
            PointsBadge(points: row.points, subtitle: row.pointsPerGame.map { "\($0.fpString)/g" })
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var metaRow: some View {
        HStack(spacing: 6) {
            PositionPill(position: row.position)
            Text(row.team).font(.caption).foregroundStyle(.secondary)
            if scope == .week, let opp = row.opponent, !opp.isEmpty {
                Text("vs \(opp)").font(.caption).foregroundStyle(.secondary)
            } else if let gp = row.gamesPlayed {
                Text("• \(gp) GP").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
