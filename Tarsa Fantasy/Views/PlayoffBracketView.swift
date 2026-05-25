import SwiftUI

// Postseason bracket. Shows the seed list, each round's matchups (scored from
// the actual fantasy week), and crowns the champion once the final resolves.
// Stateless — everything is derived from standings + weekly scores via
// Fantasy.playoffBracket.
struct PlayoffBracketView: View {
    @Environment(AppState.self) private var app
    let league: League

    private var players: [String: Player] {
        Fantasy.playersFor(league: league, snapshot: app.players(season: league.season))
    }

    private func teamByID(_ id: String?) -> FantasyTeam? {
        guard let id else { return nil }
        return league.teams.first(where: { $0.id == id })
    }

    var body: some View {
        let bracket = Fantasy.playoffBracket(league: league, players: players)
        VStack(spacing: FFSpace.l) {
            if league.playoffTeams < 2 {
                emptyState("No playoffs configured", "Set a playoff team count in league settings.")
            } else if bracket.seeds.isEmpty {
                emptyState("Seeding pending", "Standings will seed the bracket once games are played.")
            } else {
                if let champ = bracket.championTeamName {
                    championBanner(champ)
                }
                if !bracket.started {
                    Text("Playoffs begin Week \(league.playoffStartWeek)")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.accent)
                        .frame(maxWidth: .infinity)
                }
                ForEach(bracket.rounds) { round in
                    roundCard(round)
                }
                seedsCard(bracket.seeds)
            }
        }
    }

    // MARK: - Champion

    private func championBanner(_ name: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 30))
                .foregroundStyle(FFColor.accent)
            Text("CHAMPION").ffEyebrow(color: FFColor.accent)
            Text(name)
                .font(.ffStatLarge)
                .foregroundStyle(FFColor.textPrimary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FFSpace.l)
        .background(FFColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(RoundedRectangle(cornerRadius: FFRadius.m).strokeBorder(FFColor.accent.opacity(0.4), lineWidth: 1))
    }

    // MARK: - Round

    private func roundCard(_ round: PlayoffRound) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            HStack {
                Text(round.name.uppercased()).ffEyebrow()
                Spacer()
                Text(round.weekLabel)
                    .font(.ffCaption.bold())
                    .foregroundStyle(FFColor.textTertiary)
            }
            VStack(spacing: FFSpace.s) {
                ForEach(round.games) { game in
                    gameCard(game)
                }
            }
        }
        .ffCard()
    }

    private func gameCard(_ game: PlayoffGame) -> some View {
        let decided = game.winnerTeamID != nil
        return VStack(spacing: 0) {
            sideRow(game.top,
                    isWinner: decided && game.winnerTeamID == game.top.teamID,
                    isLoser: decided && game.top.teamID != nil && game.winnerTeamID != game.top.teamID)
            Rectangle().fill(FFColor.border).frame(height: 1)
            sideRow(game.bottom,
                    isWinner: decided && game.winnerTeamID == game.bottom.teamID,
                    isLoser: decided && game.bottom.teamID != nil && game.winnerTeamID != game.bottom.teamID)
        }
        .background(FFColor.surfaceElevated, in: RoundedRectangle(cornerRadius: FFRadius.s))
        .overlay(RoundedRectangle(cornerRadius: FFRadius.s).strokeBorder(FFColor.border, lineWidth: 1))
    }

    private func sideRow(_ side: PlayoffSide, isWinner: Bool, isLoser: Bool = false) -> some View {
        let team = teamByID(side.teamID)
        return HStack(spacing: FFSpace.s) {
            if let seed = side.seed {
                Text("\(seed)")
                    .font(.ffMicro.bold())
                    .foregroundStyle(FFColor.textTertiary)
                    .frame(width: 18, alignment: .center)
            } else {
                Spacer().frame(width: 18)
            }
            if let team { TeamCrestView(team: team, size: 22) }
            Text(team?.shortLabel ?? side.teamName ?? side.placeholder ?? "TBD")
                .font(.ffBody)
                .foregroundStyle(side.teamName == nil ? FFColor.textTertiary
                                 : (isWinner ? FFColor.accent : FFColor.textPrimary))
                .lineLimit(1)
            Spacer()
            if let pts = side.points {
                Text(pts.fpString)
                    .font(.ffStatSmall)
                    .foregroundStyle(isWinner ? FFColor.accent
                                     : (isLoser ? FFColor.negative : FFColor.textSecondary))
            }
            if isWinner {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(FFColor.accent)
            }
        }
        .padding(.horizontal, FFSpace.m)
        .padding(.vertical, FFSpace.s)
    }

    // MARK: - Seeds

    private func seedsCard(_ seeds: [PlayoffSeedEntry]) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("SEEDS").ffEyebrow()
            VStack(spacing: 0) {
                ForEach(seeds) { s in
                    HStack(spacing: FFSpace.s) {
                        Text("\(s.seed)")
                            .font(.ffStatSmall)
                            .foregroundStyle(s.seed == 1 ? FFColor.accent : FFColor.textTertiary)
                            .frame(width: 24, alignment: .leading)
                        if let team = teamByID(s.teamID) { TeamCrestView(team: team, size: 24) }
                        Text(s.teamName)
                            .font(.ffBody)
                            .foregroundStyle(FFColor.textPrimary)
                            .lineLimit(1)
                        if s.isDivisionWinner {
                            Text("DIV").font(.ffMicro.bold())
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(FFColor.positive.opacity(0.18), in: Capsule())
                                .foregroundStyle(FFColor.positive)
                        }
                        Spacer()
                    }
                    .padding(.vertical, FFSpace.s)
                    .ffHairlineBottom()
                }
            }
        }
        .ffCard()
    }

    private func emptyState(_ title: String, _ detail: String) -> some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: "trophy")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text(title).font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
            Text(detail)
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FFSpace.xxl)
        .ffCard()
    }
}
