import SwiftUI

// Head-to-head matchup view. Used by both standard leagues (the "Matchup"
// tab) and simulation leagues (the "This Week" tab — same widget, just a
// week picker that defaults to the simulated week).
//
// Shows the viewer's team versus their scheduled opponent for the selected
// week with starter-by-starter scoring lines, plus game-environment context
// for each starter (opponent NFL team, DvP rating, Vegas implied total,
// weather chip, injury / inactive badges).
struct MatchupView: View {
    @Environment(AppState.self) private var app
    let league: League
    @Binding var week: Int
    // Invoked when the viewer taps "Set lineup" — the parent owns league state
    // and presents the editor so it can refresh on save.
    var onEditLineup: ((FantasyTeam, Int) -> Void)? = nil

    @State private var dvpByPosition: [String: [String: DvPEntry]] = [:]
    @State private var schedule: [NFLGame] = []
    @State private var inactiveSet: Set<String> = []
    @State private var injuries: [String: Injury] = [:]

    // The viewer's team. In a sim every team is owned by the creator, so
    // we fall back to the canonical primary team. In a real league we look
    // up the team owned by the signed-in user.
    private var myTeam: FantasyTeam? {
        if league.isTest, let id = AppState.primaryTeamID(in: league) {
            return league.teams.first(where: { $0.id == id })
        }
        guard let uid = app.session?.userID else { return nil }
        return league.teams.first(where: { $0.ownerID == uid })
    }

    var body: some View {
        VStack(spacing: FFSpace.l) {
            weekPicker
            content
        }
        .task(id: contextKey) { await loadContext() }
    }

    private var contextKey: String { "\(league.id)-\(week)" }

    // MARK: - Week picker

    // Regular-season weeks plus any postseason weeks, so a manager can review
    // and set lineups for their playoff games too.
    private var selectableWeeks: [Int] {
        var weeks = league.schedule.map(\.week)
        if league.playoffTeams >= 2 {
            let rounds = max(1, Int(ceil(log2(Double(league.playoffTeams)))))
            for r in 0..<rounds { weeks.append(league.playoffStartWeek + r) }
        }
        return weeks
    }

