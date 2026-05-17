import SwiftUI

// Embedded inside NFLHubView's "Players" sub-tab. Selection bubbles up via
// the binding so the detail sheet is presented by the parent.
struct PlayersBrowser: View {
    @Environment(AppState.self) private var app
    @Binding var selectedPlayerID: String?
    @State private var query: String = ""
    @State private var position: Position = .all
    @State private var matchupMap: [String: (rating: MatchupRating, opponent: String, isHome: Bool)] = [:]
    @State private var comparing: Bool = false
    @State private var compareSelection: Set<String> = []
    @State private var showingCompareSheet: Bool = false

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
        VStack(spacing: 0) {
            if comparing { compareHeaderBar }
            ChipRow(items: Position.allCases, selection: $position) { Text($0.label) }
                .padding(.vertical, FFSpace.s)

            if app.isLoadingSeason && app.selectedPlayers().isEmpty {
                Spacer()
                ProgressView("Loading \(app.selectedSeason) stats…")
                    .tint(FFColor.accent)
                    .foregroundStyle(FFColor.textSecondary)
                Spacer()
            } else if results.isEmpty {
                Spacer()
                VStack(spacing: FFSpace.s) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(FFColor.textTertiary)
                    Text(query.isEmpty ? "No players" : "No matches")
                        .font(.ffTitle).foregroundStyle(FFColor.textPrimary)
                    Text(query.isEmpty
                         ? "Try a different position."
                         : "No players match \"\(query)\".")
                        .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                }
                Spacer()
            } else {
                List(results) { row in
                    Button {
                        if comparing {
                            toggleCompare(row.id)
                        } else {
                            selectedPlayerID = row.id
                        }
                    } label: {
                        PlayerRow(
                            summary: row, source: app.selectedPlayers(),
                            matchup: matchupMap[row.id],
                            selectedForCompare: comparing ? compareSelection.contains(row.id) : nil
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(FFColor.bg)
                    .listRowSeparatorTint(FFColor.border)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .prefetchAvatars(urls: results.map(\.headshotURL))
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search players")
        .task(id: app.selectedSeason) { await loadMatchups() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(comparing ? "Done" : "Compare") {
                    withAnimation { comparing.toggle() }
                    if !comparing { compareSelection.removeAll() }
                }
                .foregroundStyle(FFColor.accent)
            }
        }
        .sheet(isPresented: $showingCompareSheet) {
            ComparePlayersView(playerIDs: Array(compareSelection))
        }
    }

    private func toggleCompare(_ id: String) {
        if compareSelection.contains(id) {
            compareSelection.remove(id)
        } else if compareSelection.count < 3 {
            compareSelection.insert(id)
        }
    }

    private var compareHeaderBar: some View {
        HStack {
            Text("\(compareSelection.count)/3 selected")
                .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
            Spacer()
            Button("Compare") {
                showingCompareSheet = true
            }
            .font(.ffCaption.bold())
            .padding(.horizontal, FFSpace.m).padding(.vertical, 6)
            .background(compareSelection.count >= 2 ? FFColor.accent : FFColor.surfaceElevated,
                        in: Capsule())
            .foregroundStyle(compareSelection.count >= 2 ? FFColor.bg : FFColor.textTertiary)
            .disabled(compareSelection.count < 2)
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
        .background(FFColor.accentSoft)
        .ffHairlineBottom()
    }

    private func loadMatchups() async {
        async let schedules = app.schedules(season: app.selectedSeason)
        let positions = ["QB", "RB", "WR", "TE", "K"]
        async let dvpRows: [(String, [String: DvPEntry])] = withTaskGroup(of: (String, [String: DvPEntry]).self) { group in
            for pos in positions {
                group.addTask { (pos, await app.dvp(season: app.selectedSeason, position: pos)) }
            }
            var out: [(String, [String: DvPEntry])] = []
            for await pair in group { out.append(pair) }
            return out
        }
        let sched = await schedules
        let dvp = Dictionary(uniqueKeysWithValues: await dvpRows)
        let nextOpp = Fantasy.nextOpponentByTeam(schedules: sched)
        matchupMap = Fantasy.matchupRatingsByPlayer(
            players: app.selectedPlayers(),
            nextOppByTeam: nextOpp,
            dvpByPosition: dvp
        )
    }
}

// Enriched player row — adds sparkline + trend arrow + bye/opponent chips
// on top of the original. Reused on Rankings via a small wrapper.
struct PlayerRow: View {
    @Environment(AppState.self) private var app
    let summary: PlayerSummary
    // Full Player objects for the season so we can pull games for the
    // sparkline + bye/opponent context. Pass nil to skip the enrichments.
    var source: [String: Player]? = nil
    var showRank: Int? = nil
    var scoring: Scoring = .ppr
    var matchup: (rating: MatchupRating, opponent: String, isHome: Bool)? = nil
    // When non-nil, this row is in "compare picker" mode: shows a check.
    var selectedForCompare: Bool? = nil

    var body: some View {
        HStack(spacing: FFSpace.m) {
            if let selected = selectedForCompare {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? FFColor.accent : FFColor.textTertiary)
            }
            if let rank = showRank {
                Text("\(rank)")
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textSecondary)
                    .frame(width: 26, alignment: .leading)
            }
            PlayerAvatar(url: summary.headshotURL, fallback: summary.name.initialsFromName, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(summary.name).font(.ffBody).foregroundStyle(FFColor.textPrimary)
                        .lineLimit(1)
                    if let trend = currentTrend, summary.gamesPlayed >= 2 {
                        Image(systemName: trend.systemImage)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(trendColor(trend))
                    }
                }
                HStack(spacing: 6) {
                    PositionPill(position: summary.position)
                    if let injury = app.injuries[summary.id] {
                        InjuryBadge(injury: injury)
                    }
                    if let started = app.mostStarted[summary.id], started >= 50 {
                        Text("\(Int(started.rounded()))%")
                            .font(.ffMicro.bold())
                            .tracking(0.6)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(FFColor.accentSoft, in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(FFColor.accent)
                    }
                    Text(summary.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                    if let matchup, matchup.rating != .unknown {
                        Text(matchup.isHome ? "vs \(matchup.opponent)" : "@ \(matchup.opponent)")
                            .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        MatchupPill(rating: matchup.rating, compact: true)
                    } else if let bye = source?[summary.id]?.profile?.byeWeek {
                        Text("· BYE \(bye)")
                            .font(.ffMicro)
                            .foregroundStyle(FFColor.textTertiary)
                    }
                }
            }
            Spacer()
            if let player = source?[summary.id] {
                Sparkline(series: Fantasy.sparklineSeries(games: player.games, scoring: scoring))
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(summary.points.fpString)
                    .font(.ffStatMedium)
                    .foregroundStyle(FFColor.textPrimary)
                Text("\(summary.pointsPerGame.fpString)/g")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private var currentTrend: Trend? {
        guard let player = source?[summary.id] else { return nil }
        return Fantasy.trendDirection(games: player.games, scoring: scoring)
    }

    private func trendColor(_ t: Trend) -> Color {
        switch t {
        case .up:   return FFColor.positive
        case .flat: return FFColor.textTertiary
        case .down: return FFColor.negative
        }
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
                        .font(.ffStatSmall)
                        .foregroundStyle(FFColor.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
            .onChange(of: app.selectedSeason) { _, new in
                Task { await app.loadSeason(new) }
            }
        }
    }
}

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
