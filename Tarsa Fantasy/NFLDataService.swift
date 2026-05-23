import Foundation
import Supabase

// Reads cached NFL data from Supabase (populated by the sync_nflverse and
// sync_espn_live Edge Functions). Replaces the prior on-device CSV download
// from nflverse. Live in-game scoring is layered in via a realtime
// subscription on the `live_scores` table.

actor NFLDataService {

    static let shared = NFLDataService()

    private let client: SupabaseClient
    private var seasonsCache: [Int]? = nil
    private var playersBySeason: [Int: [String: Player]] = [:]
    private var schedulesBySeason: [Int: [NFLGame]] = [:]
    private var snapsBySeason: [Int: [String: [Int: SnapCount]]] = [:]
    private var teamsCache: [NFLTeamMeta]? = nil
    // Cache: [season: [positionUpper: [team: DvPEntry]]]
    private var dvpCache: [Int: [String: [String: DvPEntry]]] = [:]
    // Cache: [season: [scoring: [playerID: adp]]]
    private var adpCache: [Int: [String: [String: Double]]] = [:]

    // Per-(player, season, week) live override pushed via Realtime. Read at
    // display time and OR-merged into the stored game points.
    private var liveOverrides: [LiveKey: LiveOverride] = [:]
    private var liveListenerTask: Task<Void, Never>? = nil

    struct LiveKey: Hashable { let playerID: String; let season: Int; let week: Int }
    struct LiveOverride {
        let standard: Double
        let ppr: Double
        let halfPpr: Double
        let isFinal: Bool
    }

    init() {
        client = SupabaseConfig.sharedClient
    }

    // MARK: - Public API (preserves the surface AppState already uses)

    func availableSeasons() async -> [Int] {
        if let cached = seasonsCache { return cached }
        do {
            struct Row: Decodable { let season: Int }
            // `available_seasons` is a view: the union of seasons that have
            // player stats (the `seasons` table) and seasons that only have a
            // schedule so far (distinct seasons in `nfl_schedules`). The latter
            // surfaces an upcoming season for draft/league setup the moment its
            // schedule is synced, before any games are played.
            let rows: [Row] = try await client.from("available_seasons")
                .select("season")
                .order("season", ascending: false)
                .execute().value
            let seasons = rows.map(\.season)
            seasonsCache = seasons
            return seasons
        } catch {
            return []
        }
    }

    func players(season: Int, forceRefresh: Bool = false) async throws -> [String: Player] {
        if !forceRefresh, let cached = playersBySeason[season] { return cached }
        // Pull players_cache + player_games filtered to this season.
        let players = try await fetchPlayers(season: season)
        let games = try await fetchGames(season: season)
        var assembled: [String: Player] = [:]
        for p in players {
            var profile = PlayerProfile()
            profile.birthDate    = parseDate(p.birthDate)
            profile.heightInches = p.heightIn
            profile.weightLb     = p.weightLb
            profile.college      = p.college
            profile.jerseyNumber = p.jerseyNumber
            profile.draftYear    = p.draftYear
            profile.draftRound   = p.draftRound
            profile.draftPick    = p.draftPick
            profile.yearsExp     = p.yearsExp
            profile.status       = p.status
            profile.byeWeek      = p.byeWeek
            assembled[p.id] = Player(
                id: p.id, name: p.name,
                position: p.position, positionGroup: p.positionGroup,
                headshotURL: p.headshotURL, team: p.team,
                games: [],
                profile: profile
            )
        }
        for g in games {
            guard assembled[g.playerID] != nil else { continue }
            assembled[g.playerID]!.games.append(Game(
                season: g.season, week: g.week,
                team: g.team, opponent: g.opponent,
                completions: g.completions, attempts: g.attempts,
                passingYards: g.passingYards, passingTDs: g.passingTDs,
                passingInterceptions: g.passingInterceptions,
                carries: g.carries, rushingYards: g.rushingYards, rushingTDs: g.rushingTDs,
                receptions: g.receptions, targets: g.targets,
                receivingYards: g.receivingYards, receivingTDs: g.receivingTDs,
                fumblesLost: g.fumblesLost,
                fantasyPoints: g.fantasyPoints,
                fantasyPointsPPR: g.fantasyPointsPPR,
                fantasyPointsHalfPPR: g.fantasyPointsHalfPPR
            ))
        }
        for pid in assembled.keys {
            assembled[pid]!.games.sort { $0.week < $1.week }
        }
        // Layer in any live overrides that arrived before this season was fetched.
        applyAllLiveOverrides(to: &assembled, season: season)
        playersBySeason[season] = assembled
        return assembled
    }

    // Populate the in-memory cache from an already-assembled snapshot (the
    // disk cache loaded by AppState). Idempotent — only seeds when empty so
    // we don't clobber fresher data that arrived from a network refresh.
    func seed(season: Int, players: [String: Player]) {
        if playersBySeason[season] == nil {
            var copy = players
            applyAllLiveOverrides(to: &copy, season: season)
            playersBySeason[season] = copy
        }
    }

    func defaultSeason() async -> Int {
        await availableSeasons().first ?? Calendar.current.component(.year, from: Date())
    }

    // MARK: - Live overrides

    // Apply a live update from realtime. Splices the new fantasy point values
    // into the matching Game inside our cached player. Idempotent.
    func applyLiveOverride(playerID: String, season: Int, week: Int,
                           standard: Double, ppr: Double, halfPpr: Double, isFinal: Bool) {
        liveOverrides[LiveKey(playerID: playerID, season: season, week: week)] =
            LiveOverride(standard: standard, ppr: ppr, halfPpr: halfPpr, isFinal: isFinal)
        guard var players = playersBySeason[season],
              var player = players[playerID] else { return }
        if let idx = player.games.firstIndex(where: { $0.week == week }) {
            player.games[idx].fantasyPoints        = standard
            player.games[idx].fantasyPointsPPR     = ppr
            player.games[idx].fantasyPointsHalfPPR = halfPpr
        } else {
            // Player has no row yet for this week (game in progress, no stats
            // accumulated). Insert a stub so scoring picks up zero baseline
            // until the next nflverse sync writes the full counting stats.
            var stub = Game()
            stub.season = season; stub.week = week
            stub.fantasyPoints = standard
            stub.fantasyPointsPPR = ppr
            stub.fantasyPointsHalfPPR = halfPpr
            player.games.append(stub)
            player.games.sort { $0.week < $1.week }
        }
        players[playerID] = player
        playersBySeason[season] = players
    }

    func currentSnapshot(season: Int) -> [String: Player]? {
        playersBySeason[season]
    }

    private func applyAllLiveOverrides(to players: inout [String: Player], season: Int) {
        for (key, o) in liveOverrides where key.season == season {
            guard var p = players[key.playerID] else { continue }
            if let idx = p.games.firstIndex(where: { $0.week == key.week }) {
                p.games[idx].fantasyPoints        = o.standard
                p.games[idx].fantasyPointsPPR     = o.ppr
                p.games[idx].fantasyPointsHalfPPR = o.halfPpr
            }
            players[key.playerID] = p
        }
    }

    // MARK: - Row fetch

    private struct PlayerRowDB: Decodable {
        let id: String
        let name: String
        let position: String
        let positionGroup: String
        let team: String
        let headshotURL: String
        let birthDate: String?
        let heightIn: Int?
        let weightLb: Int?
        let college: String?
        let jerseyNumber: Int?
        let draftYear: Int?
        let draftRound: Int?
        let draftPick: Int?
        let yearsExp: Int?
        let status: String?
        let byeWeek: Int?
        enum CodingKeys: String, CodingKey {
            case id, name, position, team, college, status
            case positionGroup = "position_group"
            case headshotURL   = "headshot_url"
            case birthDate     = "birth_date"
            case heightIn      = "height_in"
            case weightLb      = "weight_lb"
            case jerseyNumber  = "jersey_number"
            case draftYear     = "draft_year"
            case draftRound    = "draft_round"
            case draftPick     = "draft_pick"
            case yearsExp      = "years_exp"
            case byeWeek       = "bye_week"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id            = try c.decode(String.self, forKey: .id)
            name          = try c.decode(String.self, forKey: .name)
            position      = try c.decode(String.self, forKey: .position)
            positionGroup = try c.decode(String.self, forKey: .positionGroup)
            team          = try c.decode(String.self, forKey: .team)
            headshotURL   = try c.decode(String.self, forKey: .headshotURL)
            // Bio columns are decoded as optional — the rosters CSV doesn't
            // populate every player.
            birthDate    = try c.decodeIfPresent(String.self, forKey: .birthDate)
            heightIn     = try c.decodeIfPresent(Int.self,    forKey: .heightIn)
            weightLb     = try c.decodeIfPresent(Int.self,    forKey: .weightLb)
            college      = try c.decodeIfPresent(String.self, forKey: .college)
            jerseyNumber = try c.decodeIfPresent(Int.self,    forKey: .jerseyNumber)
            draftYear    = try c.decodeIfPresent(Int.self,    forKey: .draftYear)
            draftRound   = try c.decodeIfPresent(Int.self,    forKey: .draftRound)
            draftPick    = try c.decodeIfPresent(Int.self,    forKey: .draftPick)
            yearsExp     = try c.decodeIfPresent(Int.self,    forKey: .yearsExp)
            status       = try c.decodeIfPresent(String.self, forKey: .status)
            byeWeek      = try c.decodeIfPresent(Int.self,    forKey: .byeWeek)
        }
    }

    private struct GameRowDB: Decodable {
        let playerID: String
        let season: Int
        let week: Int
        let team: String
        let opponent: String
        let completions: Double
        let attempts: Double
        let passingYards: Double
        let passingTDs: Double
        let passingInterceptions: Double
        let carries: Double
        let rushingYards: Double
        let rushingTDs: Double
        let receptions: Double
        let targets: Double
        let receivingYards: Double
        let receivingTDs: Double
        let fumblesLost: Double
        let fantasyPoints: Double
        let fantasyPointsPPR: Double
        let fantasyPointsHalfPPR: Double
        enum CodingKeys: String, CodingKey {
            case season, week, team, opponent, completions, attempts, carries, receptions, targets
            case playerID              = "player_id"
            case passingYards          = "passing_yards"
            case passingTDs            = "passing_tds"
            case passingInterceptions  = "passing_interceptions"
            case rushingYards          = "rushing_yards"
            case rushingTDs            = "rushing_tds"
            case receivingYards        = "receiving_yards"
            case receivingTDs          = "receiving_tds"
            case fumblesLost           = "fumbles_lost"
            case fantasyPoints         = "fantasy_points"
            case fantasyPointsPPR      = "fantasy_points_ppr"
            case fantasyPointsHalfPPR  = "fantasy_points_half_ppr"
        }
    }

    private func fetchPlayers(season: Int) async throws -> [PlayerRowDB] {
        // Pull every player in the cache. The assembly loop attaches games
        // where they exist for the requested season; players without any
        // games still surface (free agents, practice-squad-eligible, retirees
        // still in roster history). This is "every NFL player nflverse knows
        // about". PostgREST caps each request at 1000 rows, so paginate.
        var out: [PlayerRowDB] = []
        var from = 0
        let page = 1000
        while true {
            let rows: [PlayerRowDB] = try await client.from("players_cache")
                .select("""
                id, name, position, position_group, team, headshot_url,
                birth_date, height_in, weight_lb, college, jersey_number,
                draft_year, draft_round, draft_pick, years_exp, status, bye_week
                """)
                // Order by the primary key so offset pagination is stable.
                // Without a deterministic total order Postgres may return a row
                // on two pages (and skip another), duplicating/dropping players.
                .order("id", ascending: true)
                .range(from: from, to: from + page - 1)
                .execute().value
            out.append(contentsOf: rows)
            if rows.count < page { break }
            from += page
        }
        return out
    }

    // MARK: - NFL schedules

    func schedules(season: Int) async throws -> [NFLGame] {
        if let cached = schedulesBySeason[season] { return cached }
        struct Row: Decodable {
            let gameID: String; let season: Int; let week: Int
            let homeTeam: String; let awayTeam: String
            let kickoff: String?
            let homeScore: Int?; let awayScore: Int?
            let status: String
            let homeSpread: Double?
            let total: Double?
            let tempF: Int?; let windMph: Int?
            let precipitation: String?
            let roof: String?; let surface: String?
            enum CodingKeys: String, CodingKey {
                case season, week, kickoff, status, total, roof, surface
                case gameID         = "game_id"
                case homeTeam       = "home_team"
                case awayTeam       = "away_team"
                case homeScore      = "home_score"
                case awayScore      = "away_score"
                case homeSpread     = "home_spread"
                case tempF          = "temp_f"
                case windMph        = "wind_mph"
                case precipitation  = "precipitation"
            }
        }
        let rows: [Row] = (try? await client.from("nfl_schedules")
            .select()
            .eq("season", value: season)
            .order("week", ascending: true)
            .execute()
            .value) ?? []
        let games: [NFLGame] = rows.map {
            NFLGame(
                gameID: $0.gameID, season: $0.season, week: $0.week,
                home: $0.homeTeam, away: $0.awayTeam,
                kickoff: parseISO($0.kickoff),
                homeScore: $0.homeScore, awayScore: $0.awayScore,
                status: NFLGameStatus(rawValue: $0.status) ?? .scheduled,
                homeSpread: $0.homeSpread,
                total: $0.total,
                tempF: $0.tempF, windMph: $0.windMph,
                precipitation: $0.precipitation,
                roof: $0.roof, surface: $0.surface
            )
        }
        schedulesBySeason[season] = games
        return games
    }

    // MARK: - Team ranks (MFL cumulative offense/defense)

    // [team: TeamRanks]. Empty in the off-season — populates once a game is
    // played. Single-snapshot table; no season dimension.
    func teamRanks() async -> [String: TeamRanks] {
        struct Row: Decodable {
            let team: String
            let passOffense: Int?; let rushOffense: Int?
            let passDefense: Int?; let rushDefense: Int?
            enum CodingKeys: String, CodingKey {
                case team
                case passOffense = "pass_offense"
                case rushOffense = "rush_offense"
                case passDefense = "pass_defense"
                case rushDefense = "rush_defense"
            }
        }
        let rows: [Row] = (try? await client.from("nfl_team_ranks")
            .select()
            .execute().value) ?? []
        var out: [String: TeamRanks] = [:]
        out.reserveCapacity(rows.count)
        for r in rows {
            out[r.team] = TeamRanks(
                team: r.team, passOffense: r.passOffense, rushOffense: r.rushOffense,
                passDefense: r.passDefense, rushDefense: r.rushDefense
            )
        }
        return out
    }

    // MARK: - Most-started % (MFL topStarters)

    // [playerID: started_pct] — % of MFL leagues that started this player
    // in the most recent week. Empty off-season.
    func mostStarted() async -> [String: Double] {
        struct Row: Decodable {
            let playerId: String; let startedPct: Double
            enum CodingKeys: String, CodingKey {
                case playerId   = "player_id"
                case startedPct = "started_pct"
            }
        }
        let rows: [Row] = (try? await client.from("most_started")
            .select("player_id, started_pct")
            .execute().value) ?? []
        var out: [String: Double] = [:]
        for r in rows { out[r.playerId] = r.startedPct }
        return out
    }

    // MARK: - NFL team metadata

    func teams() async -> [NFLTeamMeta] {
        if let cached = teamsCache { return cached }
        struct Row: Decodable {
            let abbr: String; let fullName: String
            let conference: String; let division: String
            let primaryColor: String?; let secondaryColor: String?
            let logoURL: String?
            enum CodingKeys: String, CodingKey {
                case abbr, conference, division
                case fullName       = "full_name"
                case primaryColor   = "primary_color"
                case secondaryColor = "secondary_color"
                case logoURL        = "logo_url"
            }
        }
        let rows: [Row] = (try? await client.from("nfl_teams")
            .select()
            .order("abbr", ascending: true)
            .execute()
            .value) ?? []
        let result = rows.map {
            NFLTeamMeta(
                abbr: $0.abbr, fullName: $0.fullName,
                conference: $0.conference, division: $0.division,
                primaryColor: $0.primaryColor, secondaryColor: $0.secondaryColor,
                logoURL: $0.logoURL
            )
        }
        teamsCache = result
        return result
    }

    // MARK: - Snap counts

    // Returns [playerID: [week: SnapCount]] for fast point lookups by the UI.
    func snapCounts(season: Int) async throws -> [String: [Int: SnapCount]] {
        if let cached = snapsBySeason[season] { return cached }
        struct Row: Decodable {
            let playerID: String; let season: Int; let week: Int
            let team: String?
            let offenseSnaps: Int; let offensePct: Double
            enum CodingKeys: String, CodingKey {
                case season, week, team
                case playerID     = "player_id"
                case offenseSnaps = "offense_snaps"
                case offensePct   = "offense_pct"
            }
        }
        let rows: [Row] = (try? await client.from("snap_counts")
            .select()
            .eq("season", value: season)
            .execute()
            .value) ?? []
        var out: [String: [Int: SnapCount]] = [:]
        for r in rows {
            let entry = SnapCount(
                playerID: r.playerID, season: r.season, week: r.week,
                team: r.team ?? "", offenseSnaps: r.offenseSnaps, offensePct: r.offensePct
            )
            out[r.playerID, default: [:]][r.week] = entry
        }
        snapsBySeason[season] = out
        return out
    }

    // MARK: - Defense vs Position

    // Full-season DvP (legacy callers that don't care about week-clamping).
    func dvp(season: Int, position: String) async throws -> [String: DvPEntry] {
        try await dvp(season: season, position: position, upToWeek: nil)
    }

    // Week-clamped DvP. When upToWeek is non-nil, ranks are computed from
    // weeks 1..upToWeek only. Used by simulations to show "DvP as of week N",
    // not full-season hindsight.
    func dvp(season: Int, position: String, upToWeek: Int?) async throws -> [String: DvPEntry] {
        let key = position.uppercased()
        let cacheKey = upToWeek.map { "\(key)#\($0)" } ?? key
        if let cached = dvpCache[season]?[cacheKey] { return cached }
        struct Row: Decodable {
            let team: String
            let pointsAllowed: Double
            let rank: Int
            enum CodingKeys: String, CodingKey {
                case team, rank
                case pointsAllowed = "points_allowed"
            }
        }
        struct Args: Encodable {
            let p_season: Int
            let p_position: String
            let p_scoring: String
            let p_up_to_week: Int?
        }
        let rows: [Row] = (try? await client.rpc(
            "dvp_ranks",
            params: Args(p_season: season, p_position: key, p_scoring: "ppr",
                         p_up_to_week: upToWeek)
        ).execute().value) ?? []
        var byTeam: [String: DvPEntry] = [:]
        for r in rows {
            byTeam[r.team] = DvPEntry(team: r.team, pointsAllowed: r.pointsAllowed, rank: r.rank)
        }
        dvpCache[season, default: [:]][cacheKey] = byTeam
        return byTeam
    }

    // MARK: - ADP

    // Legacy default. Returns the latest snapshot for the season.
    func adp(season: Int, scoring: Scoring) async throws -> [String: Double] {
        try await adp(season: season, scoring: scoring, onOrBefore: nil)
    }

    // Point-in-time ADP. When `onOrBefore` is non-nil, returns the latest
    // snapshot whose snapshot_date <= that date. Use this for simulation
    // drafts — you want the ADP managers actually had at draft time, not
    // the season-aggregate.
    //
    // Note: rows are stored per (season, scoring, snapshot_date, player).
    // We fetch only the latest snapshot_date <= onOrBefore by issuing a
    // small auxiliary query first.
    func adp(season: Int, scoring: Scoring, onOrBefore: Date?) async throws -> [String: Double] {
        let key = scoring.rawValue
        let cacheKey = onOrBefore.map { Self.plainDateFormatter.string(from: $0) } ?? key
        let bucket = "\(key)#\(cacheKey)"
        if let cached = adpCache[season]?[bucket] { return cached }

        // Pick the snapshot date.
        let snapshot: String? = try await latestAdpSnapshot(
            season: season, scoring: key, onOrBefore: onOrBefore
        )
        guard let snapshot else {
            adpCache[season, default: [:]][bucket] = [:]
            return [:]
        }

        struct Row: Decodable {
            let playerID: String
            let adp: Double
            enum CodingKeys: String, CodingKey {
                case adp
                case playerID = "player_id"
            }
        }
        let rows: [Row] = (try? await client.from("adp")
            .select("player_id, adp")
            .eq("season", value: season)
            .eq("scoring", value: key)
            .eq("snapshot_date", value: snapshot)
            .execute().value) ?? []
        var out: [String: Double] = [:]
        out.reserveCapacity(rows.count)
        for r in rows { out[r.playerID] = r.adp }
        adpCache[season, default: [:]][bucket] = out
        return out
    }

    private func latestAdpSnapshot(season: Int, scoring: String, onOrBefore: Date?) async throws -> String? {
        struct Row: Decodable {
            let snapshotDate: String
            enum CodingKeys: String, CodingKey { case snapshotDate = "snapshot_date" }
        }
        var query = client.from("adp")
            .select("snapshot_date")
            .eq("season", value: season)
            .eq("scoring", value: scoring)
        if let date = onOrBefore {
            let iso = Self.plainDateFormatter.string(from: date)
            query = query.lte("snapshot_date", value: iso)
        }
        let rows: [Row] = (try? await query
            .order("snapshot_date", ascending: false)
            .limit(1)
            .execute().value) ?? []
        return rows.first?.snapshotDate
    }

    // MARK: - Depth charts (historical)

    func depthChart(season: Int, week: Int, team: String) async -> [DepthChartEntry] {
        struct Row: Decodable {
            let playerID: String; let team: String
            let position: String; let depth: Int
            enum CodingKeys: String, CodingKey {
                case team, position, depth
                case playerID = "player_id"
            }
        }
        let rows: [Row] = (try? await client.from("depth_charts")
            .select("player_id, team, position, depth")
            .eq("season", value: season)
            .eq("week",   value: week)
            .eq("team",   value: team.uppercased())
            .order("position", ascending: true)
            .order("depth",    ascending: true)
            .execute().value) ?? []
        return rows.map {
            DepthChartEntry(playerID: $0.playerID, team: $0.team,
                            position: $0.position, depth: $0.depth)
        }
    }

    // MARK: - Inactives (historical)

    // Returns the set of player IDs marked inactive for that (season, week).
    func inactives(season: Int, week: Int) async -> Set<String> {
        struct Row: Decodable {
            let playerID: String
            enum CodingKeys: String, CodingKey { case playerID = "player_id" }
        }
        let rows: [Row] = (try? await client.from("inactives")
            .select("player_id")
            .eq("season", value: season)
            .eq("week",   value: week)
            .execute().value) ?? []
        return Set(rows.map(\.playerID))
    }

    // MARK: - Date helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func parseISO(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return Self.isoFractionalFormatter.date(from: s)
            ?? Self.isoFormatter.date(from: s)
    }

    private func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return Self.plainDateFormatter.date(from: s)
    }

    private func fetchGames(season: Int) async throws -> [GameRowDB] {
        // Use a server-side range and paginate. PostgREST default limit is 1000.
        var out: [GameRowDB] = []
        var from = 0
        let page = 1000
        while true {
            let rows: [GameRowDB] = try await client.from("player_games")
                .select()
                .eq("season", value: season)
                // Order by the full key (player_id, week) so offset pagination
                // is deterministic. Ordering by `week` alone leaves rows within
                // a week unordered, so across pages Postgres can repeat a row
                // (showing a week twice in the game log) and skip another
                // (a missing week) — the duplicate/missing-game bug.
                .order("player_id", ascending: true)
                .order("week", ascending: true)
                .range(from: from, to: from + page - 1)
                .execute().value
            out.append(contentsOf: rows)
            if rows.count < page { break }
            from += page
        }
        return out
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        var out: [[Element]] = []
        var i = 0
        while i < count {
            out.append(Array(self[i..<Swift.min(i + size, count)]))
            i += size
        }
        return out
    }
}