    private var weekPicker: some View {
        let weeks = selectableWeeks
        return HStack {
            Text("WEEK").ffEyebrow()
            Spacer()
            Menu {
                Picker("Week", selection: $week) {
                    ForEach(weeks, id: \.self) { w in
                        Text("Week \(w)").tag(w)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Week \(week)").font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
        }
        .padding(.horizontal, FFSpace.s)
    }

    // MARK: - Content dispatch

    @ViewBuilder
    private var content: some View {
        if myTeam == nil {
            spectatorMessage
        } else if week > league.regularSeasonWeeks {
            playoffContent
        } else {
            let players = Fantasy.playersFor(league: league,
                                             snapshot: app.players(season: league.season))
            let result = Fantasy.scoreboard(league: league, players: players, week: week)
            if let id = myTeam?.id,
               let m = result.matchups.first(where: { $0.home.teamID == id || $0.away.teamID == id }) {
                matchupBody(matchup: m, myTeamID: id)
            } else if result.byes.contains(where: { $0.id == myTeam?.id }) {
                byeMessage
            } else {
                emptyMessage
            }
        }
    }

    // Playoff weeks aren't in the stored schedule — derive the viewer's game
    // from the bracket and render it like a regular matchup.
    @ViewBuilder
    private var playoffContent: some View {
        let players = Fantasy.playersFor(league: league,
                                         snapshot: app.players(season: league.season))
        let bracket = Fantasy.playoffBracket(league: league, players: players)
        if let id = myTeam?.id,
           let round = bracket.rounds.first(where: { $0.week == week }),
           let game = round.games.first(where: { $0.top.teamID == id || $0.bottom.teamID == id }) {
            let iAmTop = game.top.teamID == id
            let opp = iAmTop ? game.bottom : game.top
            if opp.placeholder == "BYE" {
                emptyState(icon: "calendar.badge.clock",
                           title: "First-round bye",
                           detail: "You're seeded into the next round — no game this week.")
                lineupButton
            } else if let m = buildPlayoffMatchup(myID: id, oppTeamID: opp.teamID, players: players) {
                VStack(spacing: FFSpace.l) {
                    Text(round.name.uppercased()).ffEyebrow(color: FFColor.accent)
                    matchupBody(matchup: m, myTeamID: id)
                }
            } else {
                emptyState(icon: "hourglass",
                           title: "\(round.name) · Week \(week)",
                           detail: "Your opponent is decided once this round's prior games finish.")
                lineupButton
            }
        } else {
            emptyState(icon: "trophy",
                       title: bracket.started ? "Season over for your team" : "Playoffs not started",
                       detail: bracket.started
                            ? "Your team isn't in the bracket this week."
                            : "The bracket begins Week \(league.playoffStartWeek).")
        }
    }

    private func buildPlayoffMatchup(myID: String, oppTeamID: String?, players: [String: Player]) -> LeagueMatchup? {
        func side(_ tid: String) -> LeagueSide? {
            guard let team = league.teams.first(where: { $0.id == tid }) else { return nil }
            let s = Fantasy.teamWeekScore(
                players: players, team: team, config: league.rosterConfig,
                week: week, scoring: league.scoring, settings: league.scoringSettings
            )
            return LeagueSide(teamID: tid, name: team.name, points: s.total, roster: s.roster)
        }
        guard let mine = side(myID) else { return nil }
        let theirs: LeagueSide
        if let oppTeamID, let s = side(oppTeamID) {
            theirs = s
        } else {
            theirs = LeagueSide(teamID: "", name: "TBD", points: 0, roster: [])
        }
        let played = mine.roster.contains { $0.played } || theirs.roster.contains { $0.played }
        return LeagueMatchup(id: "po-\(week)-\(myID)", home: mine, away: theirs, played: played)
    }

    private var spectatorMessage: some View {
        emptyState(icon: "person.crop.circle.badge.questionmark",
                   title: "You don't own a team in this league.",
                   detail: "Join a team to see your week-by-week matchups here.")
    }

    private var byeMessage: some View {
        emptyState(icon: "moon.zzz",
                   title: "Bye week",
                   detail: "Your team isn't scheduled this week.")
    }

    private var emptyMessage: some View {
        emptyState(icon: "calendar.badge.exclamationmark",
                   title: "No matchup scheduled",
                   detail: "The schedule doesn't include this week.")
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text(title)
                .font(.ffHeadline)
                .foregroundStyle(FFColor.textPrimary)
            Text(detail)
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FFSpace.xxl)
    }

    // MARK: - Matchup body

    @ViewBuilder
    private func matchupBody(matchup m: LeagueMatchup, myTeamID: String) -> some View {
        let iAmHome = (m.home.teamID == myTeamID)
        let mine    = iAmHome ? m.home : m.away
        let theirs  = iAmHome ? m.away : m.home

        VStack(spacing: FFSpace.l) {
            scoreHeader(mine: mine, theirs: theirs, played: m.played)
            lineupButton
            slotByPlot(mine: mine.roster, theirs: theirs.roster)
        }
    }

    // "Set lineup" — only the team's owner (or sim controller) can edit, and
    // only when there's an edit handler wired up.
    @ViewBuilder
    private var lineupButton: some View {
        if let onEditLineup, let team = myTeam, canEditLineup {
            Button {
                onEditLineup(team, week)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Set Week \(week) lineup")
                }
                .font(.ffHeadline)
                .foregroundStyle(FFColor.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(RoundedRectangle(cornerRadius: FFRadius.s).strokeBorder(FFColor.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // Owner of the team, or the sim's controller (every team is creator-owned).
    private var canEditLineup: Bool {
        guard let team = myTeam else { return false }
        if league.isTest { return true }
        return team.ownerID == app.session?.userID || league.creatorID == app.session?.userID
    }

    // MARK: - Score header

    private func scoreHeader(mine: LeagueSide, theirs: LeagueSide, played: Bool) -> some View {
        let diff = mine.points - theirs.points
        return VStack(spacing: FFSpace.m) {
            HStack(alignment: .center, spacing: FFSpace.l) {
                sideHeader(mine, label: "YOU", winning: diff > 0)
                Text("VS").ffEyebrow(color: FFColor.textTertiary)
                sideHeader(theirs, label: "OPP", winning: diff < 0)
            }
            if played || mine.points + theirs.points > 0 {
                let leader = diff > 0 ? mine.name : (diff < 0 ? theirs.name : "Tied")
                let mag = abs(diff)
                Text(diff == 0
                     ? "Tied — \(mine.points.fpString) all"
                     : "\(leader) leads by \(mag.fpString)")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
            }
        }
        .ffCard()
    }

    private func sideHeader(_ side: LeagueSide, label: String, winning: Bool) -> some View {
        VStack(spacing: 4) {
            Text(label).ffEyebrow(color: winning ? FFColor.accent : FFColor.textTertiary)
            Text(side.name)
                .font(.ffCaption)
                .foregroundStyle(winning ? FFColor.textPrimary : FFColor.textSecondary)
                .lineLimit(1)
            Text(side.points.fpString)
                .font(.ffStatLarge)
                .foregroundStyle(winning ? FFColor.accent : FFColor.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Slot-by-slot plot

    @ViewBuilder
    private func slotByPlot(mine: [LeagueRosterEntry], theirs: [LeagueRosterEntry]) -> some View {
        let mineStarters   = mine.filter   { $0.slot.isStarter }
        let theirsStarters = theirs.filter { $0.slot.isStarter }
        // Walk by index so unequal-length rosters still align gracefully
        // (shouldn't happen in normal play, but be defensive).
        let count = max(mineStarters.count, theirsStarters.count)

        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                slotRow(
                    mine:   i < mineStarters.count   ? mineStarters[i]   : nil,
                    theirs: i < theirsStarters.count ? theirsStarters[i] : nil,
                    slot:   slotForIndex(i, mine: mineStarters, theirs: theirsStarters)
                )
            }
        }
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    private func slotForIndex(
        _ i: Int, mine: [LeagueRosterEntry], theirs: [LeagueRosterEntry]
    ) -> LineupSlot {
        if i < mine.count   { return mine[i].slot }
        if i < theirs.count { return theirs[i].slot }
        return .bench
    }

    @ViewBuilder
    private func slotRow(
        mine: LeagueRosterEntry?, theirs: LeagueRosterEntry?, slot: LineupSlot
    ) -> some View {
        let myPts    = mine?.points   ?? 0
        let theirPts = theirs?.points ?? 0
        let myWin    = (mine != nil) && (myPts > theirPts)
        let theirWin = (theirs != nil) && (theirPts > myPts)

        HStack(alignment: .center, spacing: FFSpace.s) {
            playerSide(entry: mine, alignment: .trailing, winning: myWin)
            slotBadge(slot)
            playerSide(entry: theirs, alignment: .leading, winning: theirWin)
        }
        .padding(.horizontal, FFSpace.m)
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    private func slotBadge(_ slot: LineupSlot) -> some View {
        VStack(spacing: 2) {
            Text(slot.label)
                .font(.ffMicro.bold())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(FFColor.positionTint(slot.label).opacity(0.18), in: Capsule())
                .foregroundStyle(FFColor.positionTint(slot.label))
        }
        .frame(width: 56)
    }

    @ViewBuilder
    private func playerSide(
        entry: LeagueRosterEntry?, alignment: HorizontalAlignment, winning: Bool
    ) -> some View {
        let frameAlign: Alignment = (alignment == .leading) ? .leading : .trailing
        VStack(alignment: alignment, spacing: 4) {
            if let e = entry, !e.playerID.isEmpty {
                HStack(spacing: 4) {
                    if alignment == .leading {
                        Text(e.name)
                            .font(.ffBody)
                            .foregroundStyle(FFColor.textPrimary)
                            .lineLimit(1)
                        statusBadges(for: e)
                    } else {
                        statusBadges(for: e)
                        Text(e.name)
                            .font(.ffBody)
                            .foregroundStyle(FFColor.textPrimary)
                            .lineLimit(1)
                    }
                }
                Text(e.points.fpString)
                    .font(.ffStatMedium)
                    .foregroundStyle(winning ? FFColor.accent : (e.played ? FFColor.textPrimary : FFColor.textTertiary))
                gameContextLine(entry: e, alignment: alignment)
            } else {
                Text("Empty")
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textTertiary)
                Text("—")
                    .font(.ffStatMedium)
                    .foregroundStyle(FFColor.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlign)
    }

    @ViewBuilder
    private func statusBadges(for e: LeagueRosterEntry) -> some View {
        if inactiveSet.contains(e.playerID) {
            Text("INA")
                .font(.ffMicro.bold())
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(FFColor.negative.opacity(0.18), in: Capsule())
                .foregroundStyle(FFColor.negative)
        } else if let inj = injuries[e.playerID] {
            Text(inj.badge)
                .font(.ffMicro.bold())
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(FFColor.warning.opacity(0.18), in: Capsule())
                .foregroundStyle(FFColor.warning)
        }
    }

    @ViewBuilder
    private func gameContextLine(entry e: LeagueRosterEntry, alignment: HorizontalAlignment) -> some View {
        let team = e.team.uppercased()
        let game = schedule.first { $0.week == week && ($0.home == team || $0.away == team) }
        let opponent = game?.opponent(of: team) ?? ""
        let dvp = dvpByPosition[e.position.uppercased()]?[opponent]
        let rating = MatchupRating.from(rank: dvp?.rank)
        let implied = game?.impliedTotal(for: team)

        let frameAlign: Alignment = (alignment == .leading) ? .leading : .trailing
        HStack(spacing: 6) {
            if alignment == .trailing {
                Spacer(minLength: 0)
            }
            if opponent.isEmpty {
                Text("BYE")
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.warning)
            } else {
                Text("vs \(opponent)")
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
            }
            if rating != .unknown {
                Text(rating.label)
                    .font(.ffMicro.bold())
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(matchupColor(rating).opacity(0.18), in: Capsule())
                    .foregroundStyle(matchupColor(rating))
            }
            if let it = implied {
                Text(String(format: "Tot %.1f", it))
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
            }
            if let g = game, !g.isIndoor,
               (g.windMph ?? 0) >= 15 || (g.precipitation == "rain") || (g.precipitation == "snow") {
                Image(systemName: g.precipitation == "snow"
                      ? "snowflake"
                      : (g.precipitation == "rain" ? "cloud.rain" : "wind"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FFColor.textTertiary)
            }
            if alignment == .leading {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlign)
    }

    private func matchupColor(_ r: MatchupRating) -> Color {
        switch r {
        case .green:   return FFColor.positive
        case .yellow:  return FFColor.warning
        case .red:     return FFColor.negative
        case .unknown: return FFColor.textTertiary
        }
    }

    // MARK: - Context load

    private func loadContext() async {
        // Schedule + injuries are league-wide; reload on every week change
        // so simulation views pick up clamped state.
        schedule = await app.schedules(season: league.season)
        injuries = await app.injuries(for: league)
        inactiveSet = await app.inactives(season: league.season, week: week)
        var byPos: [String: [String: DvPEntry]] = [:]
        for pos in ["QB", "RB", "WR", "TE", "K", "DEF"] {
            byPos[pos] = await app.dvp(for: league, position: pos)
        }
        dvpByPosition = byPos
    }
}
