import SwiftUI

// League Overview. The "homepage" for both sims and standard leagues: where
// in the season we are, the user's team progress, a weekly scoreboard, full
// standings (tap a team name to pop up its roster), and the week's
// information environment — top adds, key injuries — so the user can decide
// what move to test next.
struct SimulationOverviewView: View {
    @Environment(AppState.self) private var app
    let league: League
    let onLeagueUpdate: (League) -> Void
    let onTapTeam: (FantasyTeam) -> Void

    @State private var trending: [TrendingPlayer] = []
    @State private var injuriesAtWeek: [String: Injury] = [:]
    @State private var inactivesAtWeek: Set<String> = []
    @State private var loaded: Bool = false
    // Cached so the (heavy) optimal-lineup math runs once per appearance/week
    // change rather than on every SwiftUI render of the team-stats card.
    @State private var teamStats: [TeamSeasonStats] = []

    private var currentWeek: Int { league.simulatedWeek ?? 0 }
    private var scheduleLen: Int { league.schedule.count }

    // Sims have a discrete season phase (preseason → week N → postseason);
    // standard leagues don't, so we suppress the chip there.
    private var phaseLabel: String? {
        guard league.isTest else { return nil }
        if currentWeek == 0 { return "PRESEASON" }
        if currentWeek > scheduleLen { return "POSTSEASON" }
        return "WEEK \(currentWeek) OF \(scheduleLen)"
    }

    // In a sim every team is owned by the creator, so we fall back to the
    // canonical primary team. In a real league we look up the team owned
    // by the signed-in user.
    private var primaryTeam: FantasyTeam? {
        if league.isTest, let id = AppState.primaryTeamID(in: league) {
            return league.teams.first(where: { $0.id == id })
        }
        guard let uid = app.session?.userID else { return nil }
        return league.teams.first(where: { $0.ownerID == uid })
    }

    var body: some View {
        VStack(spacing: FFSpace.l) {
            controlStrip
            championBanner
            standingsSnapshot
            ScoreboardSection(league: league, onTapTeam: onTapTeam)
            StandingsSection(league: league, onTapTeam: onTapTeam)
            teamStatsCard
            informationEnvironment
        }
        .task(id: "\(league.id)-\(currentWeek)") {
            await refreshContext()
        }
    }

    // Crowned champion — the frozen one once the season is completed, or the
    // live bracket winner if the final has resolved.
    private var championName: String? {
        if let name = league.championTeamName { return name }
        guard league.playoffTeams >= 2 else { return nil }
        let players = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        // Only crunch the bracket once the postseason has actually begun.
        guard Fantasy.currentWeek(players: players) >= league.playoffStartWeek else { return nil }
        return Fantasy.playoffBracket(league: league, players: players).championTeamName
    }

