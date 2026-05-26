import Foundation
import Observation

@MainActor
@Observable
final class AppState {

    // Tab selection
    var tab: AppTab = .league

    // Globally-presented player profile. Set via showPlayer(_:) so tapping a
    // player name anywhere in the app opens PlayerDetailView, without threading
    // a binding down through every view. ContentView hosts the sheet.
    var presentedPlayerID: String? = nil

    func showPlayer(_ playerID: String?) {
        guard let playerID, !playerID.isEmpty else { return }
        presentedPlayerID = playerID
    }

    // The league currently in focus. nil = show the league overview/landing
    // screen; non-nil = the tabbed (NFL + League) experience for this league.
    // selectedLeague holds the fully-loaded League so league-specific numbers
    // (scoring, ownership, free agents) can be computed app-wide.
    var selectedLeagueID: String? = nil
    var selectedLeague: League? = nil
    // Guards against an older selectLeague load landing after a newer one.
    private var selectLeagueToken = 0

    // Scoring/season the rest of the app inherits from the selected league.
    // Player stat surfaces read these instead of carrying their own toggle.
    var activeScoring: Scoring { selectedLeague?.scoring ?? .ppr }
    var activeScoringSettings: ScoringSettings? { selectedLeague?.scoringSettings }

    // Season picking
    var seasons: [Int] = []
    var selectedSeason: Int = Calendar.current.component(.year, from: Date())

    // Loaded player data, keyed by season
    var playersBySeason: [Int: [String: Player]] = [:]

    // Display-only projected snapshots for not-yet-started seasons, keyed by
    // season. Each player's `games` are synthetic per-week projections so the
    // browse/draft surfaces show a "preseason feel". NEVER used for league
    // scoring — leagues always read playersBySeason.
    var projectedBySeason: [Int: [String: Player]] = [:]
    private var projectionInFlight: Set<Int> = []

    // Auth / account
    var session: Session? = nil
    var authError: String? = nil
    var isAuthInFlight: Bool = false

    // Leagues belonging to the signed-in user
    var leagueSummaries: [LeagueSummary] = []

    // Read-only leagues imported from Sleeper. Persisted locally (SleeperStore),
    // not in Supabase — they're browsed, never played through the live engine.
    var importedSleeperLeagues: [ImportedLeague] = []

    // Set when an invite link is opened. LeaguesView consumes it to present
    // the join sheet pre-filled. Held until the user is signed in and the
    // Leagues tab can pick it up.
    var pendingJoinCode: String? = nil

    // Social graph + DM inbox. Reloaded on bootstrap and on pull-to-refresh
    // of the Chat tab. dmInbox stores both the thread row and the cached
    // profile of the other participant so the conversation list can render
    // without a per-row fetch.
    var friendships: [Friendship] = []
    var dmInbox: [DMInboxEntry] = []

    // Top-level error displayed if bootstrap fails entirely.
    var bootstrapError: String? = nil
    var isLoadingSeason: Bool = false

    // UI theme (system/light/dark). Mirrored to UserDefaults so the launch
    // splash uses the right scheme before we've fetched the user's row.
    // setTheme writes both the local cache and the profiles.theme column.
    var theme: AppTheme = AppState.localCachedTheme() {
        didSet { AppState.cacheLocalTheme(theme) }
    }

    // App-wide injury snapshot, keyed by player_id. Refreshed at bootstrap
    // and on pull-to-refresh; healthy players are absent. Views read this
    // synchronously to decorate player rows.
    var injuries: [String: Injury] = [:]

    // Per-team rolling offense/defense ranks (MFL). Empty in the off-season.
    var teamRanks: [String: TeamRanks] = [:]
    // % of MFL leagues that started each player in the most recent week.
    var mostStarted: [String: Double] = [:]
    // True while a background refresh of a season is in flight (after the
    // disk cache was shown). Drives the thin top-edge refresh indicator.
    var isRefreshingSeason: Bool = false

    private let data: NFLDataService
    private let remote: RemoteService
    private let sleeper: SleeperService

    init(data: NFLDataService = .shared, remote: RemoteService = .shared,
         sleeper: SleeperService = .shared) {
        self.data = data
        self.remote = remote
        self.sleeper = sleeper
        // Imported Sleeper leagues are local data; load them synchronously so
        // the Leagues tab can render them on first paint.
        importedSleeperLeagues = SleeperStore.shared.loadAll()
        // Subscribe to live score updates pushed by LiveScoresListener; each
        // notification re-pulls the matching season snapshot from the data
        // actor so SwiftUI sees the new fantasy points immediately.
        NotificationCenter.default.addObserver(
            forName: .liveScoresUpdated, object: nil, queue: .main
        ) { [weak self] note in
            guard let season = note.userInfo?["season"] as? Int else { return }
            Task { @MainActor [weak self] in
                await self?.refreshLiveSnapshot(season: season)
            }
        }
        // Notification taps post .pushDeepLink with the payload URL.
        NotificationCenter.default.addObserver(
            forName: .pushDeepLink, object: nil, queue: .main
        ) { [weak self] note in
            let url = note.object as? URL
            Task { @MainActor [weak self] in self?.handlePushDeepLink(url) }
        }
    }

    // MARK: - Bootstrap

    func bootstrap(force: Bool = false) async {
        if !force {
            // Try to restore a persisted Supabase session on launch.
            if session == nil {
                session = await remote.restoreSession()
            }
        }
        if session != nil { await setUpPushNotifications() }
        if !force && !seasons.isEmpty {
            await reloadLeagues()
            await applyInitialLeagueSelection()
            return
        }
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
        await applyInitialLeagueSelection()
        await reloadFriendsAndDMs()
        await loadProfileTheme()
        await loadInjuries()
        await loadMarketSignals()
    }

    // Where to land on launch: a sole league drops you straight in; with
    // several leagues a cold launch starts on the overview so you choose.
    // No-op once something is already selected (warm re-bootstrap / returning).
    private func applyInitialLeagueSelection() async {
        guard selectedLeagueID == nil else { return }
        if leagueSummaries.count == 1, let only = leagueSummaries.first {
            await selectLeague(only.id)
        }
    }

    // Focus a league (or nil to return to the overview). Loads the full league
    // plus its season + nicknames so league-specific numbers are ready. Keeps
    // the user wherever they are — only the surrounding data changes.
    func selectLeague(_ id: String?) async {
        selectedLeagueID = id
        guard let id else { selectedLeague = nil; return }
        selectLeagueToken &+= 1
        let token = selectLeagueToken
        guard let lg = await league(id) else { return }
        guard token == selectLeagueToken else { return }
        selectedLeague = lg
        if selectedSeason != lg.season { selectedSeason = lg.season }
        await loadSeason(lg.season)
        await loadLeagueNicknames(leagueID: id)
        await loadLeagueValues(leagueID: id)
    }

    // Re-pull the selected league after a mutation so the switcher, NFL tab,
    // and league views all see fresh rosters/numbers.
    func refreshSelectedLeague() async {
        guard let id = selectedLeagueID else { return }
        if let lg = await league(id) { selectedLeague = lg }
        await loadLeagueNicknames(leagueID: id)
        await loadLeagueValues(leagueID: id)
    }

    // The team the signed-in user controls in a league (the sim's primary team
    // when every team is creator-owned).
    func myTeam(in league: League) -> FantasyTeam? {
        if league.isTest, let id = AppState.primaryTeamID(in: league) {
            return league.teams.first(where: { $0.id == id })
        }
        guard let uid = session?.userID else { return nil }
        return league.teams.first(where: { $0.ownerID == uid })
    }

    // Bundles everything the Lineup / Matchup tabs need for one week: schedule,
    // DvP-by-position, injuries, inactives, and a full projection pass.
    func weekContext(league: League, week: Int) async -> WeekContext {
        let snapshot = players(season: league.season)
        let schedule = await schedules(season: league.season)
        var dvp: [String: [String: DvPEntry]] = [:]
        for pos in ["QB", "RB", "WR", "TE", "K", "DEF"] {
            dvp[pos] = await self.dvp(for: league, position: pos)
        }
        let inj = await injuries(for: league)
        let inactive = await inactives(season: league.season, week: week)

        // Preseason: the raw snapshot has no games to project from, so a live
        // projectAll pass comes back empty. Read projections out of the same
        // prior-season-seeded projected snapshot the browse/draft surfaces use,
        // so Lineup/Matchup show the same numbers as the Players tab. `players`
        // stays the raw snapshot so hasPlayed/actualPoints don't mistake a
        // projection for a finished game.
        let projections: [String: PlayerProjection]
        if isPreseason(season: league.season) {
            await ensureProjectedSnapshot(season: league.season)
        }
        if let projected = projectedBySeason[league.season] {
            projections = Fantasy.projectionsFromSnapshot(
                projected, season: league.season, week: week, scoring: league.scoring
            )
        } else {
            let ctx = Fantasy.ProjectionContext(
                season: league.season, week: week, scoring: league.scoring,
                players: snapshot, schedule: schedule,
                dvpByPosition: dvp, injuries: inj, inactives: inactive, config: .default
            )
            projections = Fantasy.projectAll(context: ctx)
        }

        return WeekContext(
            week: week, scoring: league.scoring, players: snapshot,
            schedule: schedule, dvpByPosition: dvp, injuries: inj,
            inactives: inactive, projections: projections
        )
    }

