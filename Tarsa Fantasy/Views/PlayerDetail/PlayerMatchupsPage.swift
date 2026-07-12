import SwiftUI

// Per-opponent history for the selected season. Pushed from the player
// profile hub.
struct PlayerMatchupsPage: View {
    let player: Player
    let model: PlayerDetailModel

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            ScrollView {
                matchupsSection(for: player)
                    .padding(.horizontal, FFSpace.l)
                    .padding(.top, FFSpace.s)
                    .padding(.bottom, 40)
            }
        }
        .navigationTitle("Matchups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
    }

    private func matchupsSection(for p: Player) -> some View {
        // Group all games (this season only — historical seasons aren't
        // loaded yet) by opponent and compute totals.
        let groups = Dictionary(grouping: p.games, by: { $0.opponent })
            .map { opp, games -> (opp: String, gp: Int, avg: Double, best: Double) in
                let avg = games.reduce(0.0) { $0 + $1.points(scoring: model.scoring, settings: model.scoringSettings) } / Double(games.count)
                let best = games.map { $0.points(scoring: model.scoring, settings: model.scoringSettings) }.max() ?? 0
                return (opp, games.count, Fantasy.round2(avg), Fantasy.round2(best))
            }
            .sorted { $0.avg > $1.avg }
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("VS OPPONENT (this season)").ffEyebrow().padding(.leading, FFSpace.s)
            if groups.isEmpty {
                Text("No matchups yet.")
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    .padding(FFSpace.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("OPP").ffEyebrow(color: FFColor.textTertiary)
                            .frame(width: 50, alignment: .leading)
                        Spacer()
                        Text("GP").ffEyebrow(color: FFColor.textTertiary)
                            .frame(width: 40, alignment: .trailing)
                        Text("AVG").ffEyebrow(color: FFColor.textTertiary)
                            .frame(width: 60, alignment: .trailing)
                        Text("BEST").ffEyebrow(color: FFColor.textTertiary)
                            .frame(width: 60, alignment: .trailing)
                    }
                    .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
                    ForEach(groups, id: \.opp) { g in
                        HStack {
                            Text(g.opp).font(.ffBody).foregroundStyle(FFColor.textPrimary)
                                .frame(width: 50, alignment: .leading)
                            Spacer()
                            Text("\(g.gp)")
                                .font(.ffStatSmall).foregroundStyle(FFColor.textSecondary)
                                .frame(width: 40, alignment: .trailing)
                            Text(g.avg.fpString)
                                .font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
                                .frame(width: 60, alignment: .trailing)
                            Text(g.best.fpString)
                                .font(.ffStatSmall).foregroundStyle(FFColor.accent)
                                .frame(width: 60, alignment: .trailing)
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
    }
}
