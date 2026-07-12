import SwiftUI

// Year-by-year breakdown across every season we have data for: a career
// aggregate up top, then a card per season with that year's fantasy
// position rank and position-relevant counting stats. Loaded lazily the
// first time the page is opened (it touches every season's snapshot).
// Pushed from the player profile hub.
struct PlayerCareerPage: View {
    @Environment(AppState.self) private var app
    let player: Player
    let model: PlayerDetailModel

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            ScrollView {
                careerSection(for: player)
                    .padding(.horizontal, FFSpace.l)
                    .padding(.top, FFSpace.s)
                    .padding(.bottom, 40)
            }
        }
        .navigationTitle("Career")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
        .task(id: player.id) {
            await model.loadCareerIfNeeded(app: app, player: player)
        }
        // A scoring change (or a hub reload) invalidates the loaded career by
        // clearing this key — reload immediately while the page is visible.
        .onChange(of: model.careerLoadedPlayerID) { _, new in
            if new == nil {
                Task { await model.loadCareer(app: app, player: player) }
            }
        }
    }

    @ViewBuilder
    private func careerSection(for p: Player) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.l) {
            if model.careerLoading && model.careerSeasons.isEmpty {
                careerMessageCard {
                    HStack(spacing: FFSpace.s) {
                        ProgressView().tint(FFColor.accent)
                        Text("Loading career…")
                            .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    }
                }
            } else if model.careerSeasons.isEmpty {
                careerMessageCard {
                    Text("No career stats available.")
                        .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                }
            } else {
                careerSummaryCard(for: p)
                Text("BY SEASON").ffEyebrow().padding(.leading, FFSpace.s)
                ForEach(model.careerSeasons) { line in
                    careerSeasonCard(line)
                }
            }
        }
    }

    private func careerMessageCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(FFSpace.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
    }

    private func careerSummaryCard(for p: Player) -> some View {
        let totalGP  = model.careerSeasons.reduce(0) { $0 + $1.gamesPlayed }
        let agg = Fantasy.combinedTotals(model.careerSeasons.map(\.totals))
        // Derive from the exact aggregate, not the per-season rounded points,
        // so the header matches the stat grid over a long career.
        let totalPts = Fantasy.round2(agg.points(scoring: model.scoring, settings: model.scoringSettings))
        let ppg = totalGP > 0 ? Fantasy.round2(totalPts / Double(totalGP)) : 0
        let bestLine = model.careerSeasons
            .filter { $0.positionRank != nil }
            .min { $0.positionRank!.rank < $1.positionRank!.rank }
        let stats = careerStatLine(position: p.position, totals: agg)
        return VStack(alignment: .leading, spacing: FFSpace.l) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CAREER").ffEyebrow(color: FFColor.accent)
                    Text(totalPts.fpString)
                        .font(.ffStatLarge)
                        .foregroundStyle(FFColor.textPrimary)
                    Text("\(model.careerSeasons.count) seasons · \(totalGP) games · \(ppg.fpString)/g")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                }
                Spacer()
                if let bestLine, let rank = bestLine.positionRank {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("BEST FINISH").ffEyebrow(color: FFColor.textTertiary)
                        Text(rank.label)
                            .font(.ffStatMedium)
                            .foregroundStyle(FFColor.accent)
                        Text(String(bestLine.season))
                            .font(.ffMicro)
                            .foregroundStyle(FFColor.textTertiary)
                    }
                }
            }
            if !stats.isEmpty {
                Rectangle().fill(FFColor.border).frame(height: 1)
                let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, alignment: .leading, spacing: FFSpace.m) {
                    ForEach(stats, id: \.0) { s in stat(s.0, s.1) }
                }
            }
        }
        .ffCard(padding: FFSpace.l)
    }

    private func careerSeasonCard(_ line: Fantasy.CareerSeasonLine) -> some View {
        let stats = careerStatLine(position: line.position, totals: line.totals)
        return VStack(alignment: .leading, spacing: FFSpace.m) {
            HStack(alignment: .firstTextBaseline, spacing: FFSpace.s) {
                Text(String(line.season))
                    .font(.ffStatMedium)
                    .foregroundStyle(FFColor.textPrimary)
                Text(line.teamLabel)
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textSecondary)
                Spacer()
                if let rank = line.positionRank { careerRankPill(rank) }
            }
            if !stats.isEmpty {
                let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                LazyVGrid(columns: cols, alignment: .leading, spacing: FFSpace.s) {
                    ForEach(stats, id: \.0) { s in stat(s.0, s.1) }
                }
            }
            Rectangle().fill(FFColor.border).frame(height: 1)
            HStack(spacing: FFSpace.l) {
                stat("PTS", line.points.fpString)
                stat("PPG", line.pointsPerGame.fpString)
                stat("GP", "\(line.gamesPlayed)")
                Spacer()
            }
        }
        .ffCard(padding: FFSpace.l)
    }

    private func careerRankPill(_ rank: PositionRank) -> some View {
        let color = careerRankColor(rank.rank)
        return HStack(spacing: 4) {
            Text(rank.label)
                .font(.ffCaption.bold())
                .padding(.horizontal, FFSpace.s).padding(.vertical, 3)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
            Text("of \(rank.totalAtPosition)")
                .font(.ffMicro)
                .foregroundStyle(FFColor.textTertiary)
        }
    }

    private func careerRankColor(_ r: Int) -> Color {
        switch r {
        case ...5:  return FFColor.positive
        case ...12: return FFColor.accent
        case ...24: return FFColor.warning
        default:    return FFColor.textSecondary
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
            Text(label).font(.ffMicro).tracking(0.6).foregroundStyle(FFColor.textTertiary)
        }
    }

    // Position-relevant counting totals for a career row. K (and anything we
    // don't carry box-score stats for) shows points only.
    private func careerStatLine(position: String, totals t: SeasonTotals) -> [(String, String)] {
        switch position.uppercased() {
        case "QB":
            return [
                ("PASS YD", t.passingYards.statString),
                ("PASS TD", t.passingTDs.statString),
                ("INT",     t.passingInterceptions.statString),
                ("RUSH YD", t.rushingYards.statString),
                ("RUSH TD", t.rushingTDs.statString),
                ("CMP",     t.completions.statString),
            ]
        case "RB":
            return [
                ("RUSH YD", t.rushingYards.statString),
                ("RUSH TD", t.rushingTDs.statString),
                ("CAR",     t.carries.statString),
                ("REC",     t.receptions.statString),
                ("REC YD",  t.receivingYards.statString),
                ("REC TD",  t.receivingTDs.statString),
            ]
        case "WR", "TE":
            return [
                ("REC",     t.receptions.statString),
                ("TGT",     t.targets.statString),
                ("REC YD",  t.receivingYards.statString),
                ("REC TD",  t.receivingTDs.statString),
            ] + (t.carries > 0 ? [
                ("RUSH YD", t.rushingYards.statString),
                ("RUSH TD", t.rushingTDs.statString),
            ] : [])
        default:
            return []
        }
    }
}
