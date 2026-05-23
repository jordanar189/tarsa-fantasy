import SwiftUI

// Embedded inside NFLHubView's "Players" sub-tab. Tapping a row opens the
// player profile via the app-wide presenter (app.showPlayer).
struct PlayersBrowser: View {
    @Environment(AppState.self) private var app
    @State private var query: String = ""
    @State private var position: Position = .all
    @State private var availability: Availability = .all
    @State private var matchupMap: [String: (rating: MatchupRating, opponent: String, isHome: Bool)] = [:]
    @State private var comparing: Bool = false
    @State private var compareSelection: Set<String> = []
    @State private var showingCompareSheet: Bool = false
    // Recently-dropped players in the selected league, so the claim action
    // knows whether an add is instant (free agent) or a waiver claim.
    @State private var dropped: [DroppedPlayer] = []
    @State private var claimTarget: ClaimTarget? = nil

    enum Availability: String, CaseIterable, Identifiable, Hashable {
        case all = "All", available = "Available"
        var id: String { rawValue }
    }

    struct ClaimTarget: Identifiable {
        let team: FantasyTeam
        let addPlayer: PlayerSummary
        let isOnWaivers: Bool
        let waiverUntil: Date?
        var id: String { addPlayer.id }
    }

    // Player IDs already on some roster in the selected league.
    private var rosteredIDs: Set<String> {
        guard let lg = app.selectedLeague else { return [] }
        return Set(lg.teams.flatMap { $0.roster })
    }

    // The team the signed-in user controls in the selected league (the sim's
    // primary team when every team is creator-owned).
    private var myTeam: FantasyTeam? {
        guard let lg = app.selectedLeague else { return nil }
        if lg.isTest, let id = AppState.primaryTeamID(in: lg) {
            return lg.teams.first(where: { $0.id == id })
        }
        guard let uid = app.session?.userID else { return nil }
        return lg.teams.first(where: { $0.ownerID == uid })
    }

    private var results: [PlayerSummary] {
        let base = Fantasy.search(
            players: app.displaySelectedPlayers(),
            query: query,
            position: position,
            scoring: app.activeScoring,
            limit: availability == .available ? 0 : 150
        )
        guard availability == .available, app.selectedLeague != nil else {
            return Array(base.prefix(150))
        }
        let taken = rosteredIDs
        return Array(base.lazy.filter { !taken.contains($0.id) }.prefix(150))
    }

    var body: some View {
        VStack(spacing: 0) {
            if comparing { compareHeaderBar }
            if app.isProjectedSeason(app.selectedSeason) { projectedBanner }
            if app.selectedLeague != nil {
                SegmentedTabPicker(items: Availability.allCases, selection: $availability) {
                    Text($0.rawValue)
                }
                .padding(.horizontal, FFSpace.l)
                .padding(.top, FFSpace.s)
            }
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
                            app.showPlayer(row.id)
                        }
                    } label: {
                        PlayerRow(
                            summary: row, source: app.displaySelectedPlayers(),
                            scoring: app.activeScoring,
                            matchup: matchupMap[row.id],
                            selectedForCompare: comparing ? compareSelection.contains(row.id) : nil
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(FFColor.bg)
                    .listRowSeparatorTint(FFColor.border)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        claimSwipeAction(for: row)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .prefetchAvatars(urls: results.map(\.headshotURL))
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search players")
        .task(id: app.selectedSeason) {
            await app.ensureProjectedSnapshot(season: app.selectedSeason)
            await loadMatchups()
        }
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
        .sheet(item: $claimTarget) { ctx in
            if let lg = app.selectedLeague {
                WaiverClaimSheet(
                    league: lg, team: ctx.team,
                    addPlayer: ctx.addPlayer,
                    isOnWaivers: ctx.isOnWaivers,
                    waiverUntil: ctx.waiverUntil
                ) { updated in
                    if let updated { app.selectedLeague = updated }
                    Task { await reloadDropped() }
                }
            }
        }
        .task(id: app.selectedLeagueID) { await reloadDropped() }
    }

    // Trailing swipe action to add a free agent / claim a waiver player onto the
    // user's team in the selected league. Hidden for rostered players, while
    // comparing, or when the user has no team.
    @ViewBuilder
    private func claimSwipeAction(for row: PlayerSummary) -> some View {
        if !comparing, let team = myTeam, !rosteredIDs.contains(row.id) {
            let drop = dropped.first(where: { $0.playerID == row.id && $0.isOnWaivers })
            let onWaivers = drop != nil
            Button {
                claimTarget = ClaimTarget(
                    team: team, addPlayer: row,
                    isOnWaivers: onWaivers, waiverUntil: drop?.waiverUntil
                )
            } label: {
                Label(onWaivers ? "Claim" : "Add", systemImage: "plus.circle.fill")
            }
            .tint(FFColor.accent)
        }
    }

    private func reloadDropped() async {
        guard let id = app.selectedLeagueID else { dropped = []; return }
        dropped = await app.droppedPlayers(leagueID: id)
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
            players: app.displaySelectedPlayers(),
            nextOppByTeam: nextOpp,
            dvpByPosition: dvp
        )
    }

    private var projectedBanner: some View {
        HStack(spacing: FFSpace.s) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FFColor.accent)
            Text("PROJECTED · \(String(app.selectedSeason)) preseason — model projections, not real stats")
                .font(.ffMicro)
                .foregroundStyle(FFColor.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.s)
        .background(FFColor.accentSoft)
        .ffHairlineBottom()
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
