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
    @State private var scoreboardWeek: Int? = nil

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
            scoreboardCard
            standingsCard
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

    @ViewBuilder
    private var championBanner: some View {
        if let name = championName {
            HStack(spacing: FFSpace.m) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(FFColor.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LEAGUE CHAMPION").ffEyebrow(color: FFColor.accent)
                    Text(name).font(.ffHeadline).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                }
                Spacer()
            }
            .ffCard()
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
                column(label: "RANK",
                       value: mine.map { "#\($0.rank)" } ?? "—",
                       color: mine?.rank == 1 ? FFColor.accent : FFColor.textPrimary)
                column(label: "RECORD",
                       value: mine.map(formatRecord) ?? "—")
                column(label: "POINTS FOR",
                       value: mine.map { $0.pointsFor.fpString } ?? "—")
            }
        }
        .ffCard()
    }

    private func column(label: String, value: String, color: Color = FFColor.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).ffEyebrow(color: FFColor.textTertiary)
            Text(value).font(.ffStatMedium).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatRecord(_ r: StandingsRow) -> String {
        if r.ties > 0 { return "\(r.wins)–\(r.losses)–\(r.ties)" }
        return "\(r.wins)–\(r.losses)"
    }

    // MARK: - Scoreboard

    private var scheduleWeeks: [Int] { league.schedule.map(\.week) }

    // Default the week picker to the "current" week — the simulated week for
    // sims, or the latest week with any stat rows for standard leagues.
    // Clamp into the schedule so a paused sim or out-of-season league lands
    // on a valid entry.
    private func defaultScoreboardWeek() -> Int {
        let weeks = scheduleWeeks
        guard let first = weeks.first, let last = weeks.last else { return 1 }
        let target: Int
        if league.isTest {
            target = max(1, currentWeek)
        } else {
            target = Fantasy.currentWeek(players: app.players(season: league.season))
        }
        return min(max(target, first), last)
    }

    private var resolvedScoreboardWeek: Int {
        scoreboardWeek ?? defaultScoreboardWeek()
    }

    private var scoreboardCard: some View {
        let players = Fantasy.playersFor(league: league,
                                         snapshot: app.players(season: league.season))
        let week    = resolvedScoreboardWeek
        let result  = Fantasy.scoreboard(league: league, players: players, week: week)
        let weekBinding = Binding<Int>(
            get: { resolvedScoreboardWeek },
            set: { scoreboardWeek = $0 }
        )

        return VStack(alignment: .leading, spacing: FFSpace.m) {
            HStack {
                Text("SCOREBOARD").ffEyebrow()
                Spacer()
                if scheduleWeeks.count > 1 {
                    Menu {
                        Picker("Week", selection: weekBinding) {
                            ForEach(scheduleWeeks, id: \.self) { w in
                                Text("Week \(w)").tag(w)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Week \(week)")
                                .font(.ffCaption.bold())
                                .foregroundStyle(FFColor.textPrimary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(FFColor.textTertiary)
                        }
                    }
                } else {
                    Text("Week \(week)")
                        .font(.ffCaption.bold())
                        .foregroundStyle(FFColor.textPrimary)
                }
            }

            if result.matchups.isEmpty && result.byes.isEmpty {
                Text("No games scheduled for this week.")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
                    .padding(.vertical, FFSpace.s)
            } else {
                VStack(spacing: 0) {
                    ForEach(result.matchups) { m in
                        scoreboardRow(m)
                    }
                }
                if !result.byes.isEmpty {
                    Text("On bye")
                        .ffEyebrow(color: FFColor.textTertiary)
                        .padding(.top, FFSpace.s)
                    VStack(spacing: 0) {
                        ForEach(result.byes) { bye in
                            byeRow(bye)
                        }
                    }
                }
            }
        }
        .ffCard()
    }

    private func scoreboardRow(_ m: LeagueMatchup) -> some View {
        let leader: String? = {
            if m.home.points > m.away.points { return m.home.teamID }
            if m.away.points > m.home.points { return m.away.teamID }
            return nil
        }()
        return HStack(alignment: .center, spacing: FFSpace.s) {
            scoreboardSide(team: teamByID(m.home.teamID), name: m.home.name,
                           points: m.home.points, alignment: .leading,
                           winning: leader == m.home.teamID, played: m.played)
            Text("VS").ffEyebrow(color: FFColor.textTertiary)
            scoreboardSide(team: teamByID(m.away.teamID), name: m.away.name,
                           points: m.away.points, alignment: .trailing,
                           winning: leader == m.away.teamID, played: m.played)
        }
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    private func scoreboardSide(team: FantasyTeam?, name: String, points: Double,
                                alignment: HorizontalAlignment, winning: Bool,
                                played: Bool) -> some View {
        let frameAlign: Alignment = (alignment == .leading) ? .leading : .trailing
        return VStack(alignment: alignment, spacing: 2) {
            Button {
                if let team { onTapTeam(team) }
            } label: {
                Text(name)
                    .font(.ffBody)
                    .foregroundStyle(winning ? FFColor.textPrimary : FFColor.textSecondary)
                    .lineLimit(1)
                    .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                    .frame(maxWidth: .infinity, alignment: frameAlign)
            }
            .buttonStyle(.plain)
            .disabled(team == nil)
            Text(points.fpString)
                .font(.ffStatMedium)
                .foregroundStyle(winning ? FFColor.accent
                                 : (played ? FFColor.textPrimary : FFColor.textTertiary))
        }
        .frame(maxWidth: .infinity, alignment: frameAlign)
    }

    private func byeRow(_ bye: LeagueBye) -> some View {
        let team = teamByID(bye.id)
        return Button {
            if let team { onTapTeam(team) }
        } label: {
            HStack {
                Text(bye.name)
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textSecondary)
                Spacer()
                Text("BYE")
                    .font(.ffMicro.bold())
                    .foregroundStyle(FFColor.warning)
            }
            .padding(.vertical, FFSpace.s)
            .ffHairlineBottom()
        }
        .buttonStyle(.plain)
        .disabled(team == nil)
    }

    private func teamByID(_ id: String) -> FantasyTeam? {
        league.teams.first(where: { $0.id == id })
    }

    // MARK: - Standings

    private var standingsCard: some View {
        let players   = Fantasy.playersFor(league: league,
                                           snapshot: app.players(season: league.season))
        let standings = Fantasy.standings(league: league, players: players)
        let uid       = app.session?.userID

        return VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text("STANDINGS").ffEyebrow()
                Spacer()
                Text("Tap a team to see its roster")
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
            }
            VStack(spacing: 0) {
                ForEach(Array(standings.enumerated()), id: \.element.id) { idx, row in
                    standingsRow(row, isMine: teamByID(row.id)?.ownerID == uid)
                    // Playoff cut line: after the last seeded team.
                    if league.playoffTeams >= 2, row.playoffSeed == league.playoffTeams,
                       idx < standings.count - 1 {
                        playoffCutLine
                    }
                }
            }
            if league.playoffTeams >= 2 {
                Text("Top \(league.playoffTeams) make the playoffs" +
                     (league.hasDivisions ? " · division winners seeded first." : "."))
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
            }
        }
        .ffCard()
    }

    private var playoffCutLine: some View {
        HStack(spacing: FFSpace.s) {
            Rectangle().fill(FFColor.accent.opacity(0.5)).frame(height: 1)
            Text("PLAYOFF CUT").font(.ffMicro.bold()).foregroundStyle(FFColor.accent)
            Rectangle().fill(FFColor.accent.opacity(0.5)).frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    private func standingsRow(_ row: StandingsRow, isMine: Bool) -> some View {
        let team = teamByID(row.id)
        let inPlayoffs = row.playoffSeed != nil
        return Button {
            if let team { onTapTeam(team) }
        } label: {
            HStack(spacing: FFSpace.s) {
                Text("\(row.rank)")
                    .font(.ffStatSmall)
                    .foregroundStyle(inPlayoffs ? FFColor.accent : FFColor.textTertiary)
                    .frame(width: 24, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(.ffBody)
                            .foregroundStyle(FFColor.textPrimary)
                            .lineLimit(1)
                        if isMine {
                            Text("YOU").ffEyebrow(color: FFColor.accent)
                        }
                        if let d = row.division, league.divisionNames.indices.contains(d) {
                            Text(league.divisionNames[d].uppercased())
                                .font(.ffMicro)
                                .foregroundStyle(FFColor.textTertiary)
                        }
                    }
                    Text(formatRecord(row))
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textSecondary)
                }
                Spacer()
                if let seed = row.playoffSeed {
                    Text("#\(seed)")
                        .font(.ffMicro.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(FFColor.accent.opacity(0.18), in: Capsule())
                        .foregroundStyle(FFColor.accent)
                }
                Text(row.pointsFor.fpString)
                    .font(.ffStatSmall)
                    .foregroundStyle(FFColor.textPrimary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FFColor.textTertiary)
            }
            .padding(.vertical, FFSpace.s)
            .ffHairlineBottom()
        }
        .buttonStyle(.plain)
        .disabled(team == nil)
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
                                 position: snapshot[t.playerID]?.position)
                    }
                }
            }
        }
        .ffCard()
    }

    private func trendRow(_ t: TrendingPlayer, name: String, position: String?) -> some View {
        HStack(spacing: FFSpace.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                if let p = position, !p.isEmpty {
                    Text(p.uppercased()).ffEyebrow(color: FFColor.textTertiary)
                }
            }
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
                                      team: snapshot[inj.playerID]?.team)
                        }
                    }
                }
            }
        }
        .ffCard()
    }

    private func injuryRow(_ inj: Injury, name: String, position: String?, team: String?) -> some View {
        HStack(spacing: FFSpace.s) {
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
