import SwiftUI

// Week-by-week game log with snap counts and tap-through scoring breakdowns.
// Pushed from the player profile hub.
struct PlayerGameLogPage: View {
    @Environment(AppState.self) private var app
    let player: Player
    let model: PlayerDetailModel

    @State private var breakdownGame: Game? = nil

    private var isProjected: Bool { app.isProjectedSeason(app.selectedSeason) }

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            ScrollView {
                gameLogSection(for: player)
                    .padding(.horizontal, FFSpace.l)
                    .padding(.top, FFSpace.s)
                    .padding(.bottom, 40)
            }
        }
        .navigationTitle("Game Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
        .sheet(item: $breakdownGame) { g in
            ScoreBreakdownSheet(
                playerName: player.name,
                game: g,
                scoring: model.scoring,
                settings: model.scoringSettings
            )
        }
    }

    private func gameLogSection(for p: Player) -> some View {
        let games = gameLogRows(for: p)
        return VStack(alignment: .leading, spacing: FFSpace.s) {
            Text(isProjected ? "PROJECTED GAME LOG" : "GAME LOG").ffEyebrow().padding(.leading, FFSpace.s)
            if games.isEmpty {
                Text("No games played yet.")
                    .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                    .padding(FFSpace.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            } else {
                VStack(spacing: 0) {
                    ForEach(games) { g in
                        gameRow(g, snap: model.snapCounts[p.id]?[g.week])
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

    // Game log rows, deduped to one per week and back-filled with 0-stat
    // entries for every week the player's current team has already played but
    // the player recorded nothing (DNP, inactive, healthy scratch). A bye week
    // produces no schedule row, so it's naturally skipped. Display-only — the
    // synthesized zeros never feed scoring, splits averages, or career totals.
    private func gameLogRows(for p: Player) -> [Game] {
        var byWeek: [Int: Game] = [:]
        for g in p.games {
            // Defensive de-dup: if two rows ever share a week, keep the one
            // with real production over an empty stub.
            if let existing = byWeek[g.week], existing.points(scoring: .ppr) >= g.points(scoring: .ppr) {
                continue
            }
            byWeek[g.week] = g
        }
        // player_games is regular-season only, so the latest week with any
        // stats across the league marks the REG boundary (cached in maxRegWeek).
        // Capping fills there keeps postseason schedule rows (weeks 19+) out of
        // the log and avoids inventing zeros for weeks that haven't been played.
        if !p.team.isEmpty && model.maxRegWeek > 0 {
            for sched in model.schedules {
                // `schedules` can briefly lag a season switch (it reloads in
                // .task); skip rows from any other season so we never synthesize
                // weeks/opponents from the previously selected season.
                guard sched.season == app.selectedSeason else { continue }
                guard sched.status == .final || sched.status == .inProgress else { continue }
                guard sched.week <= model.maxRegWeek else { continue }
                guard sched.home == p.team || sched.away == p.team, byWeek[sched.week] == nil else { continue }
                var stub = Game()
                stub.season = sched.season
                stub.week = sched.week
                stub.team = p.team
                stub.opponent = sched.opponent(of: p.team) ?? ""
                byWeek[sched.week] = stub
            }
        }
        return byWeek.values.sorted { $0.week < $1.week }
    }

    private func gameRow(_ g: Game, snap: SnapCount?) -> some View {
        let pts = g.points(scoring: model.scoring, settings: model.scoringSettings)
        return HStack(alignment: .top, spacing: FFSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Week \(g.week)")
                    .font(.ffBody.weight(.semibold))
                    .foregroundStyle(FFColor.textPrimary)
                Text(g.opponent.isEmpty ? " " : "vs \(g.opponent)")
                    .font(.ffCaption)
                    .foregroundStyle(FFColor.textTertiary)
                if let snap, snap.offensePct > 0 {
                    Text("\(Int(snap.offensePct))% snaps")
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if g.receivingYards > 0 || g.receptions > 0 {
                    Text("\(g.receptions.statString) rec · \(g.receivingYards.statString) yd · \(g.receivingTDs.statString) TD")
                        .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                }
                if g.rushingYards > 0 || g.carries > 0 {
                    Text("\(g.carries.statString) car · \(g.rushingYards.statString) yd · \(g.rushingTDs.statString) TD")
                        .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                }
                if g.passingYards > 0 || g.attempts > 0 {
                    Text("\(Int(g.completions))/\(Int(g.attempts)) · \(g.passingYards.statString) yd · \(g.passingTDs.statString) TD · \(g.passingInterceptions.statString) INT")
                        .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                }
                if g.targets > 0 {
                    Text("\(Int(g.targets)) tgt")
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                }
            }
            Button {
                breakdownGame = g
            } label: {
                HStack(spacing: 3) {
                    Text(pts.fpString)
                        .font(.ffStatMedium)
                        .foregroundStyle(FFColor.textPrimary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FFColor.textTertiary)
                }
                .frame(minWidth: 56, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
        .ffHairlineBottom()
    }
}

// MARK: - Score breakdown sheet

// Tapping a score in the game log opens this: a line-by-line accounting of how
// each box-score stat contributed to that week's fantasy points, under the
// scoring the game log is showing.
private struct ScoreBreakdownSheet: View {
    let playerName: String
    let game: Game
    let scoring: Scoring
    // Computed once at init — the inputs are immutable for the sheet's lifetime,
    // so there's no need to recompute on every layout pass.
    private let breakdown: (components: [Fantasy.ScoreComponent], total: Double)
    @Environment(\.dismiss) private var dismiss

    init(playerName: String, game: Game, scoring: Scoring, settings: ScoringSettings?) {
        self.playerName = playerName
        self.game = game
        self.scoring = scoring
        self.breakdown = Fantasy.scoreBreakdown(game: game, scoring: scoring, settings: settings)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FFColor.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: FFSpace.l) {
                        headerCard(total: breakdown.total)
                        if breakdown.components.isEmpty {
                            emptyCard
                        } else {
                            componentsCard(breakdown.components, total: breakdown.total)
                        }
                    }
                    .padding(FFSpace.l)
                }
            }
            .navigationTitle("Scoring Breakdown")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FFColor.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(FFColor.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func headerCard(total: Double) -> some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text(playerName.uppercased()).ffEyebrow(color: FFColor.accent)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Week \(game.week)")
                        .font(.ffTitle)
                        .foregroundStyle(FFColor.textPrimary)
                    Text(game.opponent.isEmpty ? scoring.label : "vs \(game.opponent) · \(scoring.label)")
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textTertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(total.fpString)
                        .font(.ffStatLarge)
                        .foregroundStyle(FFColor.textPrimary)
                    Text("PTS").ffEyebrow(color: FFColor.textTertiary)
                }
            }
        }
        .ffCard(padding: FFSpace.l)
    }

    private func componentsCard(_ components: [Fantasy.ScoreComponent], total: Double) -> some View {
        VStack(spacing: 0) {
            ForEach(components) { c in
                HStack(alignment: .firstTextBaseline, spacing: FFSpace.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.label)
                            .font(.ffBody)
                            .foregroundStyle(FFColor.textPrimary)
                        Text(c.detail)
                            .font(.ffMicro)
                            .foregroundStyle(FFColor.textTertiary)
                    }
                    Spacer()
                    Text(signed(c.points))
                        .font(.ffStatSmall)
                        .foregroundStyle(c.points < 0 ? FFColor.negative : FFColor.textPrimary)
                }
                .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
                .ffHairlineBottom()
            }
            HStack {
                Text("TOTAL").ffEyebrow()
                Spacer()
                Text(total.fpString)
                    .font(.ffStatMedium)
                    .foregroundStyle(FFColor.accent)
            }
            .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.m)
        }
        .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
        .overlay(
            RoundedRectangle(cornerRadius: FFRadius.m)
                .strokeBorder(FFColor.border, lineWidth: 1)
        )
    }

    private var emptyCard: some View {
        Text("No scoring stats for this game.")
            .font(.ffBody).foregroundStyle(FFColor.textSecondary)
            .padding(FFSpace.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
    }

    // Always show the sign so positive contributions read as additive.
    private func signed(_ v: Double) -> String {
        "\(v >= 0 ? "+" : "")\(v.fpString)"
    }
}
