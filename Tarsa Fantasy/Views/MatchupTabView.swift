import SwiftUI

// Matchup tab: your weekly head-to-head for the selected league. Score header
// with projected final + win probability + players-yet-to-play, slot-by-slot
// starter comparison with projections and game context, an expandable box score
// per player, a bench/optimal recap, and head-to-head history vs the opponent.
// Replaces the old in-league Matchup section.
struct MatchupTabView: View {
    @Environment(AppState.self) private var app

    @State private var week: Int = 1
    @State private var didInit = false
    @State private var context: WeekContext = .empty
    @State private var h2h: [HeadToHeadEntry] = []
    @State private var expanded: Set<String> = []

    private var league: League? { app.selectedLeague }
    private var myTeam: FantasyTeam? { league.flatMap { app.myTeam(in: $0) } }
    private var leaguePlayers: [String: Player] {
        guard let league else { return [:] }
        return Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
    }
    private var contextKey: String { "\(app.selectedLeagueID ?? "")-\(week)" }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                content
            }
            .navigationTitle("Matchup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .leagueSwitcher()
        }
        .onAppear { if !didInit { week = defaultWeek; didInit = true } }
        .task(id: contextKey) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if league == nil {
            Spacer()
        } else if myTeam == nil {
            spectator
        } else {
            ScrollView {
                VStack(spacing: FFSpace.l) {
                    weekPicker
                    matchupBody
                }
                .padding(.horizontal, FFSpace.l)
                .padding(.top, FFSpace.s)
                .padding(.bottom, 80)
            }
        }
    }

    private var spectator: some View {
        VStack(spacing: FFSpace.s) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 30, weight: .light)).foregroundStyle(FFColor.textTertiary)
            Text("No team in this league").font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
            Text("Claim a team to see your weekly matchup.")
                .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
            Spacer(); Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Week picker

    private var selectableWeeks: [Int] {
        guard let league else { return [1] }
        var weeks = league.schedule.map(\.week)
        if league.playoffTeams >= 2 {
            weeks.append(contentsOf: league.playoffStartWeek...league.playoffEndWeek)
        }
        return weeks.isEmpty ? [1] : weeks
    }

    private var defaultWeek: Int {
        guard let league else { return 1 }
        let weeks = selectableWeeks
        let target = league.isTest
            ? max(1, league.simulatedWeek ?? 1)
            : Fantasy.currentWeek(players: app.players(season: league.season))
        return min(max(target, weeks.first ?? 1), weeks.last ?? 1)
    }

    private var weekPicker: some View {
        HStack {
            Text("WEEK").ffEyebrow()
            Spacer()
            Menu {
                Picker("Week", selection: $week) {
                    ForEach(selectableWeeks, id: \.self) { w in Text("Week \(w)").tag(w) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Week \(week)").font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(FFColor.textTertiary)
                }
            }
        }
    }

    // MARK: - Resolve opponent

    // The two teams contesting the viewer's game this week, regular or playoff.
    private func resolveSides() -> (mine: FantasyTeam, opp: FantasyTeam?)? {
        guard let league, let mine = myTeam else { return nil }
        if week > league.regularSeasonWeeks {
            let bracket = Fantasy.playoffBracket(league: league, players: leaguePlayers)
            guard let round = bracket.rounds.first(where: { week >= $0.week && week <= $0.endWeek }),
                  let game = round.games.first(where: { $0.top.teamID == mine.id || $0.bottom.teamID == mine.id })
            else { return (mine, nil) }
            let oppID = game.top.teamID == mine.id ? game.bottom.teamID : game.top.teamID
            return (mine, oppID.flatMap { id in league.teams.first { $0.id == id } })
        } else {
            let result = Fantasy.scoreboard(league: league, players: leaguePlayers, week: week)
            guard let m = result.matchups.first(where: { $0.home.teamID == mine.id || $0.away.teamID == mine.id })
            else { return (mine, nil) }
            let oppID = m.home.teamID == mine.id ? m.away.teamID : m.home.teamID
            return (mine, league.teams.first { $0.id == oppID })
        }
    }

    // MARK: - Side model

    private struct SideModel {
        let team: FantasyTeam
        let starters: [LeagueRosterEntry]
        let bench: [LeagueRosterEntry]
        let actual: Double
        let projectedFinal: Double
        let remaining: Int   // starters not yet played (excludes byes/empty)
    }

    private func model(for team: FantasyTeam) -> SideModel {
        let league = league!
        let score = Fantasy.teamWeekScore(
            players: leaguePlayers, team: team, config: league.rosterConfig,
            week: week, scoring: league.scoring, settings: league.scoringSettings
        )
        let starters = score.roster.filter { $0.slot.isStarter }
        let bench = score.roster.filter { $0.slot == .bench }
        var projFinal = 0.0
        var remaining = 0
        for e in starters where !e.playerID.isEmpty {
            projFinal += context.liveOrProjected(e.playerID)
            if !context.hasPlayed(e.playerID), context.opponent(forTeam: e.team) != nil { remaining += 1 }
        }
        return SideModel(
            team: team, starters: starters, bench: bench,
            actual: score.total, projectedFinal: Fantasy.round2(projFinal), remaining: remaining
        )
    }

    @ViewBuilder
    private var matchupBody: some View {
        if let sides = resolveSides() {
            let mine = model(for: sides.mine)
            if let oppTeam = sides.opp {
                let opp = model(for: oppTeam)
                scoreHeader(mine: mine, opp: opp)
                comparison(mine: mine, opp: opp)
                recap(mine: mine, opp: opp)
                if !h2h.isEmpty { h2hCard(opponent: oppTeam) }
            } else {
                emptyState(icon: "hourglass", title: "Opponent pending",
                           detail: week > (league?.regularSeasonWeeks ?? 99)
                            ? "Your opponent is decided once this round's prior games finish."
                            : "No matchup scheduled this week.")
                if mine.starters.contains(where: { !$0.playerID.isEmpty }) {
                    singleSide(mine)
                }
            }
        } else {
            emptyState(icon: "calendar.badge.exclamationmark", title: "No matchup",
                       detail: "The schedule doesn't include this week.")
        }
    }

    // MARK: - Score header

    private func scoreHeader(mine: SideModel, opp: SideModel) -> some View {
        let myWin = MatchupMath.winProbability(
            myFinal: mine.projectedFinal, oppFinal: opp.projectedFinal,
            remainingStarters: mine.remaining + opp.remaining
        )
        let leadActual = mine.actual >= opp.actual
        return VStack(spacing: FFSpace.m) {
            HStack(alignment: .top, spacing: FFSpace.s) {
                teamColumn(mine, label: "YOU", winning: leadActual)
                VStack(spacing: 2) {
                    Text("VS").ffEyebrow(color: FFColor.textTertiary)
                }
                .frame(maxWidth: 40)
                teamColumn(opp, label: "OPP", winning: !leadActual && opp.actual > mine.actual)
            }
            winProbBar(myWin: myWin, myName: mine.team.shortLabel, oppName: opp.team.shortLabel)
            HStack {
                yetToPlay(mine, align: .leading)
                Spacer()
                Text("Proj \(mine.projectedFinal.fpString) – \(opp.projectedFinal.fpString)")
                    .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                Spacer()
                yetToPlay(opp, align: .trailing)
            }
        }
        .ffCard()
    }

    private func teamColumn(_ s: SideModel, label: String, winning: Bool) -> some View {
        VStack(spacing: 4) {
            Text(label).ffEyebrow(color: winning ? FFColor.accent : FFColor.textTertiary)
            TeamCrestView(team: s.team, size: 38)
            Text(s.team.shortLabel).font(.ffCaption).foregroundStyle(FFColor.textPrimary).lineLimit(1)
            Text(s.actual.fpString)
                .font(.ffStatLarge)
                .foregroundStyle(winning ? FFColor.accent : FFColor.textPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    private func winProbBar(myWin: Double, myName: String, oppName: String) -> some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(FFColor.accent)
                        .frame(width: max(0, geo.size.width * myWin))
                    Rectangle().fill(FFColor.surfaceElevated)
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            HStack {
                Text("\(Int((myWin * 100).rounded()))%").font(.ffMicro.bold()).foregroundStyle(FFColor.accent)
                Spacer()
                Text("WIN PROBABILITY").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                Spacer()
                Text("\(Int(((1 - myWin) * 100).rounded()))%").font(.ffMicro.bold()).foregroundStyle(FFColor.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func yetToPlay(_ s: SideModel, align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: 1) {
            Text("\(s.remaining) yet to play").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
        }
    }

    // MARK: - Comparison

    private func comparison(mine: SideModel, opp: SideModel) -> some View {
        let count = max(mine.starters.count, opp.starters.count)
        return VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                let m = i < mine.starters.count ? mine.starters[i] : nil
                let o = i < opp.starters.count ? opp.starters[i] : nil
                let slot = m?.slot ?? o?.slot ?? .bench
                comparisonRow(m: m, o: o, slot: slot)
            }
        }
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.border, lineWidth: 1))
    }

    @ViewBuilder
    private func comparisonRow(m: LeagueRosterEntry?, o: LeagueRosterEntry?, slot: LineupSlot) -> some View {
        let myPts = m?.points ?? 0
        let oPts = o?.points ?? 0
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: FFSpace.s) {
                playerSide(m, alignment: .leading, winning: (m != nil) && myPts > oPts)
                Text(slot.label)
                    .font(.ffMicro.bold())
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(FFColor.positionTint(slot.label).opacity(0.18), in: Capsule())
                    .foregroundStyle(FFColor.positionTint(slot.label))
                    .frame(width: 52)
                playerSide(o, alignment: .trailing, winning: (o != nil) && oPts > myPts)
            }
            .padding(.horizontal, FFSpace.m).padding(.vertical, FFSpace.s)
            if let m, expanded.contains(m.playerID), !m.playerID.isEmpty { boxScore(m.playerID) }
            if let o, expanded.contains(o.playerID), !o.playerID.isEmpty { boxScore(o.playerID) }
        }
        .ffHairlineBottom()
    }

    @ViewBuilder
    private func playerSide(_ e: LeagueRosterEntry?, alignment: HorizontalAlignment, winning: Bool) -> some View {
        let frameAlign: Alignment = alignment == .leading ? .leading : .trailing
        if let e, !e.playerID.isEmpty {
            Button {
                if expanded.contains(e.playerID) { expanded.remove(e.playerID) } else { expanded.insert(e.playerID) }
            } label: {
                HStack(spacing: FFSpace.s) {
                    if alignment == .leading {
                        PlayerAvatar(url: e.headshotURL, fallback: e.name.initialsFromName, size: 30)
                    }
                    VStack(alignment: alignment, spacing: 3) {
                        Text(displayName(e)).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                        statusAndContext(e, alignment: alignment)
                        HStack(spacing: 4) {
                            if context.actualPoints(e.playerID) != nil {
                                Text(e.points.fpString).font(.ffStatMedium)
                                    .foregroundStyle(winning ? FFColor.accent : FFColor.textPrimary)
                            } else {
                                Text(context.projectedPoints(e.playerID).map { $0.fpString } ?? "—")
                                    .font(.ffStatMedium).foregroundStyle(FFColor.accent)
                                Text("proj").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    if alignment == .trailing {
                        PlayerAvatar(url: e.headshotURL, fallback: e.name.initialsFromName, size: 30)
                    }
                }
                .frame(maxWidth: .infinity, alignment: frameAlign)
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: alignment, spacing: 3) {
                Text("Empty").font(.ffBody).foregroundStyle(FFColor.textTertiary)
                Text("—").font(.ffStatMedium).foregroundStyle(FFColor.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: frameAlign)
        }
    }

    @ViewBuilder
    private func statusAndContext(_ e: LeagueRosterEntry, alignment: HorizontalAlignment) -> some View {
        let opp = context.opponent(forTeam: e.team)
        let rating = context.rating(position: e.position, opponent: opp)
        HStack(spacing: 4) {
            if alignment == .trailing { Spacer(minLength: 0) }
            if let opp { Text("vs \(opp)").font(.ffMicro).foregroundStyle(FFColor.textTertiary) }
            else { Text("BYE").font(.ffMicro).foregroundStyle(FFColor.warning) }
            if rating != .unknown { MatchupPill(rating: rating, compact: true) }
            if context.isInactive(e.playerID) {
                badge("INA", color: FFColor.negative)
            } else if let inj = context.injury(e.playerID) {
                badge(inj.badge, color: FFColor.warning)
            }
            if alignment == .leading { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.ffMicro.bold())
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    // Inline per-player box score for the selected week.
    @ViewBuilder
    private func boxScore(_ pid: String) -> some View {
        if let g = leaguePlayers[pid]?.games.first(where: { $0.week == week }) {
            let stats = boxScoreStats(g)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(leaguePlayers[pid]?.name ?? "") · Week \(week)").ffEyebrow(color: FFColor.textTertiary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 6) {
                    ForEach(stats, id: \.0) { label, value in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(value).font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
                            Text(label).font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                        }
                    }
                }
            }
            .padding(FFSpace.m)
            .background(FFColor.surfaceElevated, in: RoundedRectangle(cornerRadius: FFRadius.s))
            .padding(.horizontal, FFSpace.m).padding(.bottom, FFSpace.s)
        } else {
            Text("No stat line yet for Week \(week).")
                .font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, FFSpace.m).padding(.bottom, FFSpace.s)
        }
    }

    private func boxScoreStats(_ g: Game) -> [(String, String)] {
        var out: [(String, String)] = []
        if g.passingYards != 0 || g.passingTDs != 0 || g.passingInterceptions != 0 {
            out.append(("PASS YD", g.passingYards.statString))
            out.append(("PASS TD", g.passingTDs.statString))
            out.append(("INT", g.passingInterceptions.statString))
        }
        if g.rushingYards != 0 || g.rushingTDs != 0 || g.carries != 0 {
            out.append(("CAR", g.carries.statString))
            out.append(("RUSH YD", g.rushingYards.statString))
            out.append(("RUSH TD", g.rushingTDs.statString))
        }
        if g.receptions != 0 || g.receivingYards != 0 || g.receivingTDs != 0 || g.targets != 0 {
            out.append(("REC", g.receptions.statString))
            out.append(("REC YD", g.receivingYards.statString))
            out.append(("REC TD", g.receivingTDs.statString))
        }
        if g.fumblesLost != 0 { out.append(("FUM LOST", g.fumblesLost.statString)) }
        if out.isEmpty { out.append(("PTS", g.points(scoring: context.scoring).fpString)) }
        return out
    }

    // MARK: - Recap (bench + optimal)

    private func recap(mine: SideModel, opp: SideModel) -> some View {
        let benchPts = Fantasy.round2(mine.bench.reduce(0) { $0 + $1.points })
        let optimal = optimalPoints(for: mine.team)
        let left = mine.actual
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("YOUR WEEK").ffEyebrow()
            HStack(spacing: FFSpace.l) {
                recapStat("STARTERS", left.fpString)
                recapStat("BENCH", benchPts.fpString)
                recapStat("OPTIMAL", optimal.fpString,
                          tint: optimal > left + 0.1 ? FFColor.warning : FFColor.positive)
            }
            if optimal > left + 0.1 {
                Text("Left \((optimal - left).fpString) on your bench.")
                    .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
            }
        }
        .ffCard()
    }

    private func recapStat(_ label: String, _ value: String, tint: Color = FFColor.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).ffEyebrow(color: FFColor.textTertiary)
            Text(value).font(.ffStatMedium).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Best possible starter points from the full roster for this (completed) week.
    private func optimalPoints(for team: FantasyTeam) -> Double {
        guard let league else { return 0 }
        let config = league.rosterConfig
        let ranked = team.roster.compactMap { pid -> (String, String, Double)? in
            guard let p = leaguePlayers[pid] else { return nil }
            let pts = context.actualPoints(pid) ?? 0
            return (pid, p.position, pts)
        }.sorted { $0.2 > $1.2 }
        var used = Set<String>()
        var total = 0.0
        let order = config.starterSlots.indices.sorted { i, j in
            let a = config.starterSlots[i], b = config.starterSlots[j]
            if a == .flex && b != .flex { return false }
            if b == .flex && a != .flex { return true }
            return i < j
        }
        for i in order {
            let slot = config.starterSlots[i]
            if let pick = ranked.first(where: { !used.contains($0.0) && slot.accepts(position: $0.1) }) {
                total += pick.2
                used.insert(pick.0)
            }
        }
        return Fantasy.round2(total)
    }

    // MARK: - Single side (opponent pending)

    private func singleSide(_ s: SideModel) -> some View {
        VStack(spacing: 0) {
            ForEach(s.starters) { e in
                HStack(spacing: FFSpace.s) {
                    Text(e.slot.label).font(.ffMicro.bold())
                        .foregroundStyle(FFColor.positionTint(e.slot.label)).frame(width: 40, alignment: .leading)
                    if !e.playerID.isEmpty {
                        PlayerAvatar(url: e.headshotURL, fallback: e.name.initialsFromName, size: 30)
                    }
                    Text(e.playerID.isEmpty ? "Empty" : displayName(e))
                        .font(.ffBody).foregroundStyle(e.playerID.isEmpty ? FFColor.textTertiary : FFColor.textPrimary)
                    Spacer()
                    Text(context.actualPoints(e.playerID) != nil ? e.points.fpString
                         : (context.projectedPoints(e.playerID).map { $0.fpString } ?? "—"))
                        .font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
                }
                .padding(.horizontal, FFSpace.m).padding(.vertical, FFSpace.s).ffHairlineBottom()
                .playerLink(e.playerID)
            }
        }
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.border, lineWidth: 1))
    }

    // MARK: - H2H history

    private func h2hCard(opponent: FantasyTeam) -> some View {
        let myWins = h2h.filter { $0.result == "W" }.count
        let losses = h2h.filter { $0.result == "L" }.count
        let ties = h2h.filter { $0.result == "T" }.count
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text("HEAD TO HEAD").ffEyebrow()
                Spacer()
                ColoredRecord(wins: myWins, losses: losses, ties: ties, font: .ffStatSmall)
            }
            VStack(spacing: 0) {
                ForEach(h2h.prefix(8)) { e in
                    HStack(spacing: FFSpace.s) {
                        Text("'\(String(e.season).suffix(2)) W\(e.week)")
                            .font(.ffMicro).foregroundStyle(FFColor.textTertiary).frame(width: 56, alignment: .leading)
                        Text(e.result)
                            .font(.ffMicro.bold())
                            .foregroundStyle(e.result == "W" ? FFColor.positive : (e.result == "L" ? FFColor.negative : FFColor.textSecondary))
                            .frame(width: 18)
                        Spacer()
                        Text("\(e.myPoints.fpString) – \(e.opponentPoints.fpString)")
                            .font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
                    }
                    .padding(.vertical, FFSpace.s).ffHairlineBottom()
                }
            }
        }
        .ffCard()
    }

    // MARK: - Bits

    private func displayName(_ e: LeagueRosterEntry) -> String {
        guard let league, let team = league.teams.first(where: { $0.roster.contains(e.playerID) }) else { return e.name }
        return app.nickname(teamID: team.id, playerID: e.playerID) ?? e.name
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(FFColor.textTertiary)
            Text(title).font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
            Text(detail).font(.ffCaption).foregroundStyle(FFColor.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, FFSpace.xl).ffCard()
    }

    // MARK: - Load

    private func reload() async {
        guard let league, let mine = myTeam else { return }
        context = await app.weekContext(league: league, week: week)
        // Head-to-head only meaningful in real leagues with distinct owners.
        if !league.isTest, let meUID = mine.ownerID,
           let sides = resolveSides(), let opp = sides.opp, let oppUID = opp.ownerID, oppUID != meUID {
            h2h = await app.headToHead(leagueID: league.id, meUserID: meUID, opponentUserID: oppUID)
        } else {
            h2h = []
        }
    }
}
