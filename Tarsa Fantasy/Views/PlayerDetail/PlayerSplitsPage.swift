import SwiftUI

// Home/away and monthly scoring splits. Pushed from the player profile hub.
struct PlayerSplitsPage: View {
    @Environment(AppState.self) private var app
    let player: Player
    let model: PlayerDetailModel

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            ScrollView {
                splitsSection(for: player)
                    .padding(.horizontal, FFSpace.l)
                    .padding(.top, FFSpace.s)
                    .padding(.bottom, 40)
            }
        }
        .navigationTitle("Splits")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
    }

    private func splitsSection(for p: Player) -> some View {
        // Home/away derived from the schedule rows for this season.
        let schedByGameTeams = Dictionary(uniqueKeysWithValues:
            model.schedules.map { ("\($0.season)-\($0.week)-\($0.home)-\($0.away)", $0) })
        var home: [Game] = []
        var away: [Game] = []
        for g in p.games {
            // Try both team orderings since we only know p's team + opponent.
            let kHome = "\(g.season)-\(g.week)-\(g.team)-\(g.opponent)"
            let kAway = "\(g.season)-\(g.week)-\(g.opponent)-\(g.team)"
            if schedByGameTeams[kHome] != nil { home.append(g) }
            else if schedByGameTeams[kAway] != nil { away.append(g) }
        }
        // If schedule isn't loaded yet, fall back to "all in one bucket".
        let homeAvg = avgPoints(home)
        let awayAvg = avgPoints(away)
        let allAvg  = avgPoints(p.games)

        return VStack(alignment: .leading, spacing: FFSpace.l) {
            splitCard(title: "HOME / AWAY", rows: [
                ("Home", home.count, homeAvg),
                ("Away", away.count, awayAvg),
                ("Combined", p.games.count, allAvg),
            ])
            // Monthly buckets — weeks 1-4 ≈ Sep, 5-8 ≈ Oct, 9-12 ≈ Nov, 13-18 ≈ Dec/Jan.
            let buckets: [(String, ClosedRange<Int>)] = [
                ("Sep (W1-4)",   1...4),
                ("Oct (W5-8)",   5...8),
                ("Nov (W9-12)",  9...12),
                ("Dec+ (W13+)", 13...22),
            ]
            let monthly = buckets.map { label, range -> (String, Int, Double) in
                let g = p.games.filter { range.contains($0.week) }
                return (label, g.count, avgPoints(g))
            }
            splitCard(title: "MONTHLY", rows: monthly)
        }
    }

    private func avgPoints(_ games: [Game]) -> Double {
        guard !games.isEmpty else { return 0 }
        let total = games.reduce(0.0) { $0 + $1.points(scoring: model.scoring, settings: model.scoringSettings) }
        return Fantasy.round2(total / Double(games.count))
    }

    private func splitCard(title: String, rows: [(String, Int, Double)]) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text(title).ffEyebrow().padding(.leading, FFSpace.s)
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    let (label, gp, avg) = rows[i]
                    HStack {
                        Text(label).font(.ffBody).foregroundStyle(FFColor.textPrimary)
                        Spacer()
                        Text("\(gp) GP")
                            .font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                            .frame(width: 60, alignment: .trailing)
                        Text("\(avg.fpString)/g")
                            .font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
                            .frame(width: 80, alignment: .trailing)
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