    // MARK: - Auth

    func signUp(username: String, password: String) async {
        await runAuth { try await self.remote.signUp(username: username, password: password) }
    }

    func signIn(username: String, password: String) async {
        await runAuth { try await self.remote.signIn(username: username, password: password) }
    }

    func signOut() async {
        await NotificationManager.shared.clearOnSignOut()
        try? await remote.signOut()
        session = nil
        leagueSummaries = []
        selectedLeagueID = nil
        selectedLeague = nil
        friendships = []
        dmInbox = []
    }

    private func runAuth(_ op: @escaping () async throws -> Session) async {
        isAuthInFlight = true
        authError = nil
        defer { isAuthInFlight = false }
        do {
            let s = try await op()
            session = s
            // On first sign-in, drop any pre-account local leagues file from
            // the old LeagueStore — the user opted to discard it.
            Self.removeLocalLeaguesFileIfPresent()
            await reloadLeagues()
            await applyInitialLeagueSelection()
            await reloadFriendsAndDMs()
            await loadProfileTheme()
            await setUpPushNotifications()
        } catch {
            authError = error.localizedDescription
        }
    }

    private static func removeLocalLeaguesFileIfPresent() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let url = docs?.appendingPathComponent("leagues.json") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Theme

    private static let themeStorageKey = "app.theme"

    private static func localCachedTheme() -> AppTheme {
        let raw = UserDefaults.standard.string(forKey: themeStorageKey) ?? AppTheme.dark.rawValue
        return AppTheme(rawValue: raw) ?? .dark
    }

    private static func cacheLocalTheme(_ theme: AppTheme) {
        UserDefaults.standard.set(theme.rawValue, forKey: themeStorageKey)
    }

    // Load the user's persisted theme from the server (overrides the local
    // cache when present). Called once after sign-in completes.
    func loadProfileTheme() async {
        guard let uid = session?.userID else { return }
        if let remote = await remote.profileTheme(userID: uid) {
            theme = remote
        }
    }

    // Persist the user's pick to the server. Updates the local state
    // immediately (so the UI flips), then writes through.
    func setTheme(_ new: AppTheme) async {
        theme = new
        guard let uid = session?.userID else { return }
        _ = try? await remote.setProfileTheme(userID: uid, theme: new)
    }

    // MARK: - Season data

    @discardableResult
    func loadSeason(_ season: Int) async -> [String: Player]? {
        if let existing = playersBySeason[season] { return existing }

        // Disk cache hit → show stale data instantly, refresh in background.
        // Cold launch and season-switch become a non-event for the user.
        if let cached = PlayerCacheStore.shared.loadSync(season: season) {
            setPlayers(cached, season: season)
            await data.seed(season: season, players: cached)
            Task { await LiveScoresListener.shared.start(season: season) }
            Task { await self.refreshSeasonInBackground(season) }
            return cached
        }

        // No cache → block on the network like before.
        isLoadingSeason = true
        defer { isLoadingSeason = false }
        do {
            let players = try await data.players(season: season)
            setPlayers(players, season: season)
            PlayerCacheStore.shared.save(season: season, players: players)
            Task { await LiveScoresListener.shared.start(season: season) }
            return players
        } catch {
            bootstrapError = error.localizedDescription
            return nil
        }
    }

    // Re-fetches the season from Supabase off the visible path. Failures are
    // swallowed — if we're offline, keep showing the cached snapshot.
    private func refreshSeasonInBackground(_ season: Int) async {
        isRefreshingSeason = true
        defer { isRefreshingSeason = false }
        do {
            let fresh = try await data.players(season: season, forceRefresh: true)
            setPlayers(fresh, season: season)
            PlayerCacheStore.shared.save(season: season, players: fresh)
        } catch {
            #if DEBUG
            print("Background refresh \(season) failed: \(error)")
            #endif
        }
    }

    func players(season: Int) -> [String: Player] {
        playersBySeason[season] ?? [:]
    }

    // Single funnel for publishing a season's real player snapshot. A preseason
    // projection is display-only and valid *only* until real games arrive — so
    // the moment any game shows up (network load, background refresh, or live
    // snapshot update) we drop the cached projection. Without this, displayPlayers
    // / isProjectedSeason would keep serving synthetic preseason points after
    // Week 1 data starts flowing.
    private func setPlayers(_ players: [String: Player], season: Int) {
        playersBySeason[season] = players
        if projectedBySeason[season] != nil,
           players.values.contains(where: { !$0.games.isEmpty }) {
            projectedBySeason[season] = nil
        }
    }

    // Pulls the latest snapshot (including any live overrides) from the data
    // actor and republishes it. Views call this after they get a Realtime
    // signal so SwiftUI re-renders with fresh fantasy point totals.
    func refreshLiveSnapshot(season: Int) async {
        if let snap = await data.currentSnapshot(season: season) {
            setPlayers(snap, season: season)
        }
    }

    func selectedPlayers() -> [String: Player] {
        players(season: selectedSeason)
    }

    // MARK: - Career (multi-season aggregation)

    // A player's per-season career table across every available season, most
    // recent first, with each season's fantasy points and position rank under
    // the supplied scoring. Served by the player_career RPC in a single
    // round-trip (the server aggregates per-season totals + ranks), falling back
    // to a client-side per-season crunch only if the RPC is unavailable.
    func careerSeasons(playerID: String, scoring: Scoring, settings: ScoringSettings? = nil) async -> [Fantasy.CareerSeasonLine] {
        // Fast path: one server-side aggregation round-trip (player_career RPC),
        // which returns the player's per-season totals + position rank directly.
        // A thrown error (e.g. the RPC isn't deployed yet) falls back to the
        // client-side crunch below; a successful empty result is a real "no
        // career" and is returned as-is.
        if let lines = try? await data.careerLines(
            playerID: playerID, scoring: scoring, settings: settings
        ) {
            return lines
        }
        return await careerSeasonsLocal(playerID: playerID, scoring: scoring, settings: settings)
    }

    // Fallback career aggregation: build each season's line from the in-memory /
    // disk / network snapshot, one season at a time. Heavy on a cold cache (a
    // fetch per season) — used only when the player_career RPC is unavailable.
    private func careerSeasonsLocal(playerID: String, scoring: Scoring, settings: ScoringSettings? = nil) async -> [Fantasy.CareerSeasonLine] {
        var lines: [Fantasy.CareerSeasonLine] = []
        for season in seasons {
            let inMemory = playersBySeason[season]
            let line = await Task.detached(priority: .userInitiated) { [data] () -> Fantasy.CareerSeasonLine? in
                let snapshot: [String: Player]
                if let inMemory {
                    snapshot = inMemory
                } else if let cached = PlayerCacheStore.shared.loadSync(season: season) {
                    snapshot = cached
                } else if let fetched = try? await data.players(season: season) {
                    PlayerCacheStore.shared.save(season: season, players: fetched)
                    snapshot = fetched
                } else {
                    return nil
                }
                return Fantasy.careerSeasonLine(
                    playerID: playerID, season: season,
                    snapshot: snapshot, scoring: scoring, settings: settings
                )
            }.value
            if let line { lines.append(line) }
        }
        return lines.sorted { $0.season > $1.season }
    }

    // MARK: - Preseason projection snapshots

    // A season is "preseason" when its roster is loaded but no games have been
    // played yet — nflverse has no weekly stats, only the schedule exists.
    func isPreseason(season: Int) -> Bool {
        let snap = players(season: season)
        guard !snap.isEmpty else { return false }
        return snap.values.allSatisfy { $0.games.isEmpty }
    }

    // True once a projected snapshot has been built for the season — i.e. the
    // browse/draft surfaces are showing projections rather than real stats.
    func isProjectedSeason(_ season: Int) -> Bool { projectedBySeason[season] != nil }

    // Players to display in browse/draft surfaces: the projected snapshot in
    // preseason, otherwise the real snapshot. Distinct from players(season:),
    // which league scoring uses.
    func displayPlayers(season: Int) -> [String: Player] {
        projectedBySeason[season] ?? players(season: season)
    }

    func displaySelectedPlayers() -> [String: Player] {
        displayPlayers(season: selectedSeason)
    }

    // Builds the preseason projection snapshot once per season (idempotent).
    // Seeds from the most recent prior season that actually has games, applies
    // that season's defense-vs-position to the new schedule, and caches the
    // result. No-op when the season isn't preseason or has no usable prior data.
    func ensureProjectedSnapshot(season: Int) async {
        if projectedBySeason[season] != nil || projectionInFlight.contains(season) { return }
        guard isPreseason(season: season) else { return }
        let current = players(season: season)
        guard !current.isEmpty else { return }
        projectionInFlight.insert(season)
        defer { projectionInFlight.remove(season) }

        // Walk back to the latest season that has real game data to seed from.
        let floor = seasons.min() ?? (season - 5)
        var priorPlayers: [String: Player] = [:]
        var priorSeason = season - 1
        while priorSeason >= floor {
            let snap = await loadSeason(priorSeason) ?? [:]
            if snap.values.contains(where: { !$0.games.isEmpty }) {
                priorPlayers = snap
                break
            }
            priorSeason -= 1
        }
        guard !priorPlayers.isEmpty else { return }

        let schedule = await schedules(season: season)
        guard !schedule.isEmpty else { return }

        var dvpByPos: [String: [String: DvPEntry]] = [:]
        for pos in ["QB", "RB", "WR", "TE"] {
            dvpByPos[pos] = await dvp(season: priorSeason, position: pos)
        }

        // Guard against the snapshot having been built — or real games having
        // arrived — while we awaited network data.
        guard projectedBySeason[season] == nil, isPreseason(season: season) else { return }
        projectedBySeason[season] = Fantasy.preseasonProjectedSnapshot(
            season: season, players: current, priorPlayers: priorPlayers,
            schedule: schedule, dvpByPosition: dvpByPos, injuries: injuries
        )
    }

