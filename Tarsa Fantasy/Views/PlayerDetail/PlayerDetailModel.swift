import SwiftUI

// Shared state for the player profile: the hub (PlayerDetailView) and its
// pushed subpages all read fetched data + load bookkeeping from here. Pure
// view-local UI state (presented sheets, local pickers) stays in the views.
@MainActor @Observable
final class PlayerDetailModel {
    var scoring: Scoring = .ppr
    // Custom per-stat weights from the selected league, when it overrides the
    // preset. Threaded alongside `scoring` so every point figure on the page
    // reflects the league's actual scoring.
    var scoringSettings: ScoringSettings? = nil
    var schedules: [NFLGame] = []
    // Latest regular-season week with league-wide stats, cached so the game-log
    // back-fill doesn't rescan every player on each render. Refreshed in `load`.
    var maxRegWeek: Int = 0
    var snapCounts: [String: [Int: SnapCount]] = [:]
    var rankByID: [String: PositionRank] = [:]
    var dvpByPosition: [String: [String: DvPEntry]] = [:]
    var teamTargets: [String: [Int: Double]] = [:]
    var teamTDs: [String: [Int: Double]] = [:]
    var projection: PlayerProjection? = nil
    var nicknameHistory: [NicknameHistoryEntry] = []
    var warByID: [String: Double] = [:]
    var careerSeasons: [Fantasy.CareerSeasonLine] = []
    var careerLoading = false
    var careerLoadedPlayerID: String? = nil
    private var careerLoadToken = 0
    // Injury history (career-wide, season-independent). Loaded lazily the first
    // time the Injuries page opens, mirroring the Career load pattern.
    var injuryEvents: [InjuryEvent] = []
    var injuryLoading = false
    var injuryLoadedPlayerID: String? = nil
    private var injuryLoadToken = 0
    // Season-range filter; nil = all time (the default). Lives here rather than
    // on the Injuries page because `loadInjuries` resets it per player.
    var injuryStartSeason: Int? = nil
    var injuryEndSeason: Int? = nil
    // Acquisition (hub landing): waiver/free-agent claim + trade entry for the
    // selected league. `dropped` distinguishes instant adds from waiver claims.
    var dropped: [DroppedPlayer] = []
    // Recent headlines tagging this player (hub card).
    var newsItems: [PlayerNewsItem] = []
    // Market context (hub card): draft ADP and MFL add/drop percentages.
    var adpByID: [String: Double] = [:]
    var trendingByID: [String: TrendingPlayer] = [:]

    // Season-scoped load — the hub re-runs this whenever the player or the
    // selected season changes (switching leagues changes app.selectedSeason).
    func load(app: AppState, playerID: String) async {
        // Stats inherit the selected league's scoring (preset + any
        // custom per-stat weights).
        scoring = app.activeScoring
        scoringSettings = app.activeScoringSettings
        careerSeasons = []
        careerLoadedPlayerID = nil
        await app.ensureProjectedSnapshot(season: app.selectedSeason)
        schedules = await app.schedules(season: app.selectedSeason)
        maxRegWeek = app.availableWeeks(season: app.selectedSeason).max() ?? 0
        snapCounts = await app.snapCounts(season: app.selectedSeason)
        rankByID = Fantasy.positionRanks(
            players: app.displaySelectedPlayers(), scoring: scoring, settings: scoringSettings
        )
        let players = app.displaySelectedPlayers()
        teamTargets = Fantasy.teamTargetsPerWeek(players: players)
        teamTDs     = Fantasy.teamTouchdownsPerWeek(players: players)
        warByID = Fantasy.warByPlayer(
            players: players, scoring: scoring,
            settings: scoringSettings,
            config: app.selectedLeague?.rosterConfig ?? .default,
            teamCount: app.selectedLeague?.teams.count ?? 12
        )
        // Load DvP for the player's own position only — that's the
        // only matchup we render. Read the player here (not up front) so a
        // freshly ensured projected snapshot is visible, matching the old
        // computed-property behavior.
        if let pos = app.displaySelectedPlayers()[playerID]?.position.uppercased() {
            let table = await app.dvp(season: app.selectedSeason, position: pos)
            dvpByPosition[pos] = table
        }
        projection = await app.liveProjection(
            playerID: playerID, season: app.selectedSeason, scoring: scoring
        )
        nicknameHistory = await app.playerNicknameHistory(playerID: playerID)
        newsItems = await app.news(playerID: playerID, limit: 5)
        adpByID = await app.adp(season: app.selectedSeason, scoring: scoring)
        trendingByID = Dictionary(
            uniqueKeysWithValues: await app.trendingPlayers(for: app.selectedLeague)
                .map { ($0.playerID, $0) }
        )
    }

    func loadCareerIfNeeded(app: AppState, player: Player) async {
        guard careerLoadedPlayerID != player.id else { return }
        await loadCareer(app: app, player: player)
    }

