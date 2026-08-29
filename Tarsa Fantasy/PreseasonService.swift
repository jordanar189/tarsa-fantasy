import Foundation
import Supabase

// Reads preseason_games / preseason_player_stats. Thin Supabase reader in the
// NFLDataService mould; views reach it only through the AppState
// pass-throughs at the bottom of this file.
actor PreseasonService {
    static let shared = PreseasonService()

    private let client = SupabaseConfig.sharedClient

    func games(season: Int) async throws -> [PreseasonGame] {
        let rows: [GameRow] = try await client.from("preseason_games")
            .select()
            .eq("season", value: season)
            .order("kickoff", ascending: true)
            .execute().value
        return rows.map(Self.game(from:))
    }

    func game(gameID: String) async throws -> PreseasonGame? {
        let rows: [GameRow] = try await client.from("preseason_games")
            .select()
            .eq("game_id", value: gameID)
            .limit(1)
            .execute().value
        return rows.first.map(Self.game(from:))
    }

    func boxScore(gameID: String) async throws -> [PreseasonPlayerLine] {
        let rows: [LineRow] = try await client.from("preseason_player_stats")
            .select()
            .eq("game_id", value: gameID)
            .order("fantasy_points_ppr", ascending: false)
            .execute().value
        return rows.map(Self.line(from:))
    }

    func playerLines(playerID: String, season: Int) async throws -> [PreseasonPlayerLine] {
        let rows: [LineRow] = try await client.from("preseason_player_stats")
            .select()
            .eq("player_id", value: playerID)
            .eq("season", value: season)
            .order("pre_week", ascending: true)
            .execute().value
        return rows.map(Self.line(from:))
    }

    // MARK: - Row types (snake_case → camelCase)

    private struct GameRow: Decodable {
        let gameID: String; let season: Int; let preWeek: Int; let weekLabel: String
        let homeTeam: String; let awayTeam: String
        let homeScore: Int?; let awayScore: Int?
        let homeLinescores: [Int]?; let awayLinescores: [Int]?
        let status: String
        let period: Int?; let clock: String?; let statusDetail: String?
        let kickoff: String?; let venue: String?
        let scoringPlays: [PreseasonScoringPlay]?
        enum CodingKeys: String, CodingKey {
            case season, status, period, clock, kickoff, venue
            case gameID         = "game_id"
            case preWeek        = "pre_week"
            case weekLabel      = "week_label"
            case homeTeam       = "home_team"
            case awayTeam       = "away_team"
            case homeScore      = "home_score"
            case awayScore      = "away_score"
            case homeLinescores = "home_linescores"
            case awayLinescores = "away_linescores"
            case statusDetail   = "status_detail"
            case scoringPlays   = "scoring_plays"
        }
    }

    private static func game(from r: GameRow) -> PreseasonGame {
        PreseasonGame(
            gameID: r.gameID, season: r.season, preWeek: r.preWeek, weekLabel: r.weekLabel,
            home: r.homeTeam, away: r.awayTeam,
            homeScore: r.homeScore, awayScore: r.awayScore,
            homeLinescores: r.homeLinescores ?? [], awayLinescores: r.awayLinescores ?? [],
            status: PreseasonGameStatus(rawValue: r.status) ?? .scheduled,
            period: r.period, clock: r.clock, statusDetail: r.statusDetail,
            kickoff: parseISO(r.kickoff), venue: r.venue,
            scoringPlays: r.scoringPlays ?? []
        )
    }

    private struct LineRow: Decodable {
        let gameID: String; let espnAthleteID: String
        let season: Int; let preWeek: Int
        let playerID: String?
        let name: String; let jersey: String?
        let team: String; let opponent: String
        let isFinal: Bool?
        let completions: Double?; let attempts: Double?; let passingYards: Double?
        let passingTDs: Double?; let passingInterceptions: Double?; let sacksTaken: Double?
        let carries: Double?; let rushingYards: Double?; let rushingTDs: Double?; let rushingLong: Double?
        let receptions: Double?; let targets: Double?; let receivingYards: Double?
        let receivingTDs: Double?; let receivingLong: Double?
        let fumbles: Double?; let fumblesLost: Double?
        let defTacklesSolo: Double?; let defTackleAssists: Double?; let defSacks: Double?
        let defTacklesForLoss: Double?; let defQbHits: Double?; let defPassDefended: Double?
        let defInterceptions: Double?; let defTDs: Double?
        let kickReturns: Double?; let kickReturnYards: Double?; let kickReturnTDs: Double?
        let puntReturns: Double?; let puntReturnYards: Double?; let puntReturnTDs: Double?
        let fgMade: Double?; let fgAtt: Double?; let fgLong: Double?
        let patMade: Double?; let patAtt: Double?
        let fantasyPoints: Double?; let fantasyPointsPPR: Double?; let fantasyPointsHalfPPR: Double?
        enum CodingKeys: String, CodingKey {
            case season, name, jersey, team, opponent, completions, attempts, carries, receptions, targets, fumbles
            case gameID                = "game_id"
            case espnAthleteID         = "espn_athlete_id"
            case preWeek               = "pre_week"
            case playerID              = "player_id"
            case isFinal               = "is_final"
            case passingYards          = "passing_yards"
            case passingTDs            = "passing_tds"
            case passingInterceptions  = "passing_interceptions"
            case sacksTaken            = "sacks_taken"
            case rushingYards          = "rushing_yards"
            case rushingTDs            = "rushing_tds"
            case rushingLong           = "rushing_long"
            case receivingYards        = "receiving_yards"
            case receivingTDs          = "receiving_tds"
            case receivingLong         = "receiving_long"
            case fumblesLost           = "fumbles_lost"
            case defTacklesSolo        = "def_tackles_solo"
            case defTackleAssists      = "def_tackle_assists"
            case defSacks              = "def_sacks"
            case defTacklesForLoss     = "def_tackles_for_loss"
            case defQbHits             = "def_qb_hits"
            case defPassDefended       = "def_pass_defended"
            case defInterceptions      = "def_interceptions"
            case defTDs                = "def_tds"
            case kickReturns           = "kick_returns"
            case kickReturnYards       = "kick_return_yards"
            case kickReturnTDs         = "kick_return_tds"
            case puntReturns           = "punt_returns"
            case puntReturnYards       = "punt_return_yards"
            case puntReturnTDs         = "punt_return_tds"
            case fgMade                = "fg_made"
            case fgAtt                 = "fg_att"
            case fgLong                = "fg_long"
            case patMade               = "pat_made"
            case patAtt                = "pat_att"
            case fantasyPoints         = "fantasy_points"
            case fantasyPointsPPR      = "fantasy_points_ppr"
            case fantasyPointsHalfPPR  = "fantasy_points_half_ppr"
        }
    }

    private static func line(from r: LineRow) -> PreseasonPlayerLine {
        PreseasonPlayerLine(
            gameID: r.gameID, espnAthleteID: r.espnAthleteID,
            season: r.season, preWeek: r.preWeek,
            playerID: r.playerID, name: r.name, jersey: r.jersey,
            team: r.team, opponent: r.opponent, isFinal: r.isFinal ?? false,
            completions: r.completions ?? 0, attempts: r.attempts ?? 0,
            passingYards: r.passingYards ?? 0, passingTDs: r.passingTDs ?? 0,
            passingInterceptions: r.passingInterceptions ?? 0, sacksTaken: r.sacksTaken ?? 0,
            carries: r.carries ?? 0, rushingYards: r.rushingYards ?? 0,
            rushingTDs: r.rushingTDs ?? 0, rushingLong: r.rushingLong ?? 0,
            receptions: r.receptions ?? 0, targets: r.targets ?? 0,
            receivingYards: r.receivingYards ?? 0, receivingTDs: r.receivingTDs ?? 0,
            receivingLong: r.receivingLong ?? 0,
            fumbles: r.fumbles ?? 0, fumblesLost: r.fumblesLost ?? 0,
            defTacklesSolo: r.defTacklesSolo ?? 0, defTackleAssists: r.defTackleAssists ?? 0,
            defSacks: r.defSacks ?? 0, defTacklesForLoss: r.defTacklesForLoss ?? 0,
            defQbHits: r.defQbHits ?? 0, defPassDefended: r.defPassDefended ?? 0,
            defInterceptions: r.defInterceptions ?? 0, defTDs: r.defTDs ?? 0,
            kickReturns: r.kickReturns ?? 0, kickReturnYards: r.kickReturnYards ?? 0,
            kickReturnTDs: r.kickReturnTDs ?? 0,
            puntReturns: r.puntReturns ?? 0, puntReturnYards: r.puntReturnYards ?? 0,
            puntReturnTDs: r.puntReturnTDs ?? 0,
            fgMade: r.fgMade ?? 0, fgAtt: r.fgAtt ?? 0, fgLong: r.fgLong ?? 0,
            patMade: r.patMade ?? 0, patAtt: r.patAtt ?? 0,
            fantasyPoints: r.fantasyPoints ?? 0,
            fantasyPointsPPR: r.fantasyPointsPPR ?? 0,
            fantasyPointsHalfPPR: r.fantasyPointsHalfPPR ?? 0
        )
    }

    // PostgREST emits timestamptz as ISO-8601 with or without fractional seconds.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}

// MARK: - AppState pass-throughs

// Views never touch the actor directly (see CLAUDE.md); these mirror the
// NFL-data pass-throughs in AppState.swift. Failures degrade to "no data".
extension AppState {
    func preseasonGames(season: Int) async -> [PreseasonGame] {
        (try? await PreseasonService.shared.games(season: season)) ?? []
    }

    func preseasonGame(gameID: String) async -> PreseasonGame? {
        (try? await PreseasonService.shared.game(gameID: gameID)) ?? nil
    }

    func preseasonBoxScore(gameID: String) async -> [PreseasonPlayerLine] {
        (try? await PreseasonService.shared.boxScore(gameID: gameID)) ?? []
    }

    func preseasonLines(playerID: String, season: Int) async -> [PreseasonPlayerLine] {
        (try? await PreseasonService.shared.playerLines(playerID: playerID, season: season)) ?? []
    }
}
