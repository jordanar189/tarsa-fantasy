import SwiftUI

struct LeagueDetailView: View {
    @Environment(AppState.self) private var app
    let leagueID: String

    @State private var league: League? = nil
    @State private var section: Section = .standings
    @State private var week: Int = 1
    @State private var editingTeam: FantasyTeam? = nil

    enum Section: String, CaseIterable, Identifiable {
        case standings, scoreboard, rosters
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let league {
                header(league)
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                switch section {
                case .standings:  standingsView(league)
                case .scoreboard: scoreboardView(league)
                case .rosters:    rostersView(league)
                }
            } else {
                ProgressView().padding(.top, 60)
            }
            Spacer()
        }
        .navigationTitle(league?.name ?? "League")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: leagueID) {
            await loadLeague()
        }
        .sheet(item: $editingTeam) { team in
            if let league {
                RosterEditorView(league: league, team: team) { updatedLeague in
                    self.league = updatedLeague
                }
            }
        }
    }

    private func loadLeague() async {
        league = await app.league(leagueID)
        await app.loadSeason(league?.season ?? app.selectedSeason)
        if let plan = league?.schedule.first { week = plan.week }
    }

    private func header(_ lg: League) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(lg.name).font(.title3.bold())
                HStack(spacing: 6) {
                    Text(String(lg.season)).monospacedDigit()
                    Text("•").foregroundStyle(.secondary)
                    Text(lg.scoring.label)
                    Text("•").foregroundStyle(.secondary)
                    Text("\(lg.teams.count) teams")
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: Standings
    @ViewBuilder
    private func standingsView(_ lg: League) -> some View {
        let players = app.players(season: lg.season)
        let rows = Fantasy.standings(league: lg, players: players)
        List {
            ForEach(rows) { row in
                HStack {
                    Text("\(row.rank)")
                        .frame(minWidth: 26, alignment: .trailing)
                        .foregroundStyle(.secondary).monospacedDigit()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).font(.headline)
                        Text("\(row.wins)-\(row.losses)\(row.ties > 0 ? "-\(row.ties)" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(row.pointsFor.fpString) PF")
                            .font(.subheadline).monospacedDigit()
                        Text("\(row.pointsAgainst.fpString) PA")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: Scoreboard
    @ViewBuilder
    private func scoreboardView(_ lg: League) -> some View {
        let players = app.players(season: lg.season)
        let weeks = lg.schedule.map(\.week)
        let result = Fantasy.scoreboard(league: lg, players: players, week: week)

        VStack(spacing: 0) {
            HStack {
                Text("Week").foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Picker("Week", selection: $week) {
                        ForEach(weeks, id: \.self) { w in Text("Week \(w)").tag(w) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Week \(week)").monospacedDigit()
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
            }
            .padding(.horizontal).padding(.top, 8)

            List {
                if result.matchups.isEmpty && result.byes.isEmpty {
                    Text("No matchups scheduled for week \(week).")
                        .foregroundStyle(.secondary)
                }
                ForEach(result.matchups) { m in
                    matchupCard(m)
                }
                if !result.byes.isEmpty {
                    SwiftUI.Section("Byes") {
                        ForEach(result.byes) { bye in
                            Text(bye.name).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func matchupCard(_ m: LeagueMatchup) -> some View {
        VStack(spacing: 8) {
            HStack {
                sideLabel(m.home, isWinner: m.played && m.home.points > m.away.points)
                Text("vs").foregroundStyle(.secondary)
                sideLabel(m.away, isWinner: m.played && m.away.points > m.home.points)
            }
            if m.played {
                DisclosureGroup("Rosters") {
                    HStack(alignment: .top) {
                        rosterColumn(title: m.home.name, roster: m.home.roster)
                        rosterColumn(title: m.away.name, roster: m.away.roster)
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 6)
    }

    private func sideLabel(_ side: LeagueSide, isWinner: Bool) -> some View {
        VStack(spacing: 2) {
            Text(side.name).font(.subheadline.weight(isWinner ? .bold : .regular))
            Text(side.points.fpString).font(.title3.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func rosterColumn(title: String, roster: [LeagueRosterEntry]) -> some View {
        let starters = roster.filter { $0.slot.isStarter }
        let bench    = roster.filter { $0.slot == .bench }
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold())
            ForEach(starters) { entry in
                HStack(spacing: 4) {
                    Text(entry.slot.label)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .leading)
                    Text(entry.name).lineLimit(1)
                        .foregroundStyle(entry.playerID.isEmpty ? .secondary : .primary)
                    Spacer()
                    Text(entry.points.fpString)
                        .foregroundStyle(entry.played ? .primary : .secondary)
                        .monospacedDigit()
                }
                .font(.caption2)
            }
            if !bench.isEmpty {
                Text("Bench").font(.caption2.bold()).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(bench) { entry in
                    HStack(spacing: 4) {
                        Text(entry.name).lineLimit(1)
                        Spacer()
                        Text(entry.points.fpString)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            if roster.isEmpty {
                Text("No roster set").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Rosters
    @ViewBuilder
    private func rostersView(_ lg: League) -> some View {
        let players = app.players(season: lg.season)
        let config = lg.rosterConfig
        List {
            ForEach(lg.teams) { team in
                SwiftUI.Section {
                    let (starters, bench) = Fantasy.resolveLineup(
                        team: team, players: players,
                        config: config, scoring: lg.scoring
                    )
                    if team.roster.isEmpty {
                        Text("No players yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(zip(config.starterSlots, starters).enumerated()), id: \.offset) { _, pair in
                            lineupRow(slot: pair.0, playerID: pair.1, players: players, scoring: lg.scoring)
                        }
                        if !bench.isEmpty {
                            Text("Bench")
                                .font(.caption.bold()).foregroundStyle(.secondary)
                                .padding(.top, 4)
                            ForEach(bench, id: \.self) { pid in
                                lineupRow(slot: .bench, playerID: pid, players: players, scoring: lg.scoring)
                            }
                        }
                    }
                    Button {
                        editingTeam = team
                    } label: {
                        Label("Edit roster", systemImage: "pencil")
                    }
                } header: {
                    HStack {
                        Text(team.name)
                        Spacer()
                        Text("\(team.roster.count)/\(config.totalSize)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func lineupRow(
        slot: LineupSlot, playerID: String,
        players: [String: Player], scoring: Scoring
    ) -> some View {
        let player = playerID.isEmpty ? nil : players[playerID]
        let summary = player.map { Fantasy.summary($0, scoring: scoring) }
        return HStack(spacing: 10) {
            Text(slot.label)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            if let summary {
                PositionPill(position: summary.position)
                VStack(alignment: .leading) {
                    Text(summary.name).lineLimit(1)
                    Text(summary.team).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(summary.points.fpString).monospacedDigit()
            } else {
                Text("Empty").foregroundStyle(.secondary).italic()
                Spacer()
            }
        }
    }
}