    func loadCareer(app: AppState, player p: Player) async {
        careerLoadToken &+= 1
        let token = careerLoadToken
        careerLoading = true
        let result = await app.careerSeasons(playerID: p.id, scoring: scoring, settings: scoringSettings)
        // Ignore a result a newer request (scoring change) superseded —
        // otherwise a slow PPR load could overwrite a fresher Standard one.
        guard token == careerLoadToken else { return }
        careerSeasons = result
        careerLoadedPlayerID = p.id
        careerLoading = false
    }

    func loadInjuriesIfNeeded(app: AppState, player: Player) async {
        guard injuryLoadedPlayerID != player.id else { return }
        await loadInjuries(app: app, player: player)
    }

    func loadInjuries(app: AppState, player p: Player) async {
        injuryLoadToken &+= 1
        let token = injuryLoadToken
        injuryLoading = true
        // Clear stale data up front so a player switch never renders the
        // previous player's injuries during the fetch window — with no events
        // the section falls back to its loading state.
        injuryEvents = []
        // Reset to the default all-time view whenever a new player loads.
        injuryStartSeason = nil
        injuryEndSeason = nil
        let result = await app.injuryHistory(playerID: p.id)
        guard token == injuryLoadToken else { return }
        injuryEvents = result
        injuryLoadedPlayerID = p.id
        injuryLoading = false
    }

    // Recompute the scoring-dependent derived state after the active scoring
    // (preset or custom weights) changes — e.g. when the user switches leagues.
    func applyScoringChange(app: AppState, playerID: String) {
        let players = app.displaySelectedPlayers()
        rankByID = Fantasy.positionRanks(players: players, scoring: scoring, settings: scoringSettings)
        warByID = Fantasy.warByPlayer(
            players: players, scoring: scoring,
            settings: scoringSettings,
            config: app.selectedLeague?.rosterConfig ?? .default,
            teamCount: app.selectedLeague?.teams.count ?? 12
        )
        Task {
            projection = await app.liveProjection(
                playerID: playerID, season: app.selectedSeason, scoring: scoring
            )
        }
        if careerLoadedPlayerID == playerID {
            // Loaded under the old scoring; invalidate so the Career page
            // reloads — immediately if it's open (it watches this key),
            // otherwise the next time it's opened.
            careerLoadedPlayerID = nil
        }
    }

    func reloadDropped(app: AppState) async {
        guard let id = app.selectedLeagueID else { dropped = []; return }
        dropped = await app.droppedPlayers(leagueID: id)
    }

    // Best-effort: the next scheduled opponent for this player's team. If we
    // have no schedule data yet, returns nil and dependent cards hide.
    func nextOpponentTeam(for p: Player) -> String? {
        guard !p.team.isEmpty else { return nil }
        let now = Date()
        guard let g = schedules
            .filter({ g in g.kickoff.map { $0 > now } ?? false })
            .first(where: { $0.home == p.team || $0.away == p.team }) else { return nil }
        return g.home == p.team ? g.away : g.home
    }
}

// MARK: - Ranks card (team off vs next opponent def, from MFL)

// Shared by the hub landing and the Details page.
struct RanksCardView: View {
    let own: TeamRanks?
    let opp: TeamRanks?
    let oppTeam: String?

    var body: some View {
        VStack(alignment: .leading, spacing: FFSpace.s) {
            Text("MATCHUP RANKS").ffEyebrow().padding(.leading, FFSpace.s)
            HStack(alignment: .top, spacing: FFSpace.l) {
                column(title: "OWN OFFENSE",
                       rows: [("Pass", own?.passOffense), ("Rush", own?.rushOffense)])
                Rectangle().fill(FFColor.border).frame(width: 1, height: 56)
                column(title: "\(oppTeam ?? "OPP") DEFENSE",
                       rows: [("Pass", opp?.passDefense), ("Rush", opp?.rushDefense)])
            }
            .padding(FFSpace.m)
            .background(FFColor.surface, in: RoundedRectangle(cornerRadius: FFRadius.m))
            .overlay(
                RoundedRectangle(cornerRadius: FFRadius.m)
                    .strokeBorder(FFColor.border, lineWidth: 1)
            )
        }
    }

    private func column(title: String, rows: [(String, Int?)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).ffEyebrow(color: FFColor.textTertiary)
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 6) {
                    Text(row.0).font(.ffCaption).foregroundStyle(FFColor.textSecondary)
                    Spacer(minLength: 4)
                    if let r = row.1 {
                        Text("#\(r)")
                            .font(.ffStatSmall)
                            .foregroundStyle(rankColor(r))
                    } else {
                        Text("—").font(.ffCaption).foregroundStyle(FFColor.textTertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Green = top 8, yellow = mid, red = bottom 8. Same scale for off and def
    // (1 = best offense and best defense by convention here).
    private func rankColor(_ r: Int) -> Color {
        switch r {
        case ...8:  return FFColor.positive
        case 25...: return FFColor.negative
        default:    return FFColor.warning
        }
    }
}
