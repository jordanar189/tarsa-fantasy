import SwiftUI

// Simulation Overview. The "homepage" of a simulation: where in the season
// we are, how the user's team is tracking against the field, and the
// information environment of that week — top adds, key injuries — so the
// user can decide what move to test next.
struct SimulationOverviewView: View {
    @Environment(AppState.self) private var app
    let league: League
    let onLeagueUpdate: (League) -> Void

    @State private var trending: [TrendingPlayer] = []
    @State private var injuriesAtWeek: [String: Injury] = [:]
    @State private var inactivesAtWeek: Set<String> = []
    @State private var loaded: Bool = false

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
            standingsSnapshot
            informationEnvironment
        }
        .task(id: "\(league.id)-\(currentWeek)") {
            await refreshContext()
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