    // MARK: - NFL data (Phase 1 stats overhaul)

    func schedules(season: Int) async -> [NFLGame] {
        (try? await data.schedules(season: season)) ?? []
    }

    func nflTeams() async -> [NFLTeamMeta] {
        await data.teams()
    }

    func snapCounts(season: Int) async -> [String: [Int: SnapCount]] {
        (try? await data.snapCounts(season: season)) ?? [:]
    }

    func trendingPlayers() async -> [TrendingPlayer] {
        await remote.trendingPlayers()
    }

    // Simulation-aware trending: inside a sim, returns what was trending
    // during the simulated week of the simulated season. Outside, returns
    // current live trending.
    func trendingPlayers(for league: League?) async -> [TrendingPlayer] {
        if let lg = league, lg.isTest, let week = lg.simulatedWeek, week > 0 {
            return await remote.trendingPlayers(season: lg.season, week: week)
        }
        return await remote.trendingPlayers()
    }

    func loadInjuries() async {
        injuries = await remote.injuries()
    }

    // Simulation-aware injury snapshot. For sims, pulls historical injuries
    // at the simulated week; for real leagues, returns the global live map.
    func injuries(for league: League?) async -> [String: Injury] {
        if let lg = league, lg.isTest, let week = lg.simulatedWeek, week > 0 {
            return await remote.injuries(season: lg.season, week: week)
        }
        return injuries
    }

    func loadMarketSignals() async {
        async let ranks = data.teamRanks()
        async let starters = data.mostStarted()
        teamRanks   = await ranks
        mostStarted = await starters
    }

    func dvp(season: Int, position: String) async -> [String: DvPEntry] {
        (try? await data.dvp(season: season, position: position)) ?? [:]
    }

    // Simulation-aware DvP: clamps rank window to the simulated week.
    func dvp(for league: League, position: String) async -> [String: DvPEntry] {
        let upTo = league.isTest ? league.simulatedWeek : nil
        return (try? await data.dvp(season: league.season, position: position, upToWeek: upTo)) ?? [:]
    }

    func adp(season: Int, scoring: Scoring) async -> [String: Double] {
        (try? await data.adp(season: season, scoring: scoring)) ?? [:]
    }

    // Point-in-time ADP for a simulation. Picks the latest snapshot on or
    // before the simulation's "draft date" — for past seasons that's
    // late August of that season, which mirrors typical draft windows.
    func adpForSimulation(season: Int, scoring: Scoring) async -> [String: Double] {
        let cal = Calendar(identifier: .gregorian)
        let draftDate = cal.date(from: DateComponents(year: season, month: 8, day: 25)) ?? Date()
        return (try? await data.adp(season: season, scoring: scoring, onOrBefore: draftDate)) ?? [:]
    }

    // Inactives (set of player IDs) for a given (season, week). Empty when
    // we don't have backfill for that season.
    func inactives(season: Int, week: Int) async -> Set<String> {
        await data.inactives(season: season, week: week)
    }

    // Depth chart for one team in a (season, week). Empty when not backfilled.
    func depthChart(season: Int, week: Int, team: String) async -> [DepthChartEntry] {
        await data.depthChart(season: season, week: week, team: team)
    }

    func availableWeeks(season: Int) -> [Int] {
        let players = self.players(season: season)
        var weeks: Set<Int> = []
        for (_, p) in players {
            for g in p.games { weeks.insert(g.week) }
        }
        return weeks.sorted()
    }

    // MARK: - Projections

