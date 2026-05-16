import Foundation

enum AppTab: String, Hashable { case players, rankings, leagues }

enum Scoring: String, Codable, CaseIterable, Identifiable, Hashable {
    case standard, ppr, half
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: return "Standard"
        case .ppr:      return "PPR"
        case .half:     return "Half-PPR"
        }
    }
}

enum Position: String, CaseIterable, Identifiable, Hashable {
    case all = "ALL", qb = "QB", rb = "RB", wr = "WR", te = "TE", k = "K"
    var id: String { rawValue }
    var label: String { self == .all ? "All" : rawValue }
}

enum LineupSlot: String, Codable, Hashable, CaseIterable, Identifiable {
    case qb = "QB", rb = "RB", wr = "WR", te = "TE", flex = "FLEX", k = "K", bench = "BN"
    var id: String { rawValue }
    var label: String { rawValue }
    var isStarter: Bool { self != .bench }

    func accepts(position: String) -> Bool {
        let p = position.uppercased()
        switch self {
        case .qb:    return p == "QB"
        case .rb:    return p == "RB"
        case .wr:    return p == "WR"
        case .te:    return p == "TE"
        case .k:     return p == "K"
        case .flex:  return p == "RB" || p == "WR" || p == "TE"
        case .bench: return true
        }
    }
}

struct RosterConfig: Codable, Hashable {
    var qb: Int
    var rb: Int
    var wr: Int
    var te: Int
    var flex: Int
    var k: Int
    var bench: Int

    static let `default` = RosterConfig(qb: 1, rb: 2, wr: 2, te: 1, flex: 1, k: 1, bench: 6)

    var starterCount: Int { qb + rb + wr + te + flex + k }
    var totalSize: Int { starterCount + bench }

    // Slots in display order, starters first then bench. Index into this array
    // matches the index of the matching entry in FantasyTeam.starters.
    var slots: [LineupSlot] {
        var out: [LineupSlot] = []
        out.reserveCapacity(totalSize)
        for _ in 0..<qb    { out.append(.qb) }
        for _ in 0..<rb    { out.append(.rb) }
        for _ in 0..<wr    { out.append(.wr) }
        for _ in 0..<te    { out.append(.te) }
        for _ in 0..<flex  { out.append(.flex) }
        for _ in 0..<k     { out.append(.k) }
        for _ in 0..<bench { out.append(.bench) }
        return out
    }
    var starterSlots: [LineupSlot] { Array(slots.prefix(starterCount)) }

    init(qb: Int = 1, rb: Int = 2, wr: Int = 2, te: Int = 1,
         flex: Int = 1, k: Int = 1, bench: Int = 6) {
        self.qb = qb; self.rb = rb; self.wr = wr; self.te = te
        self.flex = flex; self.k = k; self.bench = bench
    }

    private enum CodingKeys: String, CodingKey { case qb, rb, wr, te, flex, k, bench }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        qb    = try c.decodeIfPresent(Int.self, forKey: .qb)    ?? 1
        rb    = try c.decodeIfPresent(Int.self, forKey: .rb)    ?? 2
        wr    = try c.decodeIfPresent(Int.self, forKey: .wr)    ?? 2
        te    = try c.decodeIfPresent(Int.self, forKey: .te)    ?? 1
        flex  = try c.decodeIfPresent(Int.self, forKey: .flex)  ?? 1
        k     = try c.decodeIfPresent(Int.self, forKey: .k)     ?? 1
        bench = try c.decodeIfPresent(Int.self, forKey: .bench) ?? 6
    }
}

struct Game: Codable, Hashable, Identifiable {
    var season: Int = 0
    var week: Int = 0
    var team: String = ""
    var opponent: String = ""
    var completions: Double = 0
    var attempts: Double = 0
    var passingYards: Double = 0
    var passingTDs: Double = 0
    var passingInterceptions: Double = 0
    var carries: Double = 0
    var rushingYards: Double = 0
    var rushingTDs: Double = 0
    var receptions: Double = 0
    var targets: Double = 0
    var receivingYards: Double = 0
    var receivingTDs: Double = 0
    var fumblesLost: Double = 0
    var fantasyPoints: Double = 0
    var fantasyPointsPPR: Double = 0
    var fantasyPointsHalfPPR: Double = 0

    var id: String { "\(season)-\(week)-\(team)" }

    func points(scoring: Scoring) -> Double {
        switch scoring {
        case .standard: return fantasyPoints
        case .ppr:      return fantasyPointsPPR
        case .half:     return fantasyPointsHalfPPR
        }
    }
}

struct Player: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var position: String
    var positionGroup: String
    var headshotURL: String
    var team: String
    var games: [Game]
}

