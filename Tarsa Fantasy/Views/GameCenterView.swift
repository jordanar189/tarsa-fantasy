import SwiftUI
import Combine

// Week-by-week NFL scoreboard. Lists every game for the picked week as a
// card showing home/away matchup, kickoff or final score, and (when
// expanded) the top fantasy performers on each side derived from the
// season's cached player data. Live: pull-to-refresh, plus a debounced
// reload on the Realtime live-scores signal (sync_espn_live mirrors
// score/status onto nfl_schedules in the same per-minute run).
struct GameCenterView: View {
    @Environment(AppState.self) private var app

    @State private var games: [NFLGame] = []
    @State private var teams: [String: NFLTeamMeta] = [:]
    @State private var week: Int = 1
    @State private var loading: Bool = false
    @State private var selectedGame: NFLGame? = nil
    @State private var loadedSeason: Int? = nil

    private var availableWeeks: [Int] {
        Array(Set(games.map(\.week))).sorted()
    }
    private var weekGames: [NFLGame] {
        games.filter { $0.week == week }
             .sorted { lhs, rhs in
                 (lhs.kickoff ?? .distantFuture) < (rhs.kickoff ?? .distantFuture)
             }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: FFSpace.l) {
                weekPicker
                if loading && games.isEmpty {
                    ProgressView().tint(FFColor.accent).padding(.top, FFSpace.xxl)
                } else if games.isEmpty {
                    emptyState
                } else if weekGames.isEmpty {
                    Text("No games scheduled for week \(week).")
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
            .padding(.bottom, 40)
        }
        .refreshable { await reload(force: true) }
        .task(id: app.selectedSeason) { await reload() }
        .onReceive(
            NotificationCenter.default.publisher(for: .liveScoresUpdated)
                .debounce(for: .seconds(2), scheduler: RunLoop.main)
        ) { note in
            guard note.userInfo?["season"] as? Int == app.selectedSeason else { return }
            Task { await reload(force: true) }
        }
        .sheet(item: $selectedGame) { game in
            GameDetailView(game: game) { playerID in
                // Close the game detail, then open the player profile globally.
                selectedGame = nil
                app.showPlayer(playerID)
            }
        }
    }

    private func reload(force: Bool = false) async {
        loading = true; defer { loading = false }
        let season = app.selectedSeason
        async let g = app.schedules(season: season, forceRefresh: force)
        async let t = app.nflTeams()
        let (gamesResult, teamsResult) = await (g, t)
        games = gamesResult
        teams = Dictionary(uniqueKeysWithValues: teamsResult.map { ($0.abbr, $0) })
        // Default week — first one with any game whose kickoff is in the
        // future, otherwise the latest week with games — but only on first
        // load / season switch: a live refresh must not yank the user off
        // the week they're browsing.
        guard loadedSeason != season else { return }
        loadedSeason = season
        let now = Date()
        let upcoming = gamesResult
            .filter { ($0.kickoff ?? .distantPast) > now }
            .min(by: { ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture) })
        let weeks = Array(Set(gamesResult.map(\.week))).sorted()
        if let upcoming { week = upcoming.week }
        else if let last = weeks.last { week = last }
    }

    // MARK: - Week picker

    private var weekPicker: some View {
        HStack {
            Button {
                guard let idx = availableWeeks.firstIndex(of: week), idx > 0 else { return }
                withAnimation { week = availableWeeks[idx - 1] }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(10)
                    .background(FFColor.surface, in: Circle())
                    .foregroundStyle(FFColor.textPrimary)
            }
            .buttonStyle(.plain)
            .disabled(availableWeeks.first.map { week <= $0 } ?? true)

            Spacer()
            VStack(spacing: 2) {
                Text("WEEK").ffEyebrow(color: FFColor.textTertiary)
                Text("\(week)")
                    .font(.ffStatMedium)
                    .foregroundStyle(FFColor.textPrimary)
            }
            Spacer()

            Button {
                guard let idx = availableWeeks.firstIndex(of: week),
                      idx < availableWeeks.count - 1 else { return }
                withAnimation { week = availableWeeks[idx + 1] }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(10)
                    .background(FFColor.surface, in: Circle())
                    .foregroundStyle(FFColor.textPrimary)
            }
            .buttonStyle(.plain)
            .disabled(availableWeeks.last.map { week >= $0 } ?? true)
        }
    }

    private var emptyState: some View {
        VStack(spacing: FFSpace.s) {
            Image(systemName: "sportscourt")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(FFColor.textTertiary)
            Text("No schedule yet")
                .font(.ffHeadline).foregroundStyle(FFColor.textPrimary)
            Text("The NFL schedule for this season hasn't been published yet. Pull to refresh or check back soon.")
                .font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, FFSpace.xxl)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Game card

    private func gameCard(_ game: NFLGame) -> some View {
        Button {
            selectedGame = game
        } label: {
            VStack(alignment: .leading, spacing: FFSpace.s) {
                HStack(alignment: .center, spacing: FFSpace.s) {
                    sideBlock(team: game.away, score: game.awayScore,
                              isWinning: isWinning(game, side: .away),
                              status: game.status)
                    statusColumn(game)
                    sideBlock(team: game.home, score: game.homeScore,
                              isWinning: isWinning(game, side: .home),
                              status: game.status, isHome: true)
                }
                HStack(spacing: 4) {
                    Text("Game Center")
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

    private func isWinning(_ g: NFLGame, side: Side) -> Bool {
        guard let h = g.homeScore, let a = g.awayScore else { return false }
        switch side {
        case .home: return h > a
        case .away: return a > h
        }
    }

    private func sideBlock(team abbr: String, score: Int?, isWinning: Bool,
                           status: NFLGameStatus, isHome: Bool = false) -> some View {
        let meta = teams[abbr]
        return VStack(spacing: 4) {
            if let url = meta?.logoURL, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFit()
                    default: Color.clear
                    }
                }
                .frame(width: 44, height: 44)
            } else {
                Circle().fill(FFColor.surfaceElevated).frame(width: 44, height: 44)
            }
            // The card tap opens the game; the abbreviation alone links to
            // the team profile (inner gesture wins).
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
    private func statusColumn(_ g: NFLGame) -> some View {
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
                    .font(.ffMicro).tracking(0.8)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(FFColor.accent, in: Capsule())
                    .foregroundStyle(FFColor.bg)
            case .final:
                Text("FINAL")
                    .font(.ffMicro).tracking(0.8)
                    .foregroundStyle(FFColor.textTertiary)
            }
            if let spread = g.homeSpread {
                Text(formatSpread(spread, home: g.home, away: g.away))
                    .font(.ffMicro)
                    .foregroundStyle(FFColor.textTertiary)
            }
        }
    }

    // "BUF -7.5" — favorite + line. Home perspective if home is favored,
    // otherwise away perspective.
    private func formatSpread(_ s: Double, home: String, away: String) -> String {
        if s < 0 { return "\(home) \(String(format: "%.1f", s))" }
        if s > 0 { return "\(away) \(String(format: "%.1f", -s))" }
        return "PK"
    }

    // Note: top performers used to render inline here; that surface now
    // lives in GameDetailView's Overview tab, which opens the player profile
    // via the global presenter (app.showPlayer).
}