    // Projects a single player's next upcoming game using current data
    // (full history, live injuries, full-season DvP for the player's position).
    // Returns nil when the player's team has no upcoming scheduled game.
    func liveProjection(
        playerID: String, season: Int, scoring: Scoring,
        config: ProjectionConfig = .default
    ) async -> PlayerProjection? {
        let snapshot = players(season: season)
        guard let p = snapshot[playerID], !p.team.isEmpty else { return nil }
        let schedule = await schedules(season: season)
        let now = Date()
        guard let nextGame = schedule
            .filter({ $0.kickoff.map { $0 > now } ?? false })
            .filter({ $0.home == p.team || $0.away == p.team })
            .min(by: { ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture) })
        else { return nil }
        let pos = p.position.uppercased()
        let table = await dvp(season: season, position: pos)
        let ctx = Fantasy.ProjectionContext(
            season: season, week: nextGame.week, scoring: scoring,
            players: snapshot, schedule: schedule,
            dvpByPosition: [pos: table], injuries: injuries,
            inactives: [], config: config
        )
        return Fantasy.project(playerID: playerID, context: ctx)
    }

    // Replays projections across a completed season and scores them against
    // actuals. Assembles each week's context with history < week and DvP /
    // injuries / inactives as of that week (no look-ahead), then runs the pure
    // Fantasy.backtest. `startWeek` skips the thin early weeks where there's
    // little history to project from.
    func runBacktest(
        season: Int, scoring: Scoring,
        config: ProjectionConfig = .default, startWeek: Int = 4
    ) async -> BacktestReport {
        let full = await loadSeason(season) ?? players(season: season)
        let schedule = await schedules(season: season)
        let weeks = availableWeeks(season: season).filter { $0 >= startWeek }
        let positions = ["QB", "RB", "WR", "TE"]
        var contexts: [Fantasy.ProjectionContext] = []
        for w in weeks {
            let history = Fantasy.clamped(full, upTo: w - 1)
            var dvpByPos: [String: [String: DvPEntry]] = [:]
            for pos in positions {
                dvpByPos[pos] = (try? await data.dvp(season: season, position: pos, upToWeek: w - 1)) ?? [:]
            }
            let inj = await remote.injuries(season: season, week: w)
            let inactive = await inactives(season: season, week: w)
            contexts.append(Fantasy.ProjectionContext(
                season: season, week: w, scoring: scoring,
                players: history, schedule: schedule,
                dvpByPosition: dvpByPos, injuries: inj,
                inactives: inactive, config: config
            ))
        }
        return Fantasy.backtest(weeks: contexts, actuals: full)
    }

    // MARK: - Leagues

    func reloadLeagues() async {
        guard let session else { leagueSummaries = []; return }
        do {
            leagueSummaries = try await remote.myLeagues(userID: session.userID)
            // Drop the selection if that league is gone (deleted / left).
            if let id = selectedLeagueID, !leagueSummaries.contains(where: { $0.id == id }) {
                selectedLeagueID = nil
                selectedLeague = nil
            }
        } catch {
            leagueSummaries = []
            bootstrapError = error.localizedDescription
        }
    }

    func createLeague(
        name: String,
        season: Int,
        scoring: Scoring,
        yourTeamName: String,
        otherTeamNames: [String],
        rosterConfig: RosterConfig = .default,
        regularSeasonWeeks: Int = 14,
        playoffTeams: Int = 6,
        playoffReseed: Bool = true,
        weeksPerRound: Int = 1,
        divisionNames: [String] = [],
        scoringSettings: ScoringSettings? = nil,
        isDynasty: Bool = false
    ) async throws -> League {
        guard let session else { throw AppError.notSignedIn }
        let league = try await remote.createLeague(
            creatorID: session.userID,
            name: name, season: season, scoring: scoring,
            rosterConfig: rosterConfig,
            yourTeamName: yourTeamName, otherTeamNames: otherTeamNames,
            regularSeasonWeeks: regularSeasonWeeks,
            playoffTeams: playoffTeams,
            playoffReseed: playoffReseed,
            weeksPerRound: weeksPerRound,
            divisionNames: divisionNames,
            scoringSettings: scoringSettings,
            isDynasty: isDynasty
        )
        await reloadLeagues()
        await selectLeague(league.id)
        return league
    }

    func setRoster(leagueID: String, teamID: String, playerIDs: [String]) async throws -> League {
        guard let league = try await remote.league(id: leagueID) else {
            throw AppError.leagueNotFound
        }
        let seasonPlayers = await loadSeason(league.season) ?? players(season: league.season)
        let irSet = Set(league.teams.first(where: { $0.id == teamID })?.ir ?? [])
        let lineup = Fantasy.autoFillLineup(
            roster: playerIDs,
            players: seasonPlayers,
            config: league.rosterConfig,
            scoring: league.scoring,
            settings: league.scoringSettings,
            ir: irSet
        )
        guard let updated = try await remote.setRoster(
            teamID: teamID, roster: playerIDs, starters: lineup
        ) else {
            throw AppError.leagueNotFound
        }
        await reloadLeagues()
        await refreshSelectedNicknames()
        return updated
    }

    func deleteLeague(_ id: String) async {
        try? await remote.deleteLeague(id)
        await reloadLeagues()
    }

    // MARK: - Sleeper import

    // Current NFL season per Sleeper, used to default the import picker.
    func sleeperCurrentSeason() async -> Int? {
        await sleeper.nflState()?.season
    }

    func sleeperUser(username: String) async throws -> SleeperUserBrief {
        try await sleeper.user(username: username)
    }

    func sleeperLeagues(userID: String, season: Int) async throws -> [SleeperLeagueBrief] {
        try await sleeper.leagues(userID: userID, season: season)
    }

    // Pulls a Sleeper league and its full season history, persists it locally,
    // and returns it. Re-importing the same league refreshes it in place.
    @discardableResult
    func importSleeperLeague(rootLeagueID: String) async throws -> ImportedLeague {
        let league = try await sleeper.importLeague(rootLeagueID: rootLeagueID)
        if let idx = importedSleeperLeagues.firstIndex(where: { $0.id == league.id }) {
            // Preserve the local-only activation link across a re-import — the
            // Sleeper API never returns it, so a fresh fetch would drop it and
            // the league would look un-promoted again.
            var merged = league
            merged.activatedLeagueID = importedSleeperLeagues[idx].activatedLeagueID
            importedSleeperLeagues[idx] = merged
        } else {
            importedSleeperLeagues.insert(league, at: 0)
        }
        SleeperStore.shared.saveAll(importedSleeperLeagues)
        return league
    }

    func deleteImportedSleeperLeague(id: String) {
        importedSleeperLeagues.removeAll { $0.id == id }
        SleeperStore.shared.saveAll(importedSleeperLeagues)
    }

    func importedSleeperLeague(id: String) -> ImportedLeague? {
        importedSleeperLeagues.first { $0.id == id }
    }

    // Promotes a read-only Sleeper import into a real, playable Tarsa league
    // owned by the signed-in user (the "replacement for Sleeper" path). It:
    //   • creates the live league + teams using the import's latest season —
    //     scoring, roster slots and regular-season length are carried over;
    //   • claims the user's chosen team as commissioner and leaves the rest
    //     open so leaguemates can join with the league's join code;
    //   • populates every team's current roster from the latest Sleeper season
    //     (mapped to app player ids) and auto-fills a starting lineup;
    //   • backfills each completed prior season's final standings into league
    //     history so the History tab shows past champions and records.
    // Going-forward scoring uses this app's nflverse engine, so it won't
    // reproduce Sleeper's historical per-week points exactly.
    @discardableResult
    func promoteSleeperLeague(importedID: String, myRosterID: Int, name: String? = nil) async throws -> League {
        guard let session else { throw AppError.notSignedIn }
        guard let imported = importedSleeperLeague(id: importedID),
              let latest = imported.latest,
              let myTeam = latest.teams.first(where: { $0.rosterID == myRosterID })
        else { throw AppError.leagueNotFound }

        let scoring = SleeperPromotion.scoring(fromLabel: latest.scoringLabel)
        let rosterConfig = SleeperPromotion.rosterConfig(from: latest.rosterPositions)
        let regularSeasonWeeks = SleeperPromotion.regularSeasonWeeks(from: latest)
        let leagueName: String
        if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            leagueName = trimmed
        } else {
            leagueName = imported.name
        }
        let seasonYear = latest.seasonYear

        // Order teams so the user's team is first — createLeague claims index 0
        // for the creator. Keep the parallel ImportedTeam order to map rosters
        // back to the created teams (returned in the same sort order). Names are
        // forced non-empty so createLeague can't drop a blank-named team and
        // throw the zip below out of alignment.
        let others = latest.teams.filter { $0.rosterID != myRosterID }
        let orderedSources = [myTeam] + others
        func teamName(_ t: ImportedTeam) -> String {
            let n = t.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
            return n.isEmpty ? "Team \(t.rosterID)" : n
        }

        let league = try await remote.createLeague(
            creatorID: session.userID,
            name: leagueName,
            season: seasonYear,
            scoring: scoring,
            rosterConfig: rosterConfig,
            yourTeamName: teamName(myTeam),
            otherTeamNames: others.map(teamName),
            regularSeasonWeeks: regularSeasonWeeks
        )

        // Populating rosters is the core promise, so a failure here is fatal:
        // collect failures and, if any occur, roll the new league back so the
        // user gets a clean retry instead of a half-populated league that looks
        // like it succeeded. Created teams come back sorted by the
        // [myTeam] + others order we inserted them in.
        let snapshot = await loadSeason(seasonYear) ?? players(season: seasonYear)
        let lookup = latest.playerLookup
        let nameIndex = SleeperPromotion.nameIndex(for: snapshot)
        var rosterFailures = 0
        for (created, source) in zip(league.teams, orderedSources) {
            // Carry the Sleeper team logo over (best-effort — purely cosmetic, so
            // a failure here must never fail or roll back the promotion). Done
            // before the empty-roster skip so logo-only teams still get branded.
            if let logo = SleeperService.fullAvatarURLString(source.avatar) {
                try? await remote.setTeamLogo(teamID: created.id, logoURL: logo)
            }
            let roster = SleeperPromotion.resolveRoster(
                for: source, lookup: lookup, snapshot: snapshot, nameIndex: nameIndex
            )
            guard !roster.isEmpty else { continue }
            let starters = Fantasy.autoFillLineup(
                roster: roster, players: snapshot,
                config: rosterConfig, scoring: scoring
            )
            do {
                _ = try await remote.setRoster(teamID: created.id, roster: roster, starters: starters)
            } catch {
                rosterFailures += 1
            }
        }
        guard rosterFailures == 0 else {
            // Roll back so the user gets a clean retry instead of a partial
            // league (and so retrying doesn't create a duplicate). Best-effort —
            // if the delete itself fails we still report the original problem.
            try? await remote.deleteLeague(league.id)
            throw AppError.promotionFailed("\(rosterFailures) team roster\(rosterFailures == 1 ? "" : "s")")
        }

        // Backfill prior seasons' final standings into history. Best-effort: the
        // league is fully playable without it, so a history-write hiccup must
        // never block (or undo) an otherwise-successful promotion. Any season
        // older than the live one is finished, so its standings are final.
        for season in imported.seasons where season.seasonYear < seasonYear {
            let standings = SleeperPromotion.standingsRows(for: season)
            guard !standings.isEmpty else { continue }
            let leaderName = season.standings.max(by: { $0.pointsFor < $1.pointsFor })?.teamName
            let champName = season.championRosterID.flatMap { season.teamsByRoster[$0]?.teamName }
            do {
                try await remote.archiveImportedSeason(
                    leagueID: league.id,
                    season: season.seasonYear,
                    standings: standings,
                    scoringLeaderTeamName: leaderName,
                    championTeamName: champName
                )
            } catch {
                // Non-fatal — the league is fully playable without backfilled
                // history. Log so a silent failure is still diagnosable rather
                // than surfacing as an unexplained empty History tab.
                #if DEBUG
                print("Sleeper history backfill failed for \(season.seasonYear): \(error)")
                #endif
            }
        }

        // Tag the local import as activated so the UI routes to the live league.
        if let idx = importedSleeperLeagues.firstIndex(where: { $0.id == importedID }) {
            importedSleeperLeagues[idx].activatedLeagueID = league.id
            SleeperStore.shared.saveAll(importedSleeperLeagues)
        }

        await reloadLeagues()
        await selectLeague(league.id)
        // selectLeague has already loaded the fully-populated league into
        // selectedLeague; callers here only need the id, so return the row
        // createLeague handed back.
        return league
    }

    // MARK: - League history (multi-season)

    // Snapshots the current standings + per-week matchups into the
    // league_seasons + league_matchups tables, then flips season_completed.
    // Commissioner-only (server enforces).
    @discardableResult
    func completeLeagueSeason(leagueID: String) async throws -> League? {
        guard let league = try await remote.league(id: leagueID) else { return nil }
        let snap = await loadSeason(league.season) ?? players(season: league.season)
        let standings = Fantasy.standings(league: league, players: snap)
        // Per-team season points (already computed in standings.pointsFor);
        // scoring leader = highest pointsFor.
        let leader = standings.max(by: { $0.pointsFor < $1.pointsFor })

        // Walk every scheduled week and snapshot the per-matchup scores.
        var archived: [LeagueMatchupArchive] = []
        for plan in league.schedule {
            let result = Fantasy.scoreboard(league: league, players: snap, week: plan.week)
            for m in result.matchups {
                let homeTeam = league.teams.first(where: { $0.id == m.home.teamID })
                let awayTeam = league.teams.first(where: { $0.id == m.away.teamID })
                archived.append(LeagueMatchupArchive(
                    week: plan.week,
                    homeTeamID: m.home.teamID,
                    awayTeamID: m.away.teamID,
                    homeUserID: homeTeam?.ownerID,
                    awayUserID: awayTeam?.ownerID,
                    homePoints: m.home.points,
                    awayPoints: m.away.points
                ))
            }
        }

        // Crown the playoff champion (winner of the final), when the bracket
        // has resolved. Falls back to nil if the postseason isn't finished.
        let bracket = Fantasy.playoffBracket(league: league, players: snap)

        let updated = try await remote.completeLeagueSeason(
            leagueID: league.id,
            standings: standings,
            scoringLeaderTeamID: leader?.id,
            scoringLeaderTeamName: leader?.name,
            matchups: archived,
            championTeamID: bracket.championTeamID,
            championTeamName: bracket.championTeamName
        )
        await reloadLeagues()
        return updated
    }

    @discardableResult
    func rolloverLeague(parentID: String, newSeason: Int, newName: String?) async throws -> League? {
        let lg = try await remote.rolloverLeague(parentID: parentID, newSeason: newSeason, newName: newName)
        await reloadLeagues()
        return lg
    }

    func leagueHistory(leagueID: String) async -> [LeagueSeasonArchive] {
        (try? await remote.leagueHistory(leagueID: leagueID)) ?? []
    }

    func headToHead(leagueID: String, meUserID: String, opponentUserID: String) async -> [HeadToHeadEntry] {
        (try? await remote.headToHead(
            leagueID: leagueID, meUserID: meUserID, opponentUserID: opponentUserID
        )) ?? []
    }

    // MARK: - Play-by-play

    func plays(gameID: String) async -> [Play] {
        await remote.plays(gameID: gameID)
    }

    // MARK: - League chat

    func leagueChat(leagueID: String, limit: Int = 200) async -> LeagueChatLoad {
        await remote.messages(leagueID: leagueID, limit: limit)
    }

    @discardableResult
    func sendLeagueMessage(
        leagueID: String, content: String, imageURL: String? = nil
    ) async throws -> LeagueMessage {
        guard let session else { throw AppError.notSignedIn }
        return try await remote.sendMessage(
            leagueID: leagueID, userID: session.userID,
            content: content, imageURL: imageURL
        )
    }

    func uploadChatImage(leagueID: String, data: Data, contentType: String) async throws -> String {
        try await remote.uploadChatImage(
            leagueID: leagueID, data: data, contentType: contentType
        )
    }

    func deleteLeagueMessage(id: String) async {
        try? await remote.deleteMessage(id: id)
    }

    @discardableResult
    func toggleReaction(messageID: String, emoji: String) async throws -> Bool {
        guard let session else { throw AppError.notSignedIn }
        return try await remote.toggleReaction(
            messageID: messageID, userID: session.userID, emoji: emoji
        )
    }

    @discardableResult
    func sendStructuredMessage(
        leagueID: String, kind: MessageKind, payload: ChatPayload
    ) async throws -> LeagueMessage {
        guard let session else { throw AppError.notSignedIn }
        return try await remote.sendStructuredMessage(
            leagueID: leagueID, userID: session.userID, kind: kind, payload: payload
        )
    }

    func respondToMessage(messageID: String, slot: Int, choice: Int) async throws {
        guard let session else { throw AppError.notSignedIn }
        try await remote.respond(
            messageID: messageID, userID: session.userID, slot: slot, choice: choice
        )
    }

    func clearResponse(messageID: String, slot: Int) async throws {
        guard let session else { throw AppError.notSignedIn }
        try await remote.clearResponse(
            messageID: messageID, userID: session.userID, slot: slot
        )
    }

    func addPollOption(messageID: String, option: String) async throws {
        guard session != nil else { throw AppError.notSignedIn }
        try await remote.appendPollOption(messageID: messageID, option: option)
    }

    // MARK: - Friends + DMs

    func profile(userID: String) async -> Profile? {
        await remote.profile(userID: userID)
    }

    // Username substring search, used by the Find People sheet. Excludes
    // self automatically. View owns the result list — this is just a
    // passthrough so the view never reaches into RemoteService directly.
    func searchUsers(query: String, limit: Int = 25) async -> [Profile] {
        guard let me = session?.userID else { return [] }
        return await remote.searchUsers(query: query, excludingUserID: me, limit: limit)
    }

    func reloadFriendsAndDMs() async {
        guard let session else {
            friendships = []
            dmInbox = []
            return
        }
        async let f = remote.friendships(userID: session.userID)
        async let d = remote.dmInbox(userID: session.userID)
        friendships = await f
        dmInbox = await d
    }

    // Convenience projection: what's the friendship status between me and
    // another user, derived from the cached friendships list.
    func friendshipStatus(otherUserID: String) -> FriendshipStatus {
        guard let me = session?.userID else { return .none }
        guard let f = friendships.first(where: {
            $0.userA == otherUserID || $0.userB == otherUserID
        }) else { return .none }
        switch f.state {
        case .accepted: return .friends
        case .pending:
            return f.requestedBy == me ? .requestSent : .requestReceived
        }
    }

    @discardableResult
    func sendFriendRequest(toUserID otherUserID: String) async throws -> Friendship {
        let f = try await remote.sendFriendRequest(otherUserID: otherUserID)
        await reloadFriendsAndDMs()
        return f
    }

    @discardableResult
    func acceptFriendRequest(fromUserID otherUserID: String) async throws -> Friendship {
        let f = try await remote.acceptFriendRequest(otherUserID: otherUserID)
        await reloadFriendsAndDMs()
        return f
    }

    func removeFriendship(withUserID otherUserID: String) async throws {
        guard let session else { throw AppError.notSignedIn }
        try await remote.removeFriendship(
            otherUserID: otherUserID, meUserID: session.userID
        )
        await reloadFriendsAndDMs()
    }

    @discardableResult
    func openDMThread(withUserID otherUserID: String) async throws -> DMThread {
        let thread = try await remote.getOrCreateDMThread(otherUserID: otherUserID)
        await reloadFriendsAndDMs()
        return thread
    }

    func dmMessages(threadID: String, limit: Int = 200) async -> [DMMessage] {
        await remote.dmMessages(threadID: threadID, limit: limit)
    }

    @discardableResult
    func sendDMMessage(
        threadID: String, content: String, imageURL: String? = nil
    ) async throws -> DMMessage {
        guard let session else { throw AppError.notSignedIn }
        let msg = try await remote.sendDMMessage(
            threadID: threadID, senderID: session.userID,
            content: content, imageURL: imageURL
        )
        // Keep the inbox's last-message ordering fresh.
        await reloadFriendsAndDMs()
        return msg
    }

    func deleteDMMessage(id: String) async {
        try? await remote.deleteDMMessage(id: id)
    }

    func uploadDMImage(threadID: String, data: Data, contentType: String) async throws -> String {
        try await remote.uploadDMImage(
            threadID: threadID, data: data, contentType: contentType
        )
    }

    func league(_ id: String) async -> League? {
        (try? await remote.league(id: id)) ?? nil
    }

    func lookupLeague(byCode code: String) async throws -> League? {
        try await remote.leagueByCode(code)
    }

    /// Handles an opened invite link: stashes the code and routes to the
    /// Leagues tab so the join sheet can surface it.
    func handleInvite(url: URL) {
        guard let code = JoinLink.code(from: url) else { return }
        pendingJoinCode = code
        // Surface the overview (join sheet lives there) so the code can be used.
        selectedLeagueID = nil
        selectedLeague = nil
    }

    func claimTeam(teamID: String) async throws -> League? {
        guard let session else { throw AppError.notSignedIn }
        let updated = try await remote.claimTeam(teamID: teamID, userID: session.userID)
        await reloadLeagues()
        return updated
    }

    // MARK: - Waivers / free agency

    func droppedPlayers(leagueID: String) async -> [DroppedPlayer] {
        (try? await remote.droppedPlayers(leagueID: leagueID)) ?? []
    }

    func waiverClaims(leagueID: String) async -> [WaiverClaim] {
        (try? await remote.waiverClaims(leagueID: leagueID)) ?? []
    }

    func transactions(leagueID: String) async -> [LeagueTransaction] {
        (try? await remote.transactions(leagueID: leagueID, limit: 100)) ?? []
    }

    func addFreeAgent(
        league: League, team: FantasyTeam,
        addPlayerID: String, dropPlayerID: String?
    ) async throws -> League? {
        let updated = try await remote.addFreeAgent(
            league: league, team: team,
            addPlayerID: addPlayerID, dropPlayerID: dropPlayerID
        )
        await refreshSelectedNicknames()
        return updated
    }

    func dropPlayer(league: League, team: FantasyTeam, playerID: String) async throws -> League? {
        let updated = try await remote.dropPlayer(league: league, team: team, playerID: playerID)
        await refreshSelectedNicknames()
        return updated
    }

    @discardableResult
    func submitWaiverClaim(
        leagueID: String, teamID: String,
        addPlayerID: String, dropPlayerID: String?
    ) async throws -> WaiverClaim? {
        try await remote.submitWaiverClaim(
            leagueID: leagueID, teamID: teamID,
            addPlayerID: addPlayerID, dropPlayerID: dropPlayerID
        )
    }

    func cancelWaiverClaim(_ id: String) async throws {
        try await remote.cancelWaiverClaim(id)
    }

    func reorderWaiverClaims(teamID: String, claimIDsInOrder: [String]) async throws {
        try await remote.reorderWaiverClaims(teamID: teamID, claimIDsInOrder: claimIDsInOrder)
    }

    @discardableResult
    func approveTransaction(_ txID: String) async throws -> League? {
        guard let session else { throw AppError.notSignedIn }
        let updated = try await remote.approveTransaction(txID, commissionerID: session.userID)
        await refreshSelectedNicknames()
        return updated
    }

    func rejectTransaction(_ txID: String, note: String? = nil) async throws {
        guard let session else { throw AppError.notSignedIn }
        try await remote.rejectTransaction(txID, commissionerID: session.userID, note: note)
    }

    @discardableResult
    func updateWaiverSettings(
        leagueID: String, settings: WaiverSettings, priority: [String]
    ) async throws -> League? {
        try await remote.updateWaiverSettings(
            leagueID: leagueID, settings: settings, priority: priority
        )
    }

    @discardableResult
    func updateLeague(
        leagueID: String, name: String, scoring: Scoring, rosterConfig: RosterConfig,
        playoffTeams: Int, playoffReseed: Bool,
        scoringSettings: ScoringSettings?, divisionNames: [String],
        regularSeasonWeeks: Int, weeksPerRound: Int, schedule: [ScheduleWeek]
    ) async throws -> League? {
        let updated = try await remote.updateLeague(
            leagueID: leagueID, name: name, scoring: scoring, rosterConfig: rosterConfig,
            playoffTeams: playoffTeams, playoffReseed: playoffReseed,
            scoringSettings: scoringSettings, divisionNames: divisionNames,
            regularSeasonWeeks: regularSeasonWeeks, weeksPerRound: weeksPerRound,
            schedule: schedule
        )
        await reloadLeagues()
        return updated
    }

    // Persist a manually-set lineup (start/sit) and IR list for a specific
    // week. Freezes that week's lineup so future edits don't rewrite it, and
    // updates the live default lineup to match the latest edit.
    @discardableResult
    func setLineup(
        team: FantasyTeam, week: Int, starters: [String], ir: [String], taxi: [String]
    ) async throws -> League? {
        var weekly = team.weeklyLineups
        weekly[week] = starters
        return try await remote.setLineup(
            teamID: team.id, starters: starters, ir: ir, taxi: taxi, weeklyLineups: weekly
        )
    }

    @discardableResult
    func setTeamCustomization(
        teamID: String, name: String?, logoURL: String?, colorHex: String?,
        abbreviation: String?
    ) async throws -> League? {
        let updated = try await remote.setTeamCustomization(
            teamID: teamID, name: name, logoURL: logoURL, colorHex: colorHex,
            abbreviation: abbreviation
        )
        await reloadLeagues()
        return updated
    }

    // MARK: - Player nicknames

    // Active nicknames for the currently-viewed league, keyed teamID →
    // (playerID → nickname). Populated by loadLeagueNicknames when a league
    // view opens; views read it synchronously to relabel rostered players.
    var leagueNicknames: [String: [String: String]] = [:]

    func loadLeagueNicknames(leagueID: String) async {
        leagueNicknames = await remote.leagueNicknames(leagueID: leagueID)
    }

    // Refresh the per-roster team-meta caches (nicknames + values) for the
    // focused league after a roster change. The DB triggers reconcile both
    // server-side the moment a player leaves a roster, so without this the
    // caches would keep serving stale entries for dropped (and possibly
    // re-added) players until the next full league load — breaking the
    // "reset on drop" behavior in-session.
    func refreshSelectedNicknames() async {
        guard let id = selectedLeagueID else { return }
        await loadLeagueNicknames(leagueID: id)
        await loadLeagueValues(leagueID: id)
    }

    // The nickname a team has given a player on its roster, or nil.
    func nickname(teamID: String, playerID: String) -> String? {
        leagueNicknames[teamID]?[playerID]
    }

    // What to display for a player on a given team: the nickname if set,
    // otherwise the supplied real name.
    func displayName(teamID: String, playerID: String, realName: String) -> String {
        nickname(teamID: teamID, playerID: playerID) ?? realName
    }

    @discardableResult
    func setPlayerNickname(
        leagueID: String, teamID: String, playerID: String, nickname: String
    ) async throws -> League? {
        try await remote.setPlayerNickname(
            teamID: teamID, playerID: playerID, nickname: nickname
        )
        await loadLeagueNicknames(leagueID: leagueID)
        return try await remote.league(id: leagueID)
    }

    func playerNicknameHistory(playerID: String) async -> [NicknameHistoryEntry] {
        await remote.playerNicknameHistory(playerID: playerID)
    }

    // MARK: - Player values

    // Owner-assigned player value ratings for the currently-viewed league,
    // keyed teamID → (playerID → value). Loaded alongside nicknames when a
    // league is focused; refreshed on every roster change so a dropped
    // player's value isn't served stale.
    var leagueValues: [String: [String: PlayerValue]] = [:]

    func loadLeagueValues(leagueID: String) async {
        leagueValues = await remote.leagueValues(leagueID: leagueID)
    }

    func refreshSelectedValues() async {
        guard let id = selectedLeagueID else { return }
        await loadLeagueValues(leagueID: id)
    }

    // The value a team has set on a player on its roster, or nil.
    func playerValue(teamID: String, playerID: String) -> PlayerValue? {
        leagueValues[teamID]?[playerID]
    }

    // The owning team's value for a player in the selected league (whichever
    // team rosters them). Nil when the player is unrostered or unrated.
    func playerValue(playerID: String) -> PlayerValue? {
        guard let lg = selectedLeague,
              let team = lg.teams.first(where: { $0.roster.contains(playerID) })
        else { return nil }
        return playerValue(teamID: team.id, playerID: playerID)
    }

    @discardableResult
    func setPlayerValue(
        leagueID: String, teamID: String, playerID: String, value: PlayerValue?
    ) async throws -> League? {
        try await remote.setPlayerValue(
            teamID: teamID, playerID: playerID, value: value
        )
        await loadLeagueValues(leagueID: leagueID)
        return try await remote.league(id: leagueID)
    }

    // Full career injury history for one player, collapsed into distinct events
    // (newest first). Season-independent — covers every season on file.
    func injuryHistory(playerID: String) async -> [InjuryEvent] {
        let rows = await remote.injuryHistory(playerID: playerID)
        return Fantasy.injuryEvents(from: rows)
    }

    @discardableResult
    func setTeamDivision(teamID: String, division: Int?) async throws -> League? {
        try await remote.setTeamDivision(teamID: teamID, division: division)
    }

    func uploadTeamLogo(leagueID: String, data: Data, contentType: String) async throws -> String {
        // Reuses the chat-images bucket (same per-league storage RLS).
        try await remote.uploadChatImage(leagueID: leagueID, data: data, contentType: contentType)
    }

    @discardableResult
    func renameTeam(teamID: String, name: String) async throws -> League? {
        try await remote.renameTeam(teamID: teamID, name: name)
    }

    @discardableResult
    func kickTeamOwner(teamID: String) async throws -> League? {
        try await remote.kickTeamOwner(teamID: teamID)
    }

    // MARK: - Trades

    func trades(leagueID: String) async -> [Trade] {
        (try? await remote.trades(leagueID: leagueID)) ?? []
    }

    func tradeVotes(tradeID: String) async -> [TradeVote] {
        (try? await remote.tradeVotes(tradeID: tradeID)) ?? []
    }

    @discardableResult
    func proposeTrade(
        leagueID: String, proposerTeamID: String, recipientTeamID: String,
        proposerPlayerIDs: [String], recipientPlayerIDs: [String],
        note: String?, parentTradeID: String? = nil
    ) async throws -> Trade? {
        try await remote.proposeTrade(
            leagueID: leagueID,
            proposerTeamID: proposerTeamID, recipientTeamID: recipientTeamID,
            proposerPlayerIDs: proposerPlayerIDs,
            recipientPlayerIDs: recipientPlayerIDs,
            note: note, parentTradeID: parentTradeID
        )
    }

    @discardableResult
    func acceptTrade(_ tradeID: String) async throws -> Trade? {
        let trade = try await remote.acceptTrade(tradeID)
        await refreshSelectedNicknames()
        return trade
    }

    @discardableResult
    func rejectTrade(_ tradeID: String) async throws -> Trade? {
        try await remote.rejectTrade(tradeID)
    }

    @discardableResult
    func cancelTrade(_ tradeID: String) async throws -> Trade? {
        try await remote.cancelTrade(tradeID)
    }

    @discardableResult
    func commishResolveTrade(_ tradeID: String, approve: Bool, note: String?) async throws -> Trade? {
        let trade = try await remote.commishResolveTrade(tradeID, approve: approve, note: note)
        await refreshSelectedNicknames()
        return trade
    }

    @discardableResult
    func voteTrade(_ tradeID: String, vote: String) async throws -> Trade? {
        let trade = try await remote.voteTrade(tradeID, vote: vote)
        await refreshSelectedNicknames()
        return trade
    }

    @discardableResult
    func updateTradeSettings(leagueID: String, settings: TradeSettings) async throws -> League? {
        try await remote.updateTradeSettings(leagueID: leagueID, settings: settings)
    }

    // MARK: - Draft

    func draft(leagueID: String) async -> Draft? {
        (try? await remote.draft(leagueID: leagueID)) ?? nil
    }

    func draftPicks(draftID: String) async -> [DraftPick] {
        (try? await remote.draftPicks(draftID: draftID)) ?? []
    }

    @discardableResult
    func upsertDraft(
        leagueID: String, format: DraftFormat, pickSeconds: Int,
        startsAt: Date, pickOrder: [String], rosterSize: Int
    ) async throws -> Draft? {
        try await remote.upsertDraft(
            leagueID: leagueID, format: format, pickSeconds: pickSeconds,
            startsAt: startsAt, pickOrder: pickOrder, rosterSize: rosterSize
        )
    }

    @discardableResult
    func startDraft(draftID: String) async throws -> Draft? {
        try await remote.startDraft(draftID: draftID)
    }

    @discardableResult
    func pauseDraft(draftID: String) async throws -> Draft? {
        try await remote.pauseDraft(draftID: draftID)
    }

    @discardableResult
    func resumeDraft(draftID: String) async throws -> Draft? {
        try await remote.resumeDraft(draftID: draftID)
    }

    @discardableResult
    func makePick(draftID: String, teamID: String, playerID: String) async throws -> Draft? {
        try await remote.makePick(draftID: draftID, teamID: teamID, playerID: playerID, auto: false)
    }

    @discardableResult
    func setAutoPick(draftID: String, teamID: String, enabled: Bool) async throws -> Draft? {
        try await remote.setAutoPick(draftID: draftID, teamID: teamID, enabled: enabled)
    }

    // MARK: - Draft queue

    func draftQueue(draftID: String, teamID: String) async -> [String] {
        await remote.draftQueue(draftID: draftID, teamID: teamID)
    }

    func queueAdd(draftID: String, teamID: String, playerID: String) async throws {
        try await remote.queueAdd(draftID: draftID, teamID: teamID, playerID: playerID)
    }

    func queueRemove(draftID: String, teamID: String, playerID: String) async throws {
        try await remote.queueRemove(draftID: draftID, teamID: teamID, playerID: playerID)
    }

    func queueReorder(draftID: String, teamID: String, playerIDs: [String]) async throws {
        try await remote.queueReorder(draftID: draftID, teamID: teamID, playerIDs: playerIDs)
    }

    // Client-side auto-pick on timer expiry. Picks position-aware best
    // available, then locks the team into auto-pick mode so they keep
    // drafting on their own until they manually toggle off. Idempotent —
    // if another client already advanced the pick, make_pick fails on the
    // unique constraint and the call returns nil.
    @discardableResult
    func autoPickIfExpired(draft: Draft, league: League?, players: [String: Player]) async -> Draft? {
        guard draft.status == .live,
              let deadline = draft.pickDeadline,
              deadline <= Date() else { return nil }
        return await performAutoPick(draft: draft, league: league, players: players, lockIntoAuto: true)
    }

    // Voluntary auto-pick: fires when a team in auto_pick_team_ids is on
    // the clock. Doesn't re-lock (they're already in the list).
    @discardableResult
    func autoPickForOnClockAutoTeam(draft: Draft, league: League?, players: [String: Player]) async -> Draft? {
        guard draft.status == .live,
              let teamID = draft.teamOnClock(forPick: draft.currentPick),
              draft.isOnAutoPick(teamID: teamID) else { return nil }
        return await performAutoPick(draft: draft, league: league, players: players, lockIntoAuto: false)
    }

    private func performAutoPick(
        draft: Draft, league: League?, players: [String: Player], lockIntoAuto: Bool
    ) async -> Draft? {
        guard let teamID = draft.teamOnClock(forPick: draft.currentPick) else { return nil }
        let pickedIDs = await draftedPlayerIDs(draftID: draft.id)
        // Use the league snapshot to know what's on the team (in case the
        // cached league.teams.roster lags behind the latest picks). The most
        // accurate roster is the picks-so-far filtered by this team_id.
        let teamPicks = await draftPicks(draftID: draft.id)
            .filter { $0.teamID == teamID }
            .map(\.playerID)
        let team = FantasyTeam(id: teamID, name: "", roster: teamPicks)
        let config = league?.rosterConfig ?? .default
        let scoring = league?.scoring ?? .ppr
        // Queue strictly wins: if the team owner queued players, the first
        // still-available queued player is picked, ignoring the 7-pick-loop
        // template entirely. Falls through to the loop strategy only when
        // the queue is empty (or all queued players are already drafted).
        var chosenID: String? = nil
        let queued = await remote.draftQueue(draftID: draft.id, teamID: teamID)
        for pid in queued where !pickedIDs.contains(pid) && players[pid] != nil {
            chosenID = pid
            break
        }

        if chosenID == nil {
            // Use point-in-time ADP for simulation drafts (what real managers
            // had at draft time), current ADP for live real-league drafts.
            let adp: [String: Double]
            if let lg = league {
                adp = lg.isTest
                    ? await adpForSimulation(season: lg.season, scoring: lg.scoring)
                    : await self.adp(season: lg.season, scoring: lg.scoring)
            } else {
                adp = [:]
            }
            chosenID = Fantasy.bestAutoPickPlayerID(
                team: team, players: players, pickedPlayerIDs: pickedIDs,
                config: config, scoring: scoring, adp: adp
            )
        }
        guard let pid = chosenID else { return nil }
        let updated = try? await remote.makePick(
            draftID: draft.id, teamID: teamID, playerID: pid, auto: true
        )
        if lockIntoAuto, updated != nil {
            _ = try? await remote.setAutoPick(draftID: draft.id, teamID: teamID, enabled: true)
        }
        return updated
    }

    private func draftedPlayerIDs(draftID: String) async -> Set<String> {
        let picks = await draftPicks(draftID: draftID)
        return Set(picks.map(\.playerID))
    }

    // MARK: - Admin

    var isAdmin: Bool {
        guard let profile = session?.profile else { return false }
        // DB-driven flag is authoritative; the hard-coded allowlist remains a
        // fallback for accounts whose is_admin column hasn't been seeded.
        return profile.isAdmin
            || AdminConfig.adminUsernames.contains(profile.username.lowercased())
    }

    // Testers (and admins) get the floating feedback button.
    var isTester: Bool { session?.profile.isTester == true }
    var canGiveFeedback: Bool { isAdmin || isTester }

    // MARK: - Tester role + feedback

    @discardableResult
    func setTesterRole(userID: String, isTester: Bool) async throws -> Bool {
        try await remote.setTesterRole(userID: userID, isTester: isTester)
    }

    @discardableResult
    func setAdminRole(userID: String, isAdmin: Bool) async throws -> Bool {
        try await remote.setAdminRole(userID: userID, isAdmin: isAdmin)
    }

    func uploadFeedbackImage(data: Data, contentType: String) async throws -> String {
        guard let session else { throw AppError.notSignedIn }
        return try await remote.uploadFeedbackImage(
            userID: session.userID, data: data, contentType: contentType
        )
    }

    @discardableResult
    func submitFeedback(content: String, imageURLs: [String]) async throws -> FeedbackItem {
        guard let session else { throw AppError.notSignedIn }
        return try await remote.submitFeedback(
            userID: session.userID, content: content, imageURLs: imageURLs
        )
    }

    // Review list. Server RLS returns every item to admins and only the
    // caller's own items to non-admin testers, so the same call powers both
    // the admin triage inbox and a tester's "my feedback" view.
    func feedbackInbox() async -> [FeedbackItem] {
        guard canGiveFeedback else { return [] }
        return await remote.feedbackInbox()
    }

    @discardableResult
    func setFeedbackStatus(id: String, status: FeedbackStatus) async throws -> Bool {
        try await remote.setFeedbackStatus(id: id, status: status)
    }

    func feedbackComments(feedbackID: String) async -> [FeedbackComment] {
        await remote.feedbackComments(feedbackID: feedbackID)
    }

    @discardableResult
    func addFeedbackComment(feedbackID: String, content: String) async throws -> FeedbackComment {
        guard let session else { throw AppError.notSignedIn }
        return try await remote.addFeedbackComment(
            feedbackID: feedbackID, userID: session.userID, content: content
        )
    }

    // MARK: - Push notifications

    // Prompt for permission (once) and register/refresh this device's token.
    // Called after sign-in and on each bootstrap when a session exists.
    func setUpPushNotifications() async {
        guard session != nil else { return }
        await NotificationManager.shared.requestAuthorization()
        await NotificationManager.shared.uploadTokenIfPossible()
    }

    private func handlePushDeepLink(_ url: URL?) {
        guard let url else { return }
        // tarsafantasy://lineup → jump to the Lineup tab of the current league.
        if url.host == "lineup", selectedLeagueID != nil {
            tab = .lineup
        }
    }

    func uploadNotificationImage(data: Data, contentType: String) async throws -> String {
        guard isAdmin else { throw AppError.notAuthorized }
        return try await remote.uploadNotificationImage(data: data, contentType: contentType)
    }

    func deleteNotificationImage(urlString: String) async {
        await remote.deleteNotificationImage(urlString: urlString)
    }

    @discardableResult
    func sendNotification(
        title: String, body: String, imageURL: String?, deepLink: String?,
        targetUserIDs: [String]?, scheduledAt: Date?
    ) async throws -> AdminNotification {
        guard isAdmin else { throw AppError.notAuthorized }
        return try await remote.createNotification(
            title: title, body: body, imageURL: imageURL, deepLink: deepLink,
            targetUserIDs: targetUserIDs, scheduledAt: scheduledAt
        )
    }

    func adminNotifications() async -> [AdminNotification] {
        guard isAdmin else { return [] }
        return await remote.adminNotifications()
    }

    func cancelNotification(id: String) async throws {
        guard isAdmin else { return }
        try await remote.cancelNotification(id: id)
    }

    // MARK: - Simulations

    enum SimulationDraftMode { case preDrafted, liveDraft }

    // Convention: in a simulation, the user's "primary" team is the one
    // whose name doesn't match the auto-generated bot pattern. Every team
    // is owned by the creator so we can't disambiguate by owner_id.
    static func primaryTeamID(in league: League) -> String? {
        league.teams.first(where: { !$0.name.hasPrefix("Bot ") })?.id
            ?? league.teams.first?.id
    }

    // Create a Simulation league: 1 user team + N bots, all owned by the
    // creator so they can be acted on through the normal RPCs.
    @discardableResult
    func createSimulation(
        name: String,
        season: Int,
        scoring: Scoring,
        rosterConfig: RosterConfig = .default,
        yourTeamName: String,
        mode: SimulationDraftMode = .preDrafted,
        botCount: Int,
        scoringSettings: ScoringSettings? = nil
    ) async throws -> League {
        guard let session else { throw AppError.notSignedIn }
        let bots = max(1, botCount)
        let otherNames = (1...bots).map { "Bot \($0)" }
        let league = try await remote.createLeague(
            creatorID: session.userID,
            name: name,
            season: season,
            scoring: scoring,
            rosterConfig: rosterConfig,
            yourTeamName: yourTeamName,
            otherTeamNames: otherNames,
            scoringSettings: scoringSettings
        )
        // Flip is_test + clear deadline; the row is otherwise normal.
        try await remote.markAsTestLeague(leagueID: league.id)

        // Every bot team's owner_id = creator's UID so they can act on
        // their behalf through the normal RLS-protected RPCs.
        for team in league.teams where team.ownerID == nil {
            _ = try await remote.claimTeam(teamID: team.id, userID: session.userID)
        }

        // Make sure we have the data season loaded before drafting.
        let seasonPlayers = await loadSeason(league.season) ?? players(season: league.season)

        switch mode {
        case .preDrafted:
            // Point-in-time ADP — the rankings a real manager would have
            // had when drafting this season, not season-aggregate hindsight.
            let adp = await adpForSimulation(season: league.season, scoring: league.scoring)
            let drafted = Fantasy.draftRosters(
                players: seasonPlayers, teamCount: league.teams.count,
                config: league.rosterConfig, scoring: league.scoring,
                adp: adp
            )
            for (idx, team) in league.teams.enumerated() {
                let roster = drafted[idx]
                let lineup = Fantasy.autoFillLineup(
                    roster: roster, players: seasonPlayers,
                    config: league.rosterConfig, scoring: league.scoring
                )
                _ = try await remote.setRoster(
                    teamID: team.id, roster: roster, starters: lineup
                )
            }
            // Capture the pristine week-0 entry state so reset_all can
            // restore it later.
            try await remote.snapshotTeams(leagueID: league.id, week: 0)
        case .liveDraft:
            // Schedule a draft starting in 30s with a short pick clock
            // so the user can walk through the full draft room flow.
            let pickOrder = league.teams.map(\.id).shuffled()
            _ = try await remote.upsertDraft(
                leagueID: league.id,
                format: .snake,
                pickSeconds: 20,
                startsAt: Date().addingTimeInterval(30),
                pickOrder: pickOrder,
                rosterSize: league.rosterConfig.totalSize
            )
            // Snapshot the empty-roster entry state so reset_all has
            // something to restore to. Without this, a live-draft sim
            // couldn't be wound back: reset would leave rosters wherever
            // they were at reset-time even though the picks get deleted
            // and the draft re-scheduled.
            try await remote.snapshotTeams(leagueID: league.id, week: 0)
        }
        await reloadLeagues()
        await selectLeague(league.id)
        return league
    }

    // MARK: - Simulation: time travel + bot orchestration

    @discardableResult
    func advanceSimulatedWeek(leagueID: String, delta: Int) async throws -> League? {
        guard let lg = try await remote.league(id: leagueID), lg.isTest else { return nil }
        let scheduleLen = lg.schedule.count
        let current = lg.simulatedWeek ?? 0
        // Phases: 0 = pre, 1...scheduleLen = regular weeks, scheduleLen+1 = post.
        let next = max(0, min(scheduleLen + 1, current + delta))
        let updated = try await remote.setSimulatedWeek(leagueID: leagueID, week: next)
        // Capture the entry state of the new week so reset_period can rewind
        // back to it. Snapshot is a no-op if one already exists (jumping back
        // and forward shouldn't clobber the original entry).
        if let updated, delta > 0 {
            try? await remote.snapshotTeams(leagueID: leagueID, week: next)
            await runAutoProcessing(league: updated)
        }
        await refreshSelectedNicknames()
        return updated
    }

    @discardableResult
    func resetCurrentPeriod(leagueID: String) async -> League? {
        let updated = (try? await remote.resetPeriod(leagueID: leagueID)) ?? nil
        await refreshSelectedNicknames()
        return updated
    }

    @discardableResult
    func resetAll(leagueID: String) async -> League? {
        let updated = (try? await remote.resetAll(leagueID: leagueID)) ?? nil
        await refreshSelectedNicknames()
        return updated
    }

    private func runAutoProcessing(league: League) async {
        // Process waivers: re-use the regular waiver flow by simulating the
        // tick. We don't have a "force run" RPC, so for each pending claim
        // resolve it directly via processClaim — the existing
        // process_waivers function is a cron-only Edge Function. For v1 we
        // approximate by walking the pending list and using the same logic
        // the server uses. Trades have attempt_execute_trade callable per id.
        let pendingTrades = await trades(leagueID: league.id)
            .filter { $0.status == .pendingExecution }
        for t in pendingTrades {
            _ = try? await remote.callTradeRetry(tradeID: t.id)
        }
        // Pending waiver claims: simplest path is to leave them alone (the
        // hourly cron handles them). Surfacing a "Run waivers now" button is
        // a separate piece of work.
    }

    // Generate one round of bot moves and execute each in sequence.
    func runBotActivity(league: League) async {
        guard league.isTest, let session else { return }
        // Refresh the league + players snapshot so the bot's view of the
        // world is up to date.
        guard let fresh = try? await remote.league(id: league.id) else { return }
        let primary = Self.primaryTeamID(in: fresh) ?? ""
        let snapshot = players(season: fresh.season)
        let clamped: [String: Player]
        if let week = fresh.simulatedWeek, week > 0 {
            clamped = Fantasy.clamped(snapshot, upTo: week)
        } else {
            clamped = snapshot
        }
        let dropped = await droppedPlayers(leagueID: fresh.id)
        let onWaivers = Set(dropped.filter(\.isOnWaivers).map(\.playerID))

        // Historical context — both empty/no-ops in real leagues. In a sim
        // these pull from trending_history / inactives for the simulated week.
        let week = fresh.simulatedWeek ?? 0
        var trendingAdds: [String: Double] = [:]
        var inactiveSet: Set<String> = []
        if fresh.isTest, week > 0 {
            for t in await remote.trendingPlayers(season: fresh.season, week: week) {
                trendingAdds[t.playerID] = t.adds
            }
            inactiveSet = await data.inactives(season: fresh.season, week: week)
        }

        var rng = SystemRandomNumberGenerator()
        let moves = BotAI.weeklyMoves(
            league: fresh, adminTeamID: primary, players: clamped,
            onWaivers: onWaivers, upToWeek: week,
            trendingAdds: trendingAdds, inactives: inactiveSet, rng: &rng
        )
        for move in moves {
            try? await execute(move: move, in: fresh, session: session)
        }
        await refreshSelectedNicknames()
    }

    private func execute(move: BotMove, in league: League, session: Session) async throws {
        switch move {
        case let .addDrop(teamID, addPlayerID, dropPlayerID):
            guard let team = league.teams.first(where: { $0.id == teamID }) else { return }
            _ = try await remote.addFreeAgent(
                league: league, team: team,
                addPlayerID: addPlayerID, dropPlayerID: dropPlayerID
            )
        case let .waiverClaim(teamID, addPlayerID, dropPlayerID):
            _ = try await remote.submitWaiverClaim(
                leagueID: league.id, teamID: teamID,
                addPlayerID: addPlayerID, dropPlayerID: dropPlayerID
            )
        case let .proposeTrade(fromTeamID, toTeamID, sendIDs, requestIDs):
            _ = try await remote.proposeTrade(
                leagueID: league.id,
                proposerTeamID: fromTeamID, recipientTeamID: toTeamID,
                proposerPlayerIDs: sendIDs, recipientPlayerIDs: requestIDs,
                note: "Bot offer", parentTradeID: nil
            )
        }
    }

    // MARK: - Previews

    static var preview: AppState {
        let state = AppState()
        state.seasons = [2025, 2024, 2023]
        state.selectedSeason = 2025
        return state
    }

    enum AppError: LocalizedError {
        case notSignedIn, leagueNotFound, notAuthorized
        case promotionFailed(String)
        var errorDescription: String? {
            switch self {
            case .notSignedIn:    return "You're not signed in."
            case .leagueNotFound: return "League not found."
            case .notAuthorized:  return "You don't have permission to do that."
            case .promotionFailed(let what):
                return "Couldn't finish setting up the league (\(what) failed). Nothing was kept — please try again."
            }
        }
    }
}