struct PlayerSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let position: String
    let team: String
    let headshotURL: String
    let gamesPlayed: Int
    let points: Double
    let pointsPerGame: Double
}

struct SeasonTotals: Hashable {
    var gamesPlayed: Int = 0
    var completions: Double = 0
    var attempts: Double = 0
    var passingYards: Double = 0
    var passingTDs: Double = 0
    var passingInterceptions: Double = 0
    var carries: Double = 0
    var rushingYards: Double = 0
    var rushingTDs: Double = 0
    var receptions: Double = 0
    var targets: Double = 0
    var receivingYards: Double = 0
    var receivingTDs: Double = 0
    var fumblesLost: Double = 0
    var fantasyPoints: Double = 0
    var fantasyPointsPPR: Double = 0
    var fantasyPointsHalfPPR: Double = 0

    func points(scoring: Scoring) -> Double {
        switch scoring {
        case .standard: return fantasyPoints
        case .ppr:      return fantasyPointsPPR
        case .half:     return fantasyPointsHalfPPR
        }
    }
}

struct Rank: Identifiable, Hashable {
    let id: String
    var rank: Int
    let name: String
    let position: String
    let team: String
    let headshotURL: String
    let opponent: String?
    let week: Int?
    let gamesPlayed: Int?
    let points: Double
    let pointsPerGame: Double?
}

struct FantasyTeam: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var roster: [String]
    // Length matches League.rosterConfig.starterCount. An empty string is an
    // unfilled slot. Empty `[]` means lineup hasn't been computed yet — callers
    // should treat it as "auto-fill on the fly from roster".
    var starters: [String]

    init(id: String, name: String, roster: [String] = [], starters: [String] = []) {
        self.id = id; self.name = name; self.roster = roster; self.starters = starters
    }

    private enum CodingKeys: String, CodingKey { case id, name, roster, starters }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(String.self, forKey: .id)
        name     = try c.decode(String.self, forKey: .name)
        roster   = try c.decodeIfPresent([String].self, forKey: .roster)   ?? []
        starters = try c.decodeIfPresent([String].self, forKey: .starters) ?? []
    }
}

struct ScheduleWeek: Codable, Hashable, Identifiable {
    var week: Int
    var matchups: [[String]]
    var byes: [String]
    var id: Int { week }
}

struct League: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var season: Int
    var scoring: Scoring
    var createdAt: Date
    var teams: [FantasyTeam]
    var schedule: [ScheduleWeek]
    var rosterConfig: RosterConfig

    init(id: String, name: String, season: Int, scoring: Scoring, createdAt: Date,
         teams: [FantasyTeam], schedule: [ScheduleWeek],
         rosterConfig: RosterConfig = .default) {
        self.id = id; self.name = name; self.season = season; self.scoring = scoring
        self.createdAt = createdAt; self.teams = teams; self.schedule = schedule
        self.rosterConfig = rosterConfig
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, season, scoring, createdAt, teams, schedule, rosterConfig
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(String.self, forKey: .id)
        name         = try c.decode(String.self, forKey: .name)
        season       = try c.decode(Int.self, forKey: .season)
        scoring      = try c.decode(Scoring.self, forKey: .scoring)
        createdAt    = try c.decode(Date.self, forKey: .createdAt)
        teams        = try c.decode([FantasyTeam].self, forKey: .teams)
        schedule     = try c.decode([ScheduleWeek].self, forKey: .schedule)
        rosterConfig = try c.decodeIfPresent(RosterConfig.self, forKey: .rosterConfig) ?? .default
    }
}

struct LeagueSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let season: Int
    let scoring: Scoring
    let teamCount: Int
    let createdAt: Date
}

struct LeagueRosterEntry: Identifiable, Hashable {
    // Unique within a single roster array. Empty slots all share playerID = ""
    // so the id mixes in the slot index to stay unique.
    let id: String
    let playerID: String   // "" when the slot is empty
    let name: String       // "Empty" when the slot is empty
    let position: String
    let team: String
    let headshotURL: String
    let points: Double
    let played: Bool
    let slot: LineupSlot
}

struct LeagueSide: Hashable {
    let teamID: String
    let name: String
    let points: Double
    let roster: [LeagueRosterEntry]
}

struct LeagueMatchup: Identifiable, Hashable {
    let id: String
    let home: LeagueSide
    let away: LeagueSide
    let played: Bool
}

struct LeagueBye: Identifiable, Hashable {
    let id: String   // team id
    let name: String
}

struct StandingsRow: Identifiable, Hashable {
    let id: String
    let name: String
    let wins: Int
    let losses: Int
    let ties: Int
    let pointsFor: Double
    let pointsAgainst: Double
    let games: Int
    let rank: Int
}
