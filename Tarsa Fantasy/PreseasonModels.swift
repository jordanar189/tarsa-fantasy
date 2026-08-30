import Foundation

// NFL preseason games and box-score lines. Deliberately separate from
// NFLGame / Game: ESPN numbers preseason weeks 1-4 (1 = Hall of Fame weekend),
// which would collide with regular-season weeks everywhere the app keys on
// (season, week), and preseason never counts toward league scoring. Note the
// existing `AppState.isPreseason(season:)` means "no games played yet" — it is
// unrelated to these types.

enum PreseasonGameStatus: String, Codable, Hashable {
    case scheduled
    case inProgress = "in_progress"
    case final
    case postponed
}

struct PreseasonGame: Identifiable, Hashable {
    let gameID: String            // ESPN event id
    let season: Int
    let preWeek: Int              // 1 = Hall of Fame weekend, 2...4 = Preseason Weeks 1-3
    let weekLabel: String
    let home: String
    let away: String
    let homeScore: Int?
    let awayScore: Int?
    let homeLinescores: [Int]
    let awayLinescores: [Int]
    let status: PreseasonGameStatus
    let period: Int?
    let clock: String?
    let statusDetail: String?     // ESPN shortDetail: "3rd 4:12", "Final", "8/29 - 1:00 PM EDT"
    let kickoff: Date?
    let venue: String?
    let scoringPlays: [PreseasonScoringPlay]

    var id: String { gameID }
    var isLive: Bool { status == .inProgress }

    // Short week tag for compact rows: "HOF", "Pre 1", "Pre 2", ...
    static func shortWeekLabel(_ preWeek: Int) -> String {
        preWeek <= 1 ? "HOF" : "Pre \(preWeek - 1)"
    }
}

struct PreseasonScoringPlay: Codable, Hashable {
    let text: String
    let type: String?
    let period: Int?
    let clock: String?
    let away: Int?
    let home: Int?
    let team: String?
}

struct PreseasonPlayerLine: Identifiable, Hashable {
    let gameID: String
    let espnAthleteID: String
    let season: Int
    let preWeek: Int
    let playerID: String?         // players_cache id when the athlete maps; nil for camp bodies
    let name: String
    let jersey: String?
    let team: String
    let opponent: String
    let isFinal: Bool

    let completions: Double
    let attempts: Double
    let passingYards: Double
    let passingTDs: Double
    let passingInterceptions: Double
    let sacksTaken: Double
    let carries: Double
    let rushingYards: Double
    let rushingTDs: Double
    let rushingLong: Double
    let receptions: Double
    let targets: Double
    let receivingYards: Double
    let receivingTDs: Double
    let receivingLong: Double
    let fumbles: Double
    let fumblesLost: Double
    let defTacklesSolo: Double
    let defTackleAssists: Double
    let defSacks: Double
    let defTacklesForLoss: Double
    let defQbHits: Double
    let defPassDefended: Double
    let defInterceptions: Double
    let defTDs: Double
    let kickReturns: Double
    let kickReturnYards: Double
    let kickReturnTDs: Double
    let puntReturns: Double
    let puntReturnYards: Double
    let puntReturnTDs: Double
    let fgMade: Double
    let fgAtt: Double
    let fgLong: Double
    let patMade: Double
    let patAtt: Double
    let fantasyPoints: Double
    let fantasyPointsPPR: Double
    let fantasyPointsHalfPPR: Double

    var id: String { "\(gameID)-\(espnAthleteID)" }

    var hasPassing: Bool   { attempts > 0 }
    var hasRushing: Bool   { carries > 0 }
    var hasReceiving: Bool { targets > 0 || receptions > 0 }
    var hasDefense: Bool {
        defTacklesSolo + defTackleAssists + defSacks + defTacklesForLoss
            + defPassDefended + defInterceptions + defQbHits > 0
    }
    var hasReturns: Bool   { kickReturns + puntReturns > 0 }
    var hasKicking: Bool   { fgAtt + patAtt > 0 }
    var defTacklesTotal: Double { defTacklesSolo + defTackleAssists }

    // Display only — preseason never feeds league scoring, so the preset
    // point fields are the whole story (no custom-settings path).
    func points(scoring: Scoring) -> Double {
        switch scoring {
        case .ppr:  return fantasyPointsPPR
        case .half: return fantasyPointsHalfPPR
        default:    return fantasyPoints
        }
    }
}
