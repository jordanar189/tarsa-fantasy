import SwiftUI

// Full stat breakdown for the season: totals, WAR, matchup ranks, nicknames,
// weekly charts, and season highs/lows. Pushed from the player profile hub.
struct PlayerDetailsPage: View {
    @Environment(AppState.self) private var app
    let player: Player
    let model: PlayerDetailModel

    private var isProjected: Bool { app.isProjectedSeason(app.selectedSeason) }

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            ScrollView {
                detailsSection(for: player)
                    .padding(.horizontal, FFSpace.l)
                    .padding(.top, FFSpace.s)
                    .padding(.bottom, 40)
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
    }

    private func detailsSection(for p: Player) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.l) {
            totalsCard(for: p)
            if model.warByID[p.id] != nil { warCard(for: p) }
            // The matchup-ranks card lives on the hub landing now (it's
            // this-week info); the full breakdown page doesn't repeat it.
            if !model.nicknameHistory.isEmpty { nicknameHistoryCard }
            if !p.games.isEmpty {
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    Text("WEEKLY POINTS").ffEyebrow().padding(.leading, FFSpace.s)
                    WeeklyTrendChart(games: p.games, scoring: model.scoring, settings: model.scoringSettings)
                        .padding(FFSpace.m)
                        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                        .overlay(
                            RoundedRectangle(cornerRadius: FFRadius.m)
                                .strokeBorder(FFColor.border, lineWidth: 1)
                        )
                }
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    Text("WEEKLY DISTRIBUTION").ffEyebrow().padding(.leading, FFSpace.s)
                    PositionDistributionChart(games: p.games, scoring: model.scoring, settings: model.scoringSettings)
                        .padding(FFSpace.m)
                        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
                        .overlay(
                            RoundedRectangle(cornerRadius: FFRadius.m)
                                .strokeBorder(FFColor.border, lineWidth: 1)
                        )
                }
                bestWorstCard(for: p)
            }
        }
    }


    // Every nickname this player has been given by a fantasy team, active or
    // archived (dropped). Active ones are tinted; archived show when they were
    // retired so the history reads as a timeline.
    private var nicknameHistoryCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("NICKNAMES").ffEyebrow().padding(.leading, FFSpace.s)
            VStack(spacing: 0) {
                ForEach(model.nicknameHistory) { entry in
                    HStack(spacing: FFSpace.m) {
                        Image(systemName: entry.isActive ? "quote.bubble.fill" : "quote.bubble")
                            .font(.system(size: 15))
                            .foregroundStyle(entry.isActive ? FFColor.accent : FFColor.textTertiary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("“\(entry.nickname)”")
                                .font(.ffBody)
                                .foregroundStyle(entry.isActive ? FFColor.textPrimary : FFColor.textSecondary)
                                .lineLimit(1)
                            Text("\(entry.teamName) · \(entry.leagueName)")
                                .font(.ffMicro)
                                .foregroundStyle(FFColor.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if entry.isActive {
                            Text("ACTIVE").ffEyebrow(color: FFColor.accent)
                        } else if let cleared = entry.clearedAt {
                            Text("Dropped \(cleared.formatted(.dateTime.month(.abbreviated).day()))")
                                .font(.ffMicro)
                                .foregroundStyle(FFColor.textTertiary)
                        }
                    }
                    .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
                    .ffHairlineBottom()
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    // Wins Above Replacement: regular-season wins this player added over a
    // freely-available replacement starter at his position, given the league's
    // scoring and roster. Negative means a replacement would have done better.
    private func warCard(for p: Player) -> some View {
        let war = model.warByID[p.id] ?? 0
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text(isProjected ? "PROJECTED WAR" : "WINS ABOVE REPLACEMENT")
                .ffEyebrow().padding(.leading, FFSpace.s)
            HStack(alignment: .firstTextBaseline, spacing: FFSpace.m) {
                Text(String(format: "%+.1f", war))
                    .font(.ffStatLarge)
                    .foregroundStyle(war >= 0 ? FFColor.accent : FFColor.negative)
                Text("\(isProjected ? "Projected " : "")regular-season wins added vs a replaceable \(p.position.uppercased()) starter.")
                    .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(FFSpace.m)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    private func totalsCard(for p: Player) -> some View {
        let t = Fantasy.seasonTotals(p.games)
        let pts = t.points(scoring: model.scoring, settings: model.scoringSettings)
        let gp = max(t.gamesPlayed, 1)
        return VStack(alignment: .leading, spacing: FFSpace.l) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isProjected ? "PROJECTED" : "SEASON").ffEyebrow(color: isProjected ? FFColor.accent : FFColor.textTertiary)
                    Text(Fantasy.round2(pts).fpString)
                        .font(.ffStatLarge)
                        .foregroundStyle(FFColor.textPrimary)
                    Text("\(Fantasy.round2(pts / Double(gp)).fpString) per game")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                }
                Spacer()
            }
            Rectangle().fill(FFColor.border).frame(height: 1)
            if isProjected {
                Text("Projected over \(t.gamesPlayed) scheduled games · box-score detail begins Week 1")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            } else {
                statsGrid(t)
            }
        }
        .ffCard(padding: FFSpace.l)
    }

    private func statsGrid(_ t: SeasonTotals) -> some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: FFSpace.m) {
            stat("GP", "\(t.gamesPlayed)")
            stat("PASS YD", t.passingYards.statString)
            stat("PASS TD", t.passingTDs.statString)
            stat("INT", t.passingInterceptions.statString)
            stat("RUSH YD", t.rushingYards.statString)
            stat("RUSH TD", t.rushingTDs.statString)
            stat("REC", t.receptions.statString)
            stat("REC YD", t.receivingYards.statString)
            stat("REC TD", t.receivingTDs.statString)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
            Text(label).font(.ffMicro).tracking(0.6).foregroundStyle(FFColor.textTertiary)
        }
    }

    private func bestWorstCard(for p: Player) -> some View {
        let sorted = p.games.sorted { $0.points(scoring: model.scoring, settings: model.scoringSettings) > $1.points(scoring: model.scoring, settings: model.scoringSettings) }
        let best = sorted.first
        let worst = sorted.last
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("SEASON HIGHS / LOWS").ffEyebrow().padding(.leading, FFSpace.s)
            VStack(spacing: 0) {
                if let g = best { highLowRow("Best", game: g, color: FFColor.positive) }
                if let g = worst, g.id != best?.id { highLowRow("Worst", game: g, color: FFColor.negative) }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    private func highLowRow(_ label: String, game: Game, color: Color) -> some View {
        HStack {
            Text(label.uppercased()).ffEyebrow(color: color).frame(width: 60, alignment: .leading)
            Text("Week \(game.week)")
                .font(.ffBody).foregroundStyle(FFColor.textPrimary)
            Text("vs \(game.opponent)").font(.ffCaption).foregroundStyle(FFColor.textTertiary)
            Spacer()
            Text(game.points(scoring: model.scoring, settings: model.scoringSettings).fpString)
                .font(.ffStatMedium)
                .foregroundStyle(color)
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }
}
