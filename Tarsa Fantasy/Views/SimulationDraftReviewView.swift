import SwiftUI

// Simulation Draft Review. Shows the user's drafted roster with the ADP
// they would have been drafted at (point-in-time, late-August snapshot of
// the simulated season) versus their actual season production. The delta
// surfaces value plays (drafted late, scored a lot) and busts (drafted
// early, scored little). The core feedback loop for strategy testing.
struct SimulationDraftReviewView: View {
    @Environment(AppState.self) private var app
    let league: League

    @State private var adpRankings: [String: Double] = [:]
    @State private var loaded: Bool = false

    private var primaryTeam: FantasyTeam? {
        guard let id = AppState.primaryTeamID(in: league) else { return nil }
        return league.teams.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: FFSpace.l) {
            headerCard
            roster
        }
        .task(id: league.id) { await loadAdp() }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("DRAFT REVIEW").ffEyebrow()
            Text("How your picks performed versus where they were valued going in.")
                .font(.ffCaption)
                .foregroundStyle(FFColor.textSecondary)
            if !loaded {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7).tint(FFColor.accent)
                    Text("Loading draft-week ADP…")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                }
            } else if adpRankings.isEmpty {
                Text("No ADP backfill for \(String(league.season)). Showing season points only.")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
            }
        }
        .ffCard()
    }

    @ViewBuilder
    private var roster: some View {
        if let team = primaryTeam {
            let snapshot = Fantasy.playersFor(league: league,
                                              snapshot: app.players(season: league.season))
            let rows = buildRows(team: team, snapshot: snapshot)
            VStack(spacing: 0) {
                ForEach(rows, id: \.playerID) { row in
                    rosterRow(row)
                }
            }
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    private struct ReviewRow {
        let playerID: String
        let name: String
        let position: String
        let team: String
        let adpRank: Double?
        let positionRank: Int?
        let totalAtPosition: Int
        let seasonPoints: Double
    }

    private func buildRows(team: FantasyTeam, snapshot: [String: Player]) -> [ReviewRow] {
        let posRanks = Fantasy.positionRanks(players: snapshot, scoring: league.scoring)
        let posTotals = Dictionary(grouping: snapshot.values, by: { $0.position.uppercased() })
            .mapValues { $0.count }
        let players = team.roster.compactMap { snapshot[$0] }
        let withRank = players.map { p -> ReviewRow in
            let pr = posRanks[p.id]
            return ReviewRow(
                playerID: p.id,
                name: p.name,
                position: p.position.uppercased(),
                team: p.team,
                adpRank: adpRankings[p.id],
                positionRank: pr?.rank,
                totalAtPosition: pr?.totalAtPosition ?? (posTotals[p.position.uppercased()] ?? 0),
                seasonPoints: Fantasy.seasonTotals(p.games).points(scoring: league.scoring)
            )
        }
        // Sort by ADP (best first); rows without ADP fall to the bottom.
        return withRank.sorted {
            switch ($0.adpRank, $1.adpRank) {
            case let (a?, b?): return a < b
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return $0.seasonPoints > $1.seasonPoints
            }
        }
    }

    private func rosterRow(_ r: ReviewRow) -> some View {
        HStack(spacing: FFSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    PositionPill(position: r.position)
                    Text(r.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                }
            }
            .playerLink(r.playerID)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let adp = r.adpRank {
                    Text("ADP \(Int(adp.rounded()))").font(.ffStatSmall).foregroundStyle(FFColor.textPrimary)
                } else {
                    Text("UDR").font(.ffStatSmall).foregroundStyle(FFColor.textTertiary)
                }
                Text(r.seasonPoints.fpString).font(.ffMicro).foregroundStyle(FFColor.textTertiary)
            }
            valueBadge(for: r)
        }
        .padding(.horizontal, FFSpace.l)
        .padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }

    // Value = position-rank within his own position group, relative to ADP.
    // Drafted ~early-round bust if positionRank far below his ADP-implied
    // expectation; sleeper if positionRank far above.
    private func valueBadge(for r: ReviewRow) -> some View {
        let (label, color) = valueClassification(for: r)
        return Text(label)
            .font(.ffMicro.bold())
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    // Rough heuristic: compare positional rank to (adp_rank / position_count).
    // Real fantasy positional ADP scales: assume 1.5 RBs per round on average.
    // We just bucket: same as expected ±2 ranks = par; better by 3+ = steal;
    // worse by 3+ = bust.
    private func valueClassification(for r: ReviewRow) -> (String, Color) {
        guard let adp = r.adpRank, let posRank = r.positionRank else {
            return ("—", FFColor.textTertiary)
        }
        // Expected positional rank ≈ adp * (positionTotalAtPos / totalDraftable).
        // Approximate totalDraftable as 200 (rough top-end of fantasy-relevant).
        let expected = max(1, Int(adp / Double(max(1, 200 / max(1, r.totalAtPosition)))))
        let diff = expected - posRank   // positive = outperformed ADP
        if diff >= 3  { return ("STEAL", FFColor.positive) }
        if diff <= -3 { return ("BUST",  FFColor.negative) }
        return ("PAR", FFColor.textSecondary)
    }

    private func loadAdp() async {
        loaded = false
        defer { loaded = true }
        adpRankings = await app.adpForSimulation(season: league.season,
                                                  scoring: league.scoring)
    }
}
