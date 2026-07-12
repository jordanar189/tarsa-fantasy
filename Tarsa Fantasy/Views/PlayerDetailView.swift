import SwiftUI

// Sleeper-grade player profile, presented as a sheet. The hub shows the
// header/hero, injury + matchup-ranks + value cards, the at-a-glance overview
// (acquire actions, market, weekly chart, news), and pushes the deeper pages
// (Details, Career, Game Log, Splits, Advanced, Matchups, Injuries) inside its
// own NavigationStack. Fetched data lives in PlayerDetailModel so the pushed
// pages share one load.
struct PlayerDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let playerID: String

    @State private var model = PlayerDetailModel()
    // Acquisition (overview card): waiver/free-agent claim + trade entry for
    // the selected league.
    @State private var claimTarget: AddClaimTarget? = nil
    @State private var tradeTarget: AcquireTradeTarget? = nil

    private var player: Player? { app.displaySelectedPlayers()[playerID] }
    private var isProjected: Bool { app.isProjectedSeason(app.selectedSeason) }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                if let player {
                    ScrollView {
                        VStack(spacing: FFSpace.l) {
                            header(player)
                            if let injury = app.injuries[player.id] {
                                injuryCard(injury)
                            }
                            if let card = ranksCard(for: player) { card }
                            valueCard(for: player)
                            overviewSection(for: player)
                            subpageLinks(for: player)
                        }
                        .padding(.horizontal, FFSpace.l)
                        .padding(.top, FFSpace.s)
                        .padding(.bottom, 40)
                    }
                } else {
                    VStack(spacing: FFSpace.s) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 32))
                            .foregroundStyle(FFColor.textTertiary)
                        Text("Player not found").font(.ffTitle).foregroundStyle(FFColor.textPrimary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // This screen is itself a sheet — host the team profile locally
            // so the header's team abbreviation can link out.
            .hostsTeamProfileSheet()
            .navigationTitle(player?.name ?? "Player")
            .navigationBarTitleDisplayMode(.inline)
            .leagueSwitcher()
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(FFColor.accent)
                }
            }
            // Keyed on season too: switching leagues changes app.selectedSeason
            // while this view stays mounted, and every load is season-scoped —
            // re-run so schedules/snaps/ranks don't go stale.
            .task(id: "\(playerID)#\(app.selectedSeason)") {
                await model.load(app: app, playerID: playerID)
            }
            .onChange(of: app.activeScoring) { _, new in model.scoring = new }
            .onChange(of: app.activeScoringSettings) { _, new in model.scoringSettings = new }
            .onChange(of: model.scoring) { _, _ in model.applyScoringChange(app: app, playerID: playerID) }
            .onChange(of: model.scoringSettings) { _, _ in model.applyScoringChange(app: app, playerID: playerID) }
            .sheet(item: $claimTarget) { ctx in
                if let lg = app.selectedLeague {
                    WaiverClaimSheet(
                        league: lg, team: ctx.team,
                        addPlayer: ctx.addPlayer,
                        isOnWaivers: ctx.isOnWaivers,
                        waiverUntil: ctx.waiverUntil
                    ) { updated in
                        if let updated { app.selectedLeague = updated }
                        Task { await model.reloadDropped(app: app) }
                    }
                }
            }
            .sheet(item: $tradeTarget) { t in
                if let lg = app.selectedLeague {
                    ProposeTradeView(
                        league: lg, fromTeam: t.fromTeam, counterOf: nil,
                        requestPlayer: (teamID: t.toTeamID, playerID: t.playerID)
                    ) { _ in }
                }
            }
            .task(id: app.selectedLeagueID) { await model.reloadDropped(app: app) }
        }
    }

    // MARK: - Subpage links

    private func subpageLinks(for p: Player) -> some View {
        VStack(spacing: 0) {
            subpageRow("Details")  { PlayerDetailsPage(player: p, model: model) }
            subpageRow("Career")   { PlayerCareerPage(player: p, model: model) }
            subpageRow("Game Log") { PlayerGameLogPage(player: p, model: model) }
            subpageRow("Splits")   { PlayerSplitsPage(player: p, model: model) }
            subpageRow("Advanced") { PlayerAdvancedPage(player: p, model: model) }
            subpageRow("Matchups") { PlayerMatchupsPage(player: p, model: model) }
            subpageRow("Injuries") { PlayerInjuriesPage(player: p, model: model) }
        }
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    private func subpageRow<Destination: View>(
        _ title: String, @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            HStack {
                Text(title).font(.ffBody).foregroundStyle(FFColor.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FFColor.textTertiary)
            }
            .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
            .contentShape(Rectangle())
            .ffHairlineBottom()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Header

    private func header(_ p: Player) -> some View {
        let nonActiveStatus: String? = {
            guard let s = p.profile?.status, !s.isEmpty, s.uppercased() != "ACT" else { return nil }
            return s
        }()
        return VStack(alignment: .leading, spacing: FFSpace.m) {
            HStack(alignment: .top, spacing: FFSpace.l) {
                PlayerAvatar(url: p.headshotURL, fallback: p.name.initialsFromName, size: 88)
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(FFColor.textPrimary)
                    HStack(spacing: 6) {
                        PositionPill(position: p.position)
                        Text(p.team).font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                            .teamLink(p.team)
                        if let n = p.profile?.jerseyNumber {
                            Text("· #\(n)").font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                        }
                        if let nonActiveStatus {
                            StateChip(state: .locked, label: nonActiveStatus)
                        }
                        if let value = app.playerValue(playerID: p.id) {
                            PlayerValueBadge(value: value)
                        }
                    }
                    if let strip = bioStrip(p) {
                        Text(strip)
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.textTertiary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            heroStats(for: p)
        }
        .ffHeroCard()
    }

    private func bioStrip(_ p: Player) -> String? {
        guard let profile = p.profile else { return nil }
        var parts: [String] = []
        if let age = profile.age            { parts.append("\(age) yrs") }
        if let h   = profile.heightDisplay  { parts.append(h) }
        if let w   = profile.weightLb       { parts.append("\(w) lb") }
        if let c   = profile.college        { parts.append(c) }
        if let d   = profile.draftDisplay   { parts.append(d) }
        if let e   = profile.experienceDisplay { parts.append(e) }
        if parts.isEmpty { return nil }
        return parts.joined(separator: " · ")
    }

    private func heroStats(for p: Player) -> some View {
        HStack(spacing: FFSpace.l) {
            if let projection = model.projection, !isProjected {
                heroStat(
                    label: "PROJ",
                    value: String(format: "%.1f", projection.points),
                    color: FFColor.accent
                )
            }
            if let rank = model.rankByID[p.id] {
                heroStat(label: "RANK", value: rank.label, color: FFColor.accent)
            }
            if let war = model.warByID[p.id] {
                heroStat(label: "WAR", value: String(format: "%+.1f", war),
                         color: war >= 0 ? FFColor.accent : FFColor.negative)
            }
            heroStat(
                label: "TREND",
                value: trendLabel(games: p.games),
                color: trendColor(games: p.games)
            )
            if let bye = p.profile?.byeWeek {
                heroStat(label: "BYE", value: "W\(bye)")
            }
            if let started = app.mostStarted[p.id] {
                heroStat(
                    label: "STARTED",
                    value: String(format: "%.0f%%", started),
                    color: started >= 90 ? FFColor.accent : FFColor.textPrimary
                )
            }
            if let nextOpp = nextOpponent(for: p) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NEXT").ffEyebrow(color: FFColor.textTertiary)
                    HStack(spacing: 4) {
                        Text(nextOpp.label)
                            .font(.ffStatSmall)
                            .foregroundStyle(FFColor.textPrimary)
                        if let rating = nextOpp.rating, rating != .unknown {
                            MatchupPill(rating: rating, compact: true)
                        }
                    }
                }
            }
            Spacer()
        }
    }

    private func heroStat(label: String, value: String, color: Color = FFColor.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).ffEyebrow(color: FFColor.textTertiary)
            Text(value)
                .font(.ffStatSmall)
                .foregroundStyle(color)
        }
    }

    private func trendLabel(games: [Game]) -> String {
        switch Fantasy.trendDirection(games: games, scoring: model.scoring, settings: model.scoringSettings) {
        case .up:   return "↑ Rising"
        case .flat: return "→ Steady"
        case .down: return "↓ Cooling"
        }
    }
    private func trendColor(games: [Game]) -> Color {
        switch Fantasy.trendDirection(games: games, scoring: model.scoring, settings: model.scoringSettings) {
        case .up:   return FFColor.positive
        case .flat: return FFColor.textSecondary
        case .down: return FFColor.negative
        }
    }

    // Best-effort: the next scheduled game for this player's team. If we
    // have no schedule data yet, returns nil and the chip is hidden.
    private func nextOpponent(for p: Player) -> (label: String, rating: MatchupRating?)? {
        guard !p.team.isEmpty else { return nil }
        let now = Date()
        guard let g = model.schedules
            .filter({ g in g.kickoff.map { $0 > now } ?? false })
            .first(where: { $0.home == p.team || $0.away == p.team }) else { return nil }
        let isHome = g.home == p.team
        let opp = isHome ? g.away : g.home
        let label = (isHome ? "vs " : "@ ") + opp
        let rating = MatchupRating.from(
            rank: model.dvpByPosition[p.position.uppercased()]?[opp]?.rank
        )
        return (label, rating)
    }

    // MARK: - Ranks card (team off vs next opponent def, from MFL)

    private func ranksCard(for p: Player) -> RanksCardView? {
        let own = app.teamRanks[p.team]
        let oppTeam = model.nextOpponentTeam(for: p)
        let opp = oppTeam.flatMap { app.teamRanks[$0] }
        // Hide entirely when we have nothing on either side (off-season).
        if own == nil && opp == nil { return nil }
        return RanksCardView(own: own, opp: opp, oppTeam: oppTeam)
    }

    // MARK: - Injury card

    private func injuryCard(_ injury: Injury) -> some View {
        let color: Color = {
            switch injury.status.uppercased() {
            case "OUT", "IR", "INJURED RESERVE", "PUP", "SUSPENDED": return FFColor.negative
            default:                                                  return FFColor.warning
            }
        }()
        return HStack(alignment: .top, spacing: FFSpace.m) {
            Image(systemName: "cross.case.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: FFSpace.s) {
                    Text(injury.status.uppercased())
                        .ffEyebrow(color: color)
                    if let details = injury.details, !details.isEmpty {
                        Text(details)
                            .font(.ffCaption)
                            .foregroundStyle(FFColor.textSecondary)
                    }
                }
                if let date = injury.expectedReturn {
                    Text("Expected return: \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(FFSpace.m)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: FFRadius.s))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.s)
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Value (high/medium/low) — owner-set, league-visible

    // The team in the selected league that currently rosters this player,
    // if any. Nil for free agents or when no league is selected.
    private func owningTeam(for p: Player) -> FantasyTeam? {
        guard let lg = app.selectedLeague else { return nil }
        return lg.teams.first { $0.roster.contains(p.id) }
    }

    private func canEditValue(for p: Player) -> Bool {
        guard let owner = owningTeam(for: p) else { return false }
        return owner.id == myLeagueTeam?.id
    }

    @ViewBuilder
    private func valueCard(for p: Player) -> some View {
        let owner = owningTeam(for: p)
        let editable = canEditValue(for: p)
        if editable, let team = owner {
            ownerValueCard(player: p, team: team)
        } else if let owner, let value = app.playerValue(teamID: owner.id, playerID: p.id) {
            spectatorValueCard(owner: owner, value: value)
        }
    }

    private func ownerValueCard(player p: Player, team: FantasyTeam) -> some View {
        let current = app.playerValue(teamID: team.id, playerID: p.id)
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text("MY VALUE").ffEyebrow()
                Spacer()
                if current != nil {
                    Button {
                        Task { await applyValue(nil, for: p, team: team) }
                    } label: {
                        Text("Clear")
                            .font(.ffMicro.bold())
                            .foregroundStyle(FFColor.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                ForEach(PlayerValue.allCases) { v in
                    let selected = current == v
                    Button {
                        Task { await applyValue(selected ? nil : v, for: p, team: team) }
                    } label: {
                        Text(v.label)
                            .font(.ffCaption.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                selected ? valueColor(v).opacity(0.22) : FFColor.surfaceElevated,
                                in: RoundedRectangle(cornerRadius: FFRadius.s)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: FFRadius.s)
                                    .strokeBorder(
                                        selected ? valueColor(v).opacity(0.6) : FFColor.border,
                                        lineWidth: 1
                                    )
                            )
                            .foregroundStyle(selected ? valueColor(v) : FFColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .ffCard()
    }

    private func spectatorValueCard(owner: FantasyTeam, value: PlayerValue) -> some View {
        HStack(spacing: FFSpace.s) {
            Text("\(owner.name.uppercased()) VALUES")
                .ffEyebrow()
            PlayerValueBadge(value: value)
            Spacer()
        }
        .ffCard()
    }

    private func valueColor(_ v: PlayerValue) -> Color {
        switch v {
        case .high:   return FFColor.positive
        case .medium: return FFColor.warning
        case .low:    return FFColor.negative
        }
    }

    private func applyValue(_ v: PlayerValue?, for p: Player, team: FantasyTeam) async {
        guard let lg = app.selectedLeague else { return }
        // On failure the picker snaps back to server state via the cache
        // refresh inside setPlayerValue; surfacing inline isn't worth the
        // wiring for what's essentially a one-tap rating control.
        try? await app.setPlayerValue(
            leagueID: lg.id, teamID: team.id, playerID: p.id, value: v
        )
    }

    // MARK: - Overview (at-a-glance + acquire actions)

    private func overviewSection(for p: Player) -> some View {
        let games = p.games
        let total = Fantasy.seasonTotals(games).points(scoring: model.scoring, settings: model.scoringSettings)
        let gp = games.count
        let ppg = gp > 0 ? total / Double(gp) : 0
        let weekly = games.map { $0.points(scoring: model.scoring, settings: model.scoringSettings) }
        return VStack(alignment: .leading, spacing: FFSpace.l) {
            if let acq = acquisition(for: p) {
                acquisitionCard(acq, player: p)
            }
            glanceCard(
                total: total, ppg: ppg, gp: gp,
                best: weekly.max() ?? 0, worst: weekly.min() ?? 0,
                trend: Fantasy.trendDirection(games: games, scoring: model.scoring, settings: model.scoringSettings)
            )
            marketCard(for: p)
            if !games.isEmpty {
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    Text("WEEKLY POINTS").ffEyebrow().padding(.leading, FFSpace.s)
                    WeeklyTrendChart(games: games, scoring: model.scoring, settings: model.scoringSettings)
                        .padding(FFSpace.m)
                        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                        .overlay(
                            RoundedRectangle(cornerRadius: FFRadius.m)
                                .strokeBorder(FFColor.border, lineWidth: 1)
                        )
                }
            }
            if !model.newsItems.isEmpty {
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    Text("NEWS").ffEyebrow().padding(.leading, FFSpace.s)
                    ForEach(model.newsItems.prefix(3)) { item in
                        NewsCard(item: item, compact: true)
                    }
                }
            }
        }
    }

    // ADP · add/drop market movement · next-4-games schedule strength.
    // All three are optional data sources — the card renders whatever is
    // available and disappears entirely when none are.
    @ViewBuilder
    private func marketCard(for p: Player) -> some View {
        let adp = model.adpByID[p.id]
        let trend = model.trendingByID[p.id]
        let sos = upcomingSOS(for: p)
        if adp != nil || trend != nil || sos != nil {
            HStack(spacing: FFSpace.l) {
                if let adp {
                    marketColumn("ADP", String(format: "%.1f", adp), FFColor.textPrimary)
                }
                if let trend {
                    let rising = trend.adds >= trend.drops
                    marketColumn(
                        rising ? "ADDS 24H" : "DROPS 24H",
                        String(format: "%.0f%%", rising ? trend.adds : trend.drops),
                        rising ? FFColor.positive : FFColor.negative
                    )
                }
                if let sos {
                    marketColumn("NEXT \(sos.games)", sos.label, sos.color)
                }
                Spacer()
            }
            .ffCard()
        }
    }

    private func marketColumn(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).ffEyebrow(color: FFColor.textTertiary)
            Text(value).font(.ffStatMedium).foregroundStyle(color)
        }
    }

    // Average DvP rank of the next few opponents at this player's position.
    // Rank 1 = allows the most fantasy points, so LOW average = soft slate.
    private func upcomingSOS(for p: Player) -> (label: String, color: Color, games: Int)? {
        guard !p.team.isEmpty else { return nil }
        let dvp = model.dvpByPosition[p.position.uppercased()] ?? [:]
        guard !dvp.isEmpty else { return nil }
        let now = Date()
        let upcoming = model.schedules
            .filter { g in (g.home == p.team || g.away == p.team) && (g.kickoff.map { $0 > now } ?? false) }
            .sorted { ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture) }
            .prefix(4)
        let ranks = upcoming.compactMap { g -> Int? in
            let opp = g.home == p.team ? g.away : g.home
            return dvp[opp]?.rank
        }
        guard !ranks.isEmpty else { return nil }
        let avg = Double(ranks.reduce(0, +)) / Double(ranks.count)
        let label: String
        let color: Color
        switch avg {
        case ..<12:  label = "Soft";  color = FFColor.positive
        case ..<21:  label = "Even";  color = FFColor.warning
        default:     label = "Tough"; color = FFColor.negative
        }
        return (label, color, ranks.count)
    }

    private func acquisitionCard(_ acq: PlayerAcquisition, player p: Player) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text(acquisitionEyebrow(acq)).ffEyebrow()
            AcquisitionButton(acquisition: acq, enabled: myLeagueTeam != nil) {
                handleAcquisition(acq, player: p)
            }
        }
        .ffCard()
    }

    private func glanceCard(total: Double, ppg: Double, gp: Int,
                            best: Double, worst: Double, trend: Trend) -> some View {
        VStack(spacing: FFSpace.m) {
            HStack(spacing: FFSpace.m) {
                glanceStat("PTS", total.fpString)
                glanceStat("PPG", ppg.fpString)
                glanceStat("GP", "\(gp)")
            }
            HStack(spacing: FFSpace.m) {
                glanceStat("BEST", best.fpString)
                glanceStat("WORST", worst.fpString)
                glanceStat("TREND", trendGlyph(trend), color: trendTint(trend))
            }
        }
        .ffCard()
    }

    private func glanceStat(_ label: String, _ value: String, color: Color = FFColor.textPrimary) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.ffStatMedium).foregroundStyle(color)
            Text(label).ffEyebrow(color: FFColor.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func trendGlyph(_ t: Trend) -> String {
        switch t { case .up: return "↑"; case .flat: return "→"; case .down: return "↓" }
    }
    private func trendTint(_ t: Trend) -> Color {
        switch t {
        case .up:   return FFColor.positive
        case .flat: return FFColor.textTertiary
        case .down: return FFColor.negative
        }
    }

    private func acquisitionEyebrow(_ acq: PlayerAcquisition) -> String {
        switch acq {
        case .addable:           return "FREE AGENT"
        case .claimable:         return "ON WAIVERS"
        case .trade(_, let name): return "ROSTERED BY \(name.uppercased())"
        case .onMyRoster:        return "ON YOUR ROSTER"
        case .unavailable:       return "AVAILABILITY"
        }
    }

    // The team the signed-in user controls in the selected league.
    private var myLeagueTeam: FantasyTeam? {
        guard let lg = app.selectedLeague else { return nil }
        if lg.isTest, let id = AppState.primaryTeamID(in: lg) {
            return lg.teams.first(where: { $0.id == id })
        }
        guard let uid = app.session?.userID else { return nil }
        return lg.teams.first(where: { $0.ownerID == uid })
    }

    private func acquisition(for p: Player) -> PlayerAcquisition? {
        guard let lg = app.selectedLeague else { return nil }
        let droppedByID = Dictionary(model.dropped.map { ($0.playerID, $0) }, uniquingKeysWith: { a, _ in a })
        let week = Fantasy.currentWeek(players: app.displaySelectedPlayers())
        return PlayerAcquisition.resolve(
            playerID: p.id, league: lg, myTeam: myLeagueTeam,
            players: app.displaySelectedPlayers(),
            droppedByID: droppedByID, week: week
        )
    }

    private func handleAcquisition(_ acq: PlayerAcquisition, player p: Player) {
        guard let team = myLeagueTeam else { return }
        let summary = Fantasy.summary(p, scoring: model.scoring)
        switch acq {
        case .addable:
            claimTarget = AddClaimTarget(team: team, addPlayer: summary, isOnWaivers: false, waiverUntil: nil)
        case .claimable(let until):
            claimTarget = AddClaimTarget(team: team, addPlayer: summary, isOnWaivers: true, waiverUntil: until)
        case .trade(let teamID, _):
            tradeTarget = AcquireTradeTarget(fromTeam: team, toTeamID: teamID, playerID: p.id)
        case .onMyRoster, .unavailable:
            break
        }
    }
}