    // Static celebration chrome — the brand-gradient trophy, an accent
    // stripe, and a soft glow. No motion or haptics; the title was won in
    // the past, this banner just wears it.
    @ViewBuilder
    private var championBanner: some View {
        if let name = championName {
            HStack(spacing: FFSpace.m) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(FFGradient.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LEAGUE CHAMPION").ffEyebrow(color: FFColor.accent)
                    Text(name).font(.ffHeadline).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                }
                Spacer()
            }
            .ffCard()
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(FFColor.accent)
                    .frame(height: 3)
                    .padding(.horizontal, FFSpace.xxxl)
                    .padding(.top, 1)
            }
            .shadow(color: FFColor.accent.opacity(0.20), radius: 12, y: 4)
        }
    }

    // Compact week stepper + run-bots + reset accessor. Sim-only — the
    // banner has no meaning in a live standard league.
    @ViewBuilder
    private var controlStrip: some View {
        if league.isTest {
            SimulationBanner(league: league, onLeagueUpdate: onLeagueUpdate)
        }
    }

    private var standingsSnapshot: some View {
        let players = Fantasy.playersFor(league: league,
                                         snapshot: app.players(season: league.season))
        let standings = Fantasy.standings(league: league, players: players)
        let mine = primaryTeam.flatMap { team in standings.first(where: { $0.id == team.id }) }

        return VStack(alignment: .leading, spacing: FFSpace.m) {
            HStack {
                Text("YOUR PROGRESS").ffEyebrow()
                Spacer()
                if let phaseLabel {
                    Text(phaseLabel)
                        .font(.ffMicro).tracking(0.8)
                        .foregroundStyle(FFColor.accent)
                }
            }
            HStack(alignment: .top, spacing: FFSpace.xl) {
                // Rank is the card's anchor stat; record and points step down.
                column(label: "RANK",
                       value: mine.map { "#\($0.rank)" } ?? "—",
                       color: mine?.rank == 1 ? FFColor.accent : FFColor.textPrimary,
                       font: .ffStatLarge)
                column(label: "RECORD") {
                    if let mine {
                        ColoredRecord(wins: mine.wins, losses: mine.losses,
                                      ties: mine.ties, font: .ffStatMedium)
                    } else {
                        Text("—").font(.ffStatMedium).foregroundStyle(FFColor.textPrimary)
                    }
                }
                column(label: "POINTS FOR",
                       value: mine.map { $0.pointsFor.fpString } ?? "—")
            }
        }
        // The hub's one hero surface — everything below stays ffCard.
        .ffHeroCard()
    }

    private func column(label: String, value: String,
                        color: Color = FFColor.textPrimary,
                        font: Font = .ffStatMedium) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).ffEyebrow(color: FFColor.textTertiary)
            Text(value).font(font).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func column<Content: View>(label: String,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).ffEyebrow(color: FFColor.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func teamByID(_ id: String) -> FantasyTeam? {
        league.teams.first(where: { $0.id == id })
    }

    // MARK: - Team stats

    // Advanced per-team season stats: PF/PA, Max PF (best possible lineup),
    // Max PF % (efficiency), PPG, best/worst week, and a schedule-independent
    // all-play record. Scrolls horizontally so the full column set fits on phone.
    private var teamStatsCard: some View {
        let stats = teamStats
        let uid = app.session?.userID
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("TEAM STATS").ffEyebrow()
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    statsHeaderRow
                    ForEach(stats) { s in
                        teamStatsRow(s, isMine: teamByID(s.id)?.ownerID == uid)
                    }
                }
            }
            Text("Max PF = best possible lineup each week. Max PF % = scoring efficiency. "
                 + "All-play = record vs. every team each week (luck-neutral).")
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)
        }
        .ffCard()
    }

    // Column widths shared by the header and data rows so they line up.
    private static let statCols: [(title: String, width: CGFloat)] = [
        ("PF", 58), ("PA", 58), ("MAX PF", 64), ("MAX %", 56),
        ("PPG", 56), ("HI", 52), ("LO", 52), ("ALL-PLAY", 72)
    ]
    private static let teamColWidth: CGFloat = 128

    private var statsHeaderRow: some View {
        HStack(spacing: 0) {
            Text("TEAM").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                .frame(width: Self.teamColWidth, alignment: .leading)
            ForEach(Self.statCols.indices, id: \.self) { i in
                Text(Self.statCols[i].title)
                    .font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                    .frame(width: Self.statCols[i].width, alignment: .trailing)
            }
        }
        .padding(.vertical, 6)
        .ffHairlineBottom()
    }

    private func teamStatsRow(_ s: TeamSeasonStats, isMine: Bool) -> some View {
        let team = teamByID(s.id)
        let cells = [
            s.pointsFor.fpString,
            s.pointsAgainst.fpString,
            s.maxPointsFor.fpString,
            String(format: "%.0f%%", s.efficiency * 100),
            s.pointsPerGame.fpString,
            s.high.fpString,
            s.low.fpString,
            s.allPlayRecord
        ]
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                if let team { TeamCrestView(team: team, size: 22) }
                Text(team?.displayAbbreviation ?? s.name)
                    .font(.ffBody)
                    .foregroundStyle(isMine ? FFColor.accent : FFColor.textPrimary)
                    .lineLimit(1)
            }
            .frame(width: Self.teamColWidth, alignment: .leading)
            ForEach(cells.indices, id: \.self) { i in
                Text(cells[i])
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textPrimary)
                    .frame(width: Self.statCols[i].width, alignment: .trailing)
            }
        }
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    // What the league was talking about *at this week*. Empty during a
    // sim's preseason; in a standard league we always have live data, so
    // show it as soon as the page opens.
    @ViewBuilder
    private var informationEnvironment: some View {
        if !league.isTest || currentWeek > 0 {
            VStack(spacing: FFSpace.l) {
                trendingCard
                injuryCard
            }
        }
    }

    private var trendingCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text("TOP ADDS THIS WEEK").ffEyebrow()
                Spacer()
                if !loaded {
                    ProgressView().scaleEffect(0.6).tint(FFColor.accent)
                }
            }
            if trending.isEmpty {
                Text("No backfilled trending data for this week.")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            } else {
                let top = Array(trending.sorted(by: { $0.adds > $1.adds }).prefix(5))
                let snapshot = app.players(season: league.season)
                VStack(spacing: 0) {
                    ForEach(top, id: \.playerID) { t in
                        trendRow(t, name: snapshot[t.playerID]?.name ?? t.playerID,
                                 position: snapshot[t.playerID]?.position,
                                 headshotURL: snapshot[t.playerID]?.headshotURL ?? "")
                    }
                }
            }
        }
        .ffCard()
    }

    private func trendRow(_ t: TrendingPlayer, name: String, position: String?, headshotURL: String) -> some View {
        HStack(spacing: FFSpace.s) {
            PlayerAvatar(url: headshotURL, fallback: name.initialsFromName, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                if let p = position, !p.isEmpty {
                    Text(p.uppercased()).ffEyebrow(color: FFColor.textTertiary)
                }
            }
            .playerLink(t.playerID)
            Spacer()
            Text(String(format: "+%.0f%%", t.adds))
                .font(.ffStatSmall)
                .foregroundStyle(FFColor.positive)
        }
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    private var injuryCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("KEY INJURIES THIS WEEK").ffEyebrow()
            if injuriesAtWeek.isEmpty {
                Text("No injuries logged for this week.")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            } else {
                let snapshot = app.players(season: league.season)
                let serious = injuriesAtWeek.values.filter { sev($0.status) >= 2 }
                let sorted = serious.sorted { sev($0.status) > sev($1.status) }
                let top = Array(sorted.prefix(6))
                if top.isEmpty {
                    Text("Mostly questionable tags — nothing season-ending.")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(top, id: \.playerID) { inj in
                            injuryRow(inj, name: snapshot[inj.playerID]?.name ?? inj.playerID,
                                      position: snapshot[inj.playerID]?.position,
                                      team: snapshot[inj.playerID]?.team,
                                      headshotURL: snapshot[inj.playerID]?.headshotURL ?? "")
                        }
                    }
                }
            }
        }
        .ffCard()
    }

    private func injuryRow(_ inj: Injury, name: String, position: String?, team: String?, headshotURL: String) -> some View {
        HStack(spacing: FFSpace.s) {
            PlayerAvatar(url: headshotURL, fallback: name.initialsFromName, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                HStack(spacing: 4) {
                    if let p = position, !p.isEmpty {
                        Text(p.uppercased()).ffEyebrow(color: FFColor.textTertiary)
                    }
                    if let t = team, !t.isEmpty {
                        Text(t.uppercased())
                            .font(.ffMicro)
                            .foregroundStyle(FFColor.textTertiary)
                    }
                }
            }
            .playerLink(inj.playerID)
            Spacer()
            Text(inj.badge)
                .font(.ffMicro.bold())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(badgeColor(for: inj.status), in: Capsule())
                .foregroundStyle(FFColor.bg)
        }
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    private func badgeColor(for status: String) -> Color {
        switch sev(status) {
        case 3: return FFColor.negative
        case 2: return FFColor.warning
        default: return FFColor.textTertiary
        }
    }

    // Severity: 3 = out/IR/season, 2 = doubtful, 1 = questionable, 0 = other.
    private func sev(_ s: String) -> Int {
        switch s.uppercased() {
        case "OUT", "IR", "INJURED RESERVE", "PUP", "SUSPENDED": return 3
        case "DOUBTFUL": return 2
        case "QUESTIONABLE": return 1
        default: return 0
        }
    }

    private func refreshContext() async {
        loaded = false
        defer { loaded = true }
        // Compute the team-stats table once here (it runs optimalWeekPoints over
        // every team-week) instead of inline in the card's body on each render.
        let statsPlayers = Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
        self.teamStats = Fantasy.teamSeasonStats(league: league, players: statsPlayers)
        if league.isTest && currentWeek == 0 {
            trending = []
            injuriesAtWeek = [:]
            inactivesAtWeek = []
            return
        }
        async let tr = app.trendingPlayers(for: league)
        async let inj = app.injuries(for: league)
        self.trending        = await tr
        self.injuriesAtWeek  = await inj
        // Standard leagues have no simulated week — inactives are
        // week-scoped and don't apply, so skip the fetch.
        if currentWeek > 0 {
            self.inactivesAtWeek = await app.inactives(season: league.season, week: currentWeek)
        } else {
            self.inactivesAtWeek = []
        }
    }
}
