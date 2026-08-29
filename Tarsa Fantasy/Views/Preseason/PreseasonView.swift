import SwiftUI
import Combine

// NFL preseason scoreboard, pushed from Game Center. Weeks are ESPN's
// preseason weeks (Hall of Fame weekend, then Preseason Weeks 1-3). Live:
// pull-to-refresh, the `preseason_updated` broadcast (debounced), and a 60 s
// poll while any game is in progress — the poll is the safety net for a
// dropped Realtime channel, and the reason a stale scoreboard can't linger.
struct PreseasonView: View {
    @Environment(AppState.self) private var app

    @State private var games: [PreseasonGame] = []
    @State private var teams: [String: NFLTeamMeta] = [:]
    @State private var preWeek: Int = 1
    @State private var loading: Bool = false
    @State private var selectedGame: PreseasonGame? = nil
    @State private var loadedSeason: Int? = nil

    private var availableWeeks: [Int] {
        Array(Set(games.map(\.preWeek))).sorted()
    }
    private var weekGames: [PreseasonGame] {
        games.filter { $0.preWeek == preWeek }
             .sorted { lhs, rhs in
                 (lhs.kickoff ?? .distantFuture) < (rhs.kickoff ?? .distantFuture)
             }
    }
    private var weekLabel: String {
        games.first(where: { $0.preWeek == preWeek })?.weekLabel ?? "Preseason"
    }

