import SwiftUI

// Side-by-side stats comparison for 2-3 players. Built as a column per
// player + one column for the stat label. Stats include both season totals
// and the Phase 3 derived advanced numbers.
struct ComparePlayersView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let playerIDs: [String]

    @State private var scoring: Scoring = .ppr
    @State private var teamTargets: [String: [Int: Double]] = [:]
    @State private var teamTDs: [String: [Int: Double]] = [:]
    @State private var snapCounts: [String: [Int: SnapCount]] = [:]

    private var players: [Player] {
        playerIDs.compactMap { app.displaySelectedPlayers()[$0] }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                if players.count < 2 {
                    Text("Select at least 2 players to compare.")
                        .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                        .padding(FFSpace.xl)
                } else {
                    ScrollView {
                        VStack(spacing: FFSpace.l) {
                            headers
                            statTable
                        }
                        .padding(.horizontal, FFSpace.l)
                        .padding(.top, FFSpace.s)
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(FFColor.accent)
                }
            }
            .task {
                scoring = app.activeScoring
                await app.ensureProjectedSnapshot(season: app.selectedSeason)
                let players = app.displaySelectedPlayers()
                teamTargets = Fantasy.teamTargetsPerWeek(players: players)
                teamTDs     = Fantasy.teamTouchdownsPerWeek(players: players)
                snapCounts  = await app.snapCounts(season: app.selectedSeason)
            }
        }
        .hostsPlayerProfileSheet()
    }

    private var headers: some View {
        HStack(alignment: .top, spacing: FFSpace.s) {
            // Spacer column for the stat label.
            Color.clear.frame(width: 70)
            ForEach(players) { p in
                VStack(spacing: 6) {
                    PlayerAvatar(url: p.headshotURL, fallback: p.name.initialsFromName, size: 48)
                    Text(p.name)
                        .font(.ffCaption.bold())
                        .foregroundStyle(FFColor.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        PositionPill(position: p.position)
                        Text(p.team).font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .playerLink(p.id)
            }
        }
    }

    private var statTable: some View {
        let rows = makeRows()
        return VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { i in
                let r = rows[i]
                statRow(label: r.label, values: r.values, highlight: r.highlight)
            }
        }
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    private struct ComparisonRow {
        let label: String
        let values: [String]
        // Index of the "winning" cell to highlight, or nil if no winner
        // (e.g., qualitative rows).
        let highlight: Int?
    }

    private func makeRows() -> [ComparisonRow] {
        let totals = players.map { Fantasy.seasonTotals($0.games) }
        let pts    = totals.map { $0.points(scoring: scoring) }
        let ppg    = zip(totals, pts).map { (t, p) -> Double in
            t.gamesPlayed > 0 ? p / Double(t.gamesPlayed) : 0
        }

        // Per-player advanced derived numbers.
        let advanced: [[Fantasy.WeeklyAdvanced]] = players.map {
            Fantasy.weeklyAdvanced(
                player: $0, snapMap: snapCounts[$0.id],
                teamTargets: teamTargets, teamTouchdowns: teamTDs
            )
        }
        func avgNN(_ vals: [Double?]) -> Double {
            let nn = vals.compactMap { $0 }
            return nn.isEmpty ? 0 : nn.reduce(0, +) / Double(nn.count)
        }
        let snapAvg    = advanced.map { avgNN($0.map { $0.snapPct }) }
        let tShareAvg  = advanced.map { avgNN($0.map { $0.targetShare }) }
        let tdShareAvg = advanced.map { avgNN($0.map { $0.tdShare }) }

        return [
            ComparisonRow(label: "GP",        values: totals.map { "\($0.gamesPlayed)" },
                          highlight: maxIndex(totals.map { Double($0.gamesPlayed) })),
            ComparisonRow(label: "POINTS",    values: pts.map { Fantasy.round2($0).fpString },
                          highlight: maxIndex(pts)),
            ComparisonRow(label: "PER GAME",  values: ppg.map { Fantasy.round2($0).fpString },
                          highlight: maxIndex(ppg)),
            ComparisonRow(label: "PASS YD",   values: totals.map { $0.passingYards.statString },
                          highlight: maxIndex(totals.map { $0.passingYards })),
            ComparisonRow(label: "PASS TD",   values: totals.map { $0.passingTDs.statString },
                          highlight: maxIndex(totals.map { $0.passingTDs })),
            ComparisonRow(label: "RUSH YD",   values: totals.map { $0.rushingYards.statString },
                          highlight: maxIndex(totals.map { $0.rushingYards })),
            ComparisonRow(label: "RUSH TD",   values: totals.map { $0.rushingTDs.statString },
                          highlight: maxIndex(totals.map { $0.rushingTDs })),
            ComparisonRow(label: "REC",       values: totals.map { $0.receptions.statString },
                          highlight: maxIndex(totals.map { $0.receptions })),
            ComparisonRow(label: "REC YD",    values: totals.map { $0.receivingYards.statString },
                          highlight: maxIndex(totals.map { $0.receivingYards })),
            ComparisonRow(label: "REC TD",    values: totals.map { $0.receivingTDs.statString },
                          highlight: maxIndex(totals.map { $0.receivingTDs })),
            ComparisonRow(label: "SNAP %",    values: snapAvg.map { $0 > 0 ? "\(Int($0))%" : "—" },
                          highlight: maxIndex(snapAvg)),
            ComparisonRow(label: "TGT SHARE", values: tShareAvg.map { $0 > 0 ? "\(Int($0 * 100))%" : "—" },
                          highlight: maxIndex(tShareAvg)),
            ComparisonRow(label: "TD SHARE",  values: tdShareAvg.map { $0 > 0 ? "\(Int($0 * 100))%" : "—" },
                          highlight: maxIndex(tdShareAvg)),
        ]
    }

    private func maxIndex(_ values: [Double]) -> Int? {
        guard !values.isEmpty else { return nil }
        let m = values.max() ?? 0
        guard m > 0 else { return nil }
        return values.firstIndex(of: m)
    }

    private func statRow(label: String, values: [String], highlight: Int?) -> some View {
        HStack(spacing: FFSpace.s) {
            Text(label.uppercased())
                .font(.ffMicro).tracking(0.6)
                .foregroundStyle(FFColor.textTertiary)
                .frame(width: 70, alignment: .leading)
            ForEach(values.indices, id: \.self) { i in
                Text(values[i])
                    .font(.ffStatSmall)
                    .foregroundStyle(highlight == i ? FFColor.accent : FFColor.textPrimary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }
}

// Tiny helper used in scratch math above; safe no-op for our purposes.
private extension Array where Element == Double {
    func average() -> Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}
