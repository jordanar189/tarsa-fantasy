import SwiftUI

// The league standings card: ranked rows with crests, records, playoff seeds,
// and the playoff cut line. Extracted from SimulationOverviewView so the same
// section can anchor other league surfaces (it becomes the League hub's
// landing content in the 5-tab shell).
struct StandingsSection: View {
    @Environment(AppState.self) private var app
    let league: League
    let onTapTeam: (FantasyTeam) -> Void

    var body: some View {
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
            Rectangle().fill(FFColor.negative.opacity(0.55)).frame(height: 1)
            Text("PLAYOFF CUT").font(.ffMicro.bold()).foregroundStyle(FFColor.negative)
            Rectangle().fill(FFColor.negative.opacity(0.55)).frame(height: 1)
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
                if let team { TeamCrestView(team: team, size: 26) }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(.ffBody)
                            .foregroundStyle(FFColor.textPrimary)
                            .lineLimit(1)
                        if let abbr = team?.displayAbbreviation {
                            Text(abbr)
                                .font(.ffMicro)
                                .foregroundStyle(FFColor.textTertiary)
                        }
                        if isMine {
                            Text("YOU").ffEyebrow(color: FFColor.accent)
                        }
                        if let d = row.division, league.divisionNames.indices.contains(d) {
                            Text(league.divisionNames[d].uppercased())
                                .font(.ffMicro)
                                .foregroundStyle(FFColor.textTertiary)
                        }
                    }
                    ColoredRecord(wins: row.wins, losses: row.losses, ties: row.ties)
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

    private func teamByID(_ id: String) -> FantasyTeam? {
        league.teams.first(where: { $0.id == id })
    }
}