    var body: some View {
        ZStack {
            FFColor.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: FFSpace.l) {
                    weekPicker
                    if loading && games.isEmpty {
                        ProgressView().tint(FFColor.accent).padding(.top, FFSpace.xxl)
                    } else if games.isEmpty {
                        emptyState
                    } else if weekGames.isEmpty {
                        Text("No games this week.")
                            .font(.ffBody).foregroundStyle(FFColor.textSecondary)
                            .padding(.vertical, FFSpace.xl)
                    } else {
                        VStack(spacing: FFSpace.m) {
                            ForEach(weekGames) { game in
                                gameCard(game)
                            }
                        }
                    }
                }
                .padding(.horizontal, FFSpace.l)
                .padding(.top, FFSpace.s)
                .padding(.bottom, 40)
            }
            .refreshable { await reload() }
        }
        .navigationTitle("Preseason")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FFColor.bg, for: .navigationBar)
        .task(id: app.selectedSeason) {
            await reload()
            await PreseasonListener.shared.start(season: app.selectedSeason)
            await pollWhileLive()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .preseasonUpdated)
                .debounce(for: .seconds(1), scheduler: RunLoop.main)
        ) { note in
            guard note.userInfo?["season"] as? Int == app.selectedSeason else { return }
            Task { await reload() }
        }
        .sheet(item: $selectedGame) { game in
            PreseasonGameView(game: game)
        }
    }

    private func reload() async {
        loading = true; defer { loading = false }
        let season = app.selectedSeason
        async let g = app.preseasonGames(season: season)
        async let t = app.nflTeams()
        let (gamesResult, teamsResult) = await (g, t)
        games = gamesResult
        teams = Dictionary(uniqueKeysWithValues: teamsResult.map { ($0.abbr, $0) })
        // Default week only on first load / season switch (a live refresh
        // must not yank the user off the week they're browsing): the week
        // with a game in progress, else the first with a future kickoff,
        // else the last one played.
        guard loadedSeason != season else { return }
        loadedSeason = season
        let now = Date()
        if let live = gamesResult.first(where: { $0.isLive }) {
            preWeek = live.preWeek
        } else if let upcoming = gamesResult
            .filter({ ($0.kickoff ?? .distantPast) > now })
            .min(by: { ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture) }) {
            preWeek = upcoming.preWeek
        } else if let last = Array(Set(gamesResult.map(\.preWeek))).sorted().last {
            preWeek = last
        }
    }

    private func pollWhileLive() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            if games.contains(where: { $0.isLive }) { await reload() }
        }
    }

    // MARK: - Week picker

    private var weekPicker: some View {
        HStack {
            Button {
                guard let idx = availableWeeks.firstIndex(of: preWeek), idx > 0 else { return }
                withAnimation { preWeek = availableWeeks[idx - 1] }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(10)
                    .background(FFColor.surface, in: Circle())
                    .foregroundStyle(FFColor.textPrimary)
            }
            .buttonStyle(.plain)
            .disabled(availableWeeks.first.map { preWeek <= $0 } ?? true)

            Spacer()
            VStack(spacing: 2) {
                Text("PRESEASON").ffEyebrow(color: FFColor.textTertiary)
                Text(weekLabel)
                    .font(.ffHeadline)
                    .foregroundStyle(FFColor.textPrimary)
            }
            Spacer()

            Button {
                guard let idx = availableWeeks.firstIndex(of: preWeek),
                      idx < availableWeeks.count - 1 else { return }
                withAnimation { preWeek = availableWeeks[idx + 1] }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(10)
                    .background(FFColor.surface, in: Circle())
                    .foregroundStyle(FFColor.textPrimary)
            }
            .buttonStyle(.plain)
            .disabled(availableWeeks.last.map { preWeek >= $0 } ?? true)
        }
    }

    private var emptyState: some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: "sportscourt")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("No preseason schedule yet")
                .font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
            Text("Preseason games show up here once the league publishes the slate. Pull to refresh.")
                .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, FFSpace.xxl)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Game card

    private func gameCard(_ game: PreseasonGame) -> some View {
        Button {
            selectedGame = game
        } label: {
            VStack(alignment: .leading, spacing: FFSpace.s) {
                HStack(alignment: .center, spacing: FFSpace.s) {
                    sideBlock(team: game.away, score: game.awayScore,
                              isWinning: isWinning(game, side: .away), status: game.status)
                    statusColumn(game)
                    sideBlock(team: game.home, score: game.homeScore,
                              isWinning: isWinning(game, side: .home), status: game.status)
                }
                HStack(spacing: 4) {
                    Text("Box Score")
                        .font(.ffMicro).tracking(0.6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(FFColor.accent)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .ffCard()
        }
        .buttonStyle(.plain)
    }

    private enum Side { case home, away }

    private func isWinning(_ g: PreseasonGame, side: Side) -> Bool {
        guard let h = g.homeScore, let a = g.awayScore else { return false }
        switch side {
        case .home: return h > a
        case .away: return a > h
        }
    }

    private func sideBlock(team abbr: String, score: Int?, isWinning: Bool,
                           status: PreseasonGameStatus) -> some View {
        let meta = teams[abbr]
        return VStack(spacing: 4) {
            TeamLogoCircle(url: meta?.logoURL, size: 44)
            // The card tap opens the box score; the abbreviation alone links
            // to the team profile (inner gesture wins).
            Text(abbr)
                .font(.ffCaption.bold())
                .foregroundStyle(FFColor.textPrimary)
                .teamLink(abbr)
            if let s = score, status != .scheduled {
                Text("\(s)")
                    .font(.ffStatLarge)
                    .foregroundStyle(isWinning ? FFColor.accent : FFColor.textPrimary)
            } else {
                Text(meta?.fullName ?? "")
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func statusColumn(_ g: PreseasonGame) -> some View {
        VStack(spacing: 6) {
            switch g.status {
            case .scheduled:
                if let k = g.kickoff {
                    Text(k.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textTertiary)
                    Text(k.formatted(date: .omitted, time: .shortened))
                        .font(.ffCaption)
                        .foregroundStyle(FFColor.textSecondary)
                } else {
                    Text("TBD").font(.ffMicro).foregroundStyle(FFColor.textTertiary)
                }
            case .inProgress:
                Text("LIVE")
                    .font(.ffMicro.bold()).tracking(0.8)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(FFColor.live, in: Capsule())
                    .foregroundStyle(.white)
                if let detail = g.statusDetail {
                    Text(detail)
                        .font(.ffMicro)
                        .foregroundStyle(FFColor.textSecondary)
                }
            case .final:
                Text("FINAL")
                    .font(.ffMicro).tracking(0.8)
                    .foregroundStyle(FFColor.textTertiary)
            case .postponed:
                Text("PPD")
                    .font(.ffMicro).tracking(0.8)
                    .foregroundStyle(FFColor.warning)
            }
        }
    }
}
