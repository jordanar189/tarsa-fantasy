import SwiftUI

struct PlayerDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let playerID: String
    @State private var scoring: Scoring = .ppr

    private var player: Player? { app.selectedPlayers()[playerID] }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let player {
                    VStack(spacing: 16) {
                        header(player)
                        scoringPicker
                        totalsCard(for: player)
                        gameLog(for: player)
                    }
                    .padding()
                } else {
                    ContentUnavailableView(
                        "Player not found",
                        systemImage: "questionmark.circle"
                    )
                    .padding(.top, 60)
                }
            }
            .navigationTitle(player?.name ?? "Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func header(_ p: Player) -> some View {
        HStack(spacing: 14) {
            PlayerAvatar(url: p.headshotURL, fallback: p.name.initialsFromName)
                .scaleEffect(1.6)
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(p.name).font(.title3.bold())
                HStack(spacing: 6) {
                    PositionPill(position: p.position)
                    Text(p.team).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var scoringPicker: some View {
        Picker("Scoring", selection: $scoring) {
            ForEach(Scoring.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private func totalsCard(for p: Player) -> some View {
        let t = Fantasy.seasonTotals(p.games)
        let pts = t.points(scoring: scoring)
        let gp = max(t.gamesPlayed, 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Season totals", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Spacer()
                VStack(alignment: .trailing) {
                    Text(Fantasy.round2(pts).fpString)
                        .font(.title2.bold()).monospacedDigit()
                    Text("\(Fantasy.round2(pts / Double(gp)).fpString) per game")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Divider()
            statsGrid(t)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func statsGrid(_ t: SeasonTotals) -> some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            stat("GP", "\(t.gamesPlayed)")
            stat("Pass yd", t.passingYards.statString)
            stat("Pass TD", t.passingTDs.statString)
            stat("INT", t.passingInterceptions.statString)
            stat("Rush yd", t.rushingYards.statString)
            stat("Rush TD", t.rushingTDs.statString)
            stat("Rec", t.receptions.statString)
            stat("Rec yd", t.receivingYards.statString)
            stat("Rec TD", t.receivingTDs.statString)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(.subheadline, design: .rounded)).monospacedDigit().bold()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func gameLog(for p: Player) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Game log", systemImage: "list.bullet.rectangle")
                .font(.headline)
            ForEach(p.games) { game in
                gameRow(game)
            }
            if p.games.isEmpty {
                Text("No games played yet.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func gameRow(_ g: Game) -> some View {
        let pts = g.points(scoring: scoring)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Week \(g.week)").font(.subheadline.bold())
                Text(g.opponent.isEmpty ? " " : "vs \(g.opponent)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if g.receivingYards > 0 || g.receptions > 0 {
                    Text("\(g.receptions.statString) rec, \(g.receivingYards.statString) yd, \(g.receivingTDs.statString) TD")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if g.rushingYards > 0 || g.carries > 0 {
                    Text("\(g.carries.statString) car, \(g.rushingYards.statString) yd, \(g.rushingTDs.statString) TD")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if g.passingYards > 0 || g.attempts > 0 {
                    Text("\(Int(g.completions))/\(Int(g.attempts)), \(g.passingYards.statString) yd, \(g.passingTDs.statString) TD, \(g.passingInterceptions.statString) INT")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(pts.fpString)
                .font(.headline).monospacedDigit()
                .frame(minWidth: 50, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
