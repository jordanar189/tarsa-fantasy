import Foundation
import Observation

@MainActor
@Observable
final class AppState {

    // Tab selection
    var tab: AppTab = .players

    // Season picking
    var seasons: [Int] = []
    var selectedSeason: Int = Calendar.current.component(.year, from: Date())

    // Loaded player data, keyed by season
    var playersBySeason: [Int: [String: Player]] = [:]

    // Leagues
    var leagueSummaries: [LeagueSummary] = []

    // Top-level error displayed if bootstrap fails entirely.
    var bootstrapError: String? = nil
    var isLoadingSeason: Bool = false

    private let data: NFLDataService
    private let store: LeagueStore

    init(data: NFLDataService = .shared, store: LeagueStore = .shared) {
        self.data = data
        self.store = store
    }

    // MARK: - Bootstrap

    func bootstrap(force: Bool = false) async {
        if !force && !seasons.isEmpty { return }
        bootstrapError = nil
        let list = await data.availableSeasons()
        if list.isEmpty {
            bootstrapError = "No NFL seasons reachable. Check your network connection."
            return
        }
        seasons = list
        if !list.contains(selectedSeason) {
            selectedSeason = list.first ?? selectedSeason
        }
        await loadSeason(selectedSeason)
        await reloadLeagues()
    }

    // MARK: - Season data

    @discardableResult
    func loadSeason(_ season: Int) async -> [String: Player]? {
        if let existing = playersBySeason[season] { return existing }
        isLoadingSeason = true
        defer { isLoadingSeason = false }
        do {
            let players = try await data.players(season: season)
            playersBySeason[season] = players
            return players
        } catch {
            bootstrapError = error.localizedDescription
            return nil
        }
    }

    func players(season: Int) -> [String: Player] {
        playersBySeason[season] ?? [:]
    }

    func selectedPlayers() -> [String: Player] {
        players(season: selectedSeason)
    }

    func availableWeeks(season: Int) -> [Int] {
        let players = self.players(season: season)
        var weeks: Set<Int> = []
        for (_, p) in players {
            for g in p.games { weeks.insert(g.week) }
        }
        return weeks.sorted()
    }

    // MARK: - Leagues

    func reloadLeagues() async {
        leagueSummaries = await store.list()
    }

    func createLeague(
        name: String,
        season: Int,
        scoring: Scoring,
        teamNames: [String],
        rosterConfig: RosterConfig = .default
    ) async throws -> League {
        let league = try await store.create(
            name: name, season: season, scoring: scoring,
            teamNames: teamNames, rosterConfig: rosterConfig
        )
        await reloadLeagues()
        // Pre-warm players for that season so the new league has stats to show.
        await loadSeason(season)
        return league
    }

    func setRoster(leagueID: String, teamID: String, playerIDs: [String]) async throws -> League {
        // Compute auto-fill on MainActor so we can use the player cache, then
        // hand both the roster and lineup to the actor-isolated store.
        guard let league = await store.get(leagueID) else {
            return try await store.setRoster(leagueID: leagueID, teamID: teamID, playerIDs: playerIDs)
        }
        let seasonPlayers = await loadSeason(league.season) ?? players(season: league.season)
        let lineup = Fantasy.autoFillLineup(
            roster: playerIDs,
            players: seasonPlayers,
            config: league.rosterConfig,
            scoring: league.scoring
        )
        let updated = try await store.setRoster(
            leagueID: leagueID, teamID: teamID,
            playerIDs: playerIDs, starters: lineup
        )
        await reloadLeagues()
        return updated
    }

    func deleteLeague(_ id: String) async {
        _ = try? await store.delete(id)
        await reloadLeagues()
    }

    func league(_ id: String) async -> League? {
        await store.get(id)
    }

    // MARK: - Previews

    static var preview: AppState {
        let state = AppState()
        state.seasons = [2025, 2024, 2023]
        state.selectedSeason = 2025
        return state
    }
}
