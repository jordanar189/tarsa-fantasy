import SwiftUI

// Four tabs: Most Added / Most Dropped (sourced from MFL's market-wide
// topAdds/topDrops feeds, refreshed daily) + Hottest / Coldest derived
// from the last 3 weeks of cached player_games.
struct TrendingView: View {
    @Environment(AppState.self) private var app
    @Binding var selectedPlayerID: String?

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case added   = "Added"
        case dropped = "Dropped"
        case hot     = "Hottest"
        case cold    = "Coldest"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .added
    @State private var trending: [TrendingPlayer] = []
    @State private var loading: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FFSpace.l) {
                SegmentedTabPicker(items: Tab.allCases, selection: $tab) {
                    Text($0.rawValue)
                }
                content
            }
            .padding(.horizontal, FFSpace.l)
            .padding(.top, FFSpace.s)
            .padding(.bottom, 40)
        }
        .task(id: tab) {
            if tab == .added || tab == .dropped { await reload() }
        }
    }

    private func reload() async {
        loading = true; defer { loading = false }
        trending = await app.trendingPlayers()
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .added:   transactionList(filter: { $0.adds > 0 }, sort: { $0.adds > $1.adds }, label: "added")
        case .dropped: transactionList(filter: { $0.drops > 0 }, sort: { $0.drops > $1.drops }, label: "dropped")
        case .hot:     scoreList(top: true)
        case .cold:    scoreList(top: false)
        }
    }

    private func transactionList(
        filter: (TrendingPlayer) -> Bool,
        sort: (TrendingPlayer, TrendingPlayer) -> Bool,
        label: String
    ) -> some View {
        let players = app.selectedPlayers()
        let rows = trending
            .filter { filter($0) && (players[$0.playerID].map { Fantasy.isFantasyPosition($0.position) } ?? false) }
            .sorted(by: sort).prefix(40)
        return Group {
            if loading && trending.isEmpty {
                ProgressView().tint(FFColor.accent).padding(.top, FFSpace.xxl)
                    .frame(maxWidth: .infinity)
            } else if rows.isEmpty {
                emptyHint("No players \(label) recently.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, t in
                        Button {
                            selectedPlayerID = t.playerID
                        } label: {
                            trendingRow(rank: idx + 1, item: t, players: players)
                        }
                        .buttonStyle(.plain)
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

    private func trendingRow(rank: Int, item: TrendingPlayer, players: [String: Player]) -> some View {
        let player = players[item.playerID]
        return HStack(spacing: FFSpace.m) {
            Text("\(rank)")
                .font(.ffStatSmall)
                .foregroundStyle(rank <= 3 ? FFColor.accent : FFColor.textTertiary)
                .frame(width: 26, alignment: .leading)
            PlayerAvatar(url: player?.headshotURL ?? "",
                         fallback: (player?.name ?? "?").initialsFromName, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(player?.name ?? item.playerID)
                    .font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                if let player {
                    HStack(spacing: 6) {
                        PositionPill(position: player.position)
                        Text(player.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if item.adds > 0 {
                    Text("+\(formatPct(item.adds))")
                        .font(.ffStatSmall)
                        .foregroundStyle(FFColor.positive)
                }
                if item.drops > 0 {
                    Text("-\(formatPct(item.drops))")
                        .font(.ffStatSmall)
                        .foregroundStyle(FFColor.negative)
                }
            }
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    private func formatPct(_ v: Double) -> String {
        String(format: "%.1f%%", v)
    }

    // MARK: - Hottest / Coldest (client-side derived)

    private struct StreakEntry: Identifiable {
        let player: Player
        let avgRecent: Double
        let gamesRecent: Int
        var id: String { player.id }
    }

    private func scoreList(top: Bool) -> some View {
        let players = app.selectedPlayers()
        let weeks = app.availableWeeks(season: app.selectedSeason)
        let maxWeek = weeks.last ?? 0
        let lookback = 3
        let lowerWeek = max(1, maxWeek - lookback + 1)

        let entries: [StreakEntry] = players.values.compactMap { p in
            guard Fantasy.isFantasyPosition(p.position) else { return nil }
            let recent = p.games.filter { $0.week >= lowerWeek && $0.week <= maxWeek }
            guard recent.count >= 2 else { return nil }
            let avg = recent.reduce(0.0) { $0 + $1.points(scoring: .ppr) } / Double(recent.count)
            return StreakEntry(player: p, avgRecent: Fantasy.round2(avg), gamesRecent: recent.count)
        }
        let sorted = entries.sorted { top ? $0.avgRecent > $1.avgRecent : $0.avgRecent < $1.avgRecent }
        let rows = Array(sorted.prefix(40))

        return Group {
            if rows.isEmpty {
                emptyHint("Need at least one week of stats to show this list.")
            } else {
                VStack(alignment: .leading, spacing: FFSpace.s) {
                    Text("LAST \(lookback) WEEKS (W\(lowerWeek)-\(maxWeek))")
                        .ffEyebrow().padding(.leading, FFSpace.s)
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { idx, e in
                            Button { selectedPlayerID = e.player.id } label: {
                                streakRow(rank: idx + 1, entry: e, top: top)
                            }
                            .buttonStyle(.plain)
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

    private func streakRow(rank: Int, entry: StreakEntry, top: Bool) -> some View {
        let p = entry.player
        return HStack(spacing: FFSpace.m) {
            Text("\(rank)")
                .font(.ffStatSmall)
                .foregroundStyle(rank <= 3 ? FFColor.accent : FFColor.textTertiary)
                .frame(width: 26, alignment: .leading)
            PlayerAvatar(url: p.headshotURL, fallback: p.name.initialsFromName, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.ffBody).foregroundStyle(FFColor.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    PositionPill(position: p.position)
                    Text(p.team).font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                    Text("· \(entry.gamesRecent) GP").font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                }
            }
            Spacer()
            Sparkline(series: Fantasy.sparklineSeries(games: p.games, scoring: .ppr))
            Text("\(entry.avgRecent.fpString)/g")
                .font(.ffStatSmall)
                .foregroundStyle(top ? FFColor.positive : FFColor.negative)
        }
        .padding(.horizontal, FFSpace.l).padding(.vertical, FFSpace.s)
        .ffHairlineBottom()
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.ffBody)
            .foregroundStyle(FFColor.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, FFSpace.xl)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
    }
}
