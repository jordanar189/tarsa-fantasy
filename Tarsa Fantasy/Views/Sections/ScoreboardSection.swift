import SwiftUI

// The weekly scoreboard card: every matchup for a chosen week with win/loss
// tinted scores, plus byes. Owns its week-picker state (defaults to the
// current week, clamped into the schedule). Extracted from
// SimulationOverviewView so other league surfaces can reuse it — it becomes
// part of the Matchup tab in the 5-tab shell.
struct ScoreboardSection: View {
    @Environment(AppState.self) private var app
    let league: League
    let onTapTeam: (FantasyTeam) -> Void

    @State private var scoreboardWeek: Int? = nil

    private var currentWeek: Int { league.simulatedWeek ?? 0 }
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

    var body: some View {
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
                           winning: leader == m.home.teamID,
                           losing: m.played && leader != nil && leader != m.home.teamID)
            Text("VS").ffEyebrow(color: FFColor.textTertiary)
            scoreboardSide(team: teamByID(m.away.teamID), name: m.away.name,
                           points: m.away.points, alignment: .trailing,
                           winning: leader == m.away.teamID,
                           losing: m.played && leader != nil && leader != m.away.teamID)
        }
        .padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    private func scoreboardSide(team: FantasyTeam?, name: String, points: Double,
                                alignment: HorizontalAlignment, winning: Bool,
                                losing: Bool = false) -> some View {
        let frameAlign: Alignment = (alignment == .leading) ? .leading : .trailing
        let label = team?.shortLabel ?? name
        return VStack(alignment: alignment, spacing: 4) {
            Button {
                if let team { onTapTeam(team) }
            } label: {
                HStack(spacing: 6) {
                    if alignment == .leading, let team { TeamCrestView(team: team, size: 22) }
                    Text(label)
                        .font(.ffBody)
                        .foregroundStyle(FFColor.textPrimary)
                        .lineLimit(1)
                        .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
                    if alignment == .trailing, let team { TeamCrestView(team: team, size: 22) }
                }
                .frame(maxWidth: .infinity, alignment: frameAlign)
            }
            .buttonStyle(.plain)
            .disabled(team == nil)
            // Win/loss tints the score; an unplayed 0.0 stays primary (it's
            // upcoming, not deactivated) rather than greyed out.
            Text(points.fpString)
                .font(.ffStatMedium)
                .foregroundStyle(winning ? FFColor.accent
                                 : (losing ? FFColor.negative : FFColor.textPrimary))
        }
        .frame(maxWidth: .infinity, alignment: frameAlign)
    }

    private func byeRow(_ bye: LeagueBye) -> some View {
        let team = teamByID(bye.id)
        return Button {
            if let team { onTapTeam(team) }
        } label: {
            HStack(spacing: FFSpace.s) {
                if let team { TeamCrestView(team: team, size: 22) }
                Text(team?.shortLabel ?? bye.name)
                    .font(.ffBody)
                    .foregroundStyle(FFColor.textPrimary)
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
}
