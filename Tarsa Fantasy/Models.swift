import Foundation

enum AppTab: String, Hashable { case chat, nfl, leagues }

// Persisted UI theme. `system` follows the device setting; `light`/`dark`
// force the app into that scheme regardless of the device. Default is
// `dark` for parity with the pre-theming behavior.
enum AppTheme: String, CaseIterable, Identifiable, Hashable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }
}

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
    case all = "ALL", qb = "QB", rb = "RB", wr = "WR", te = "TE", k = "K", def = "DEF"
    var id: String { rawValue }
    var label: String { self == .all ? "All" : rawValue }
}

enum LineupSlot: String, Codable, Hashable, CaseIterable, Identifiable {
    case qb = "QB", rb = "RB", wr = "WR", te = "TE", flex = "FLEX", k = "K", def = "DEF", bench = "BN"
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
        case .def:   return p == "DEF"
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
    var def: Int
    var bench: Int

    static let `default` = RosterConfig(qb: 1, rb: 2, wr: 2, te: 1, flex: 1, k: 1, def: 1, bench: 6)

    var starterCount: Int { qb + rb + wr + te + flex + k + def }
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
        for _ in 0..<def   { out.append(.def) }
        for _ in 0..<bench { out.append(.bench) }
        return out
    }
    var starterSlots: [LineupSlot] { Array(slots.prefix(starterCount)) }

    init(qb: Int = 1, rb: Int = 2, wr: Int = 2, te: Int = 1,
         flex: Int = 1, k: Int = 1, def: Int = 1, bench: Int = 6) {
        self.qb = qb; self.rb = rb; self.wr = wr; self.te = te
        self.flex = flex; self.k = k; self.def = def; self.bench = bench
    }

    private enum CodingKeys: String, CodingKey { case qb, rb, wr, te, flex, k, def, bench }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        qb    = try c.decodeIfPresent(Int.self, forKey: .qb)    ?? 1
        rb    = try c.decodeIfPresent(Int.self, forKey: .rb)    ?? 2
        wr    = try c.decodeIfPresent(Int.self, forKey: .wr)    ?? 2
        te    = try c.decodeIfPresent(Int.self, forKey: .te)    ?? 1
        flex  = try c.decodeIfPresent(Int.self, forKey: .flex)  ?? 1
        k     = try c.decodeIfPresent(Int.self, forKey: .k)     ?? 1
        def   = try c.decodeIfPresent(Int.self, forKey: .def)   ?? 1
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

struct PlayerProfile: Codable, Hashable {
    var birthDate: Date?
    var heightInches: Int?
    var weightLb: Int?
    var college: String?
    var jerseyNumber: Int?
    var draftYear: Int?
    var draftRound: Int?
    var draftPick: Int?
    var yearsExp: Int?
    var status: String?
    var byeWeek: Int?

    // Decode each field individually so partial bios from nflverse don't
    // make the whole struct fail to decode.
    private enum CodingKeys: String, CodingKey {
        case birthDate, heightInches, weightLb, college, jerseyNumber,
             draftYear, draftRound, draftPick, yearsExp, status, byeWeek
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        birthDate    = try c.decodeIfPresent(Date.self,   forKey: .birthDate)
        heightInches = try c.decodeIfPresent(Int.self,    forKey: .heightInches)
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

    var age: Int? {
        guard let dob = birthDate else { return nil }
        let comps = Calendar.current.dateComponents([.year], from: dob, to: Date())
        return comps.year
    }

    var heightDisplay: String? {
        guard let h = heightInches, h > 0 else { return nil }
        return "\(h / 12)'\(h % 12)\""
    }

    var draftDisplay: String? {
        // Treat 0 as no-data — nflverse uses 0 for undrafted free agents in
        // some columns. If we don't have a real pick number, fall back to
        // "Undrafted" with whatever year we know.
        let y = (draftYear ?? 0) > 0 ? draftYear : nil
        let r = (draftRound ?? 0) > 0 ? draftRound : nil
        let p = (draftPick ?? 0) > 0 ? draftPick : nil
        if let y, let r, let p {
            return "\(y) · Rd \(r) Pick \(p)"
        }
        if let y { return "\(y) · Undrafted" }
        return nil
    }

    // "Rookie" reads better than "0y exp" for first-year players.
    var experienceDisplay: String? {
        guard let y = yearsExp else { return nil }
        return y == 0 ? "Rookie" : "\(y)y exp"
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
    var profile: PlayerProfile?

    init(id: String, name: String, position: String, positionGroup: String,
         headshotURL: String, team: String, games: [Game],
         profile: PlayerProfile? = nil) {
        self.id = id; self.name = name
        self.position = position; self.positionGroup = positionGroup
        self.headshotURL = headshotURL; self.team = team
        self.games = games; self.profile = profile
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, position, positionGroup, headshotURL, team, games, profile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(String.self,        forKey: .id)
        name          = try c.decode(String.self,        forKey: .name)
        position      = try c.decode(String.self,        forKey: .position)
        positionGroup = try c.decode(String.self,        forKey: .positionGroup)
        headshotURL   = try c.decode(String.self,        forKey: .headshotURL)
        team          = try c.decode(String.self,        forKey: .team)
        games         = try c.decode([Game].self,        forKey: .games)
        profile       = try c.decodeIfPresent(PlayerProfile.self, forKey: .profile)
    }
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
    // The signed-in user's ID who owns this team, or nil if the team is
    // unclaimed (available to join).
    var ownerID: String?

    init(id: String, name: String, roster: [String] = [],
         starters: [String] = [], ownerID: String? = nil) {
        self.id = id; self.name = name; self.roster = roster
        self.starters = starters; self.ownerID = ownerID
    }
}

struct ScheduleWeek: Codable, Hashable, Identifiable {
    var week: Int
    var matchups: [[String]]
    var byes: [String]
    var id: Int { week }
}

struct WaiverSettings: Codable, Hashable {
    // 0 = Sunday … 6 = Saturday, UTC. Matches Postgres date_part('dow').
    var processDay: Int
    var processHour: Int     // UTC hour, 0–23
    var periodHours: Int
    var commissionerApproval: Bool

    static let `default` = WaiverSettings(
        processDay: 3, processHour: 8, periodHours: 24, commissionerApproval: false
    )

    var processDayLabel: String {
        ["Sunday", "Monday", "Tuesday", "Wednesday",
         "Thursday", "Friday", "Saturday"][max(0, min(6, processDay))]
    }
}

struct TradeSettings: Codable, Hashable {
    var approval: TradeApprovalMode
    var deadline: Date?
    var voteHours: Int

    static let `default` = TradeSettings(approval: .none, deadline: nil, voteHours: 24)
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
    var joinCode: String
    var creatorID: String
    var waiverSettings: WaiverSettings
    // Ordered team IDs; index 0 has highest waiver priority.
    var waiverPriority: [String]
    var lastWaiversRunAt: Date?
    var tradeSettings: TradeSettings
    // Simulation: when isTest is true, the league is a solo-vs-bots
    // simulation; simulatedWeek pins league-scoped views (standings,
    // scoreboard, free agents) to that fantasy week.
    var isTest: Bool
    var simulatedWeek: Int?
    // Multi-season history: parentLeagueID points to the previous season's
    // league (nil for the first season). seasonCompleted flips when the
    // commish runs "Complete season" — that snapshot freezes the standings
    // into league_seasons and makes the History tab available.
    var parentLeagueID: String?
    var seasonCompleted: Bool
    var seasonCompletedAt: Date?

    init(id: String, name: String, season: Int, scoring: Scoring, createdAt: Date,
         teams: [FantasyTeam], schedule: [ScheduleWeek],
         rosterConfig: RosterConfig = .default,
         joinCode: String = "", creatorID: String = "",
         waiverSettings: WaiverSettings = .default,
         waiverPriority: [String] = [],
         lastWaiversRunAt: Date? = nil,
         tradeSettings: TradeSettings = .default,
         isTest: Bool = false,
         simulatedWeek: Int? = nil,
         parentLeagueID: String? = nil,
         seasonCompleted: Bool = false,
         seasonCompletedAt: Date? = nil) {
        self.id = id; self.name = name; self.season = season; self.scoring = scoring
        self.createdAt = createdAt; self.teams = teams; self.schedule = schedule
        self.rosterConfig = rosterConfig
        self.joinCode = joinCode; self.creatorID = creatorID
        self.waiverSettings = waiverSettings
        self.waiverPriority = waiverPriority
        self.lastWaiversRunAt = lastWaiversRunAt
        self.tradeSettings = tradeSettings
        self.isTest = isTest
        self.simulatedWeek = simulatedWeek
        self.parentLeagueID = parentLeagueID
        self.seasonCompleted = seasonCompleted
        self.seasonCompletedAt = seasonCompletedAt
    }
}

// One frozen snapshot per (league, season). Created by complete_league_season
// RPC. standings is a serialized [StandingsRow] for display without recomputing.
struct LeagueSeasonArchive: Identifiable, Hashable {
    let id: String
    let leagueID: String
    let season: Int
    let standings: [StandingsRow]
    let scoringLeaderTeamID: String?
    let scoringLeaderTeamName: String?
    let archivedAt: Date
}

// Wire payload for the write_league_matchups RPC. Constructed app-side
// when the commish completes a season, since per-week scores depend on
// the league's scoring config and roster snapshots.
struct LeagueMatchupArchive: Hashable {
    let week: Int
    let homeTeamID: String
    let awayTeamID: String
    let homeUserID: String?
    let awayUserID: String?
    let homePoints: Double
    let awayPoints: Double
}

// One row from the play-by-play table. Every field except game_id /
// play_id / season / week is optional because the historical rows synced
// under the slim schema have null for the expansion columns.
struct Play: Identifiable, Hashable {
    let gameID: String
    let playID: Int
    let season: Int
    let week: Int
    let posteam: String?
    let defteam: String?
    let playType: String?
    let description: String?
    let passerPlayerID: String?
    let receiverPlayerID: String?
    let rusherPlayerID: String?
    let tdPlayerID: String?
    let yardsGained: Double?
    let touchdown: Bool?
    let epa: Double?
    let qtr: Int?
    let down: Int?
    let ydstogo: Int?
    let yardline100: Int?
    let posteamScore: Int?
    let defteamScore: Int?
    let gameSecondsRemaining: Int?
    let drive: Int?
    let completePass: Bool?
    let passAttempt: Bool?
    let rushAttempt: Bool?
    let fieldGoalAttempt: Bool?
    let fieldGoalResult: String?
    let extraPointAttempt: Bool?
    let extraPointResult: String?
    let twoPointAttempt: Bool?
    let interception: Bool?
    let fumble: Bool?
    let fumbleLost: Bool?
    let firstDown: Bool?
    let sack: Bool?
    let penalty: Bool?
    let penaltyYards: Int?
    let airYards: Double?
    let yardsAfterCatch: Double?
    let passLocation: String?   // "left" / "middle" / "right"
    let runLocation: String?    // "left" / "middle" / "right"
    let runGap: String?         // "end" / "tackle" / "guard"

    var id: String { "\(gameID)-\(playID)" }
}

// One posted message in a league's chat. Username is joined in at fetch
// time; nil for messages whose author's profile has been deleted.
// imageURL is set when the user attached a photo; content may be empty in
// that case (image-only post).
struct LeagueMessage: Identifiable, Hashable, Sendable {
    let id: String
    let leagueID: String
    let userID: String
    let username: String?
    let content: String
    let imageURL: String?
    let createdAt: Date
}

// One emoji reaction on a chat message. Composite identity (message, user,
// emoji) — a user can react with multiple distinct emojis on the same
// message, but only one of each.
struct LeagueMessageReaction: Identifiable, Hashable, Sendable {
    let messageID: String
    let userID: String
    let emoji: String
    var id: String { "\(messageID)|\(userID)|\(emoji)" }
}

// Combined chat transcript: messages plus all their reactions, fetched in
// a single round-trip so the chat opens with full state.
struct LeagueChatLoad: Sendable {
    let messages: [LeagueMessage]
    let reactions: [String: [LeagueMessageReaction]]
}

// One historical matchup between two users (head-to-head view).
struct HeadToHeadEntry: Hashable, Identifiable {
    var id: String { "\(season)-\(week)-\(myTeamID)" }
    let season: Int
    let week: Int
    let myTeamID: String
    let opponentTeamID: String
    let opponentUsername: String?
    let myPoints: Double
    let opponentPoints: Double
    var result: String {
        if myPoints > opponentPoints { return "W" }
        if myPoints < opponentPoints { return "L" }
        return "T"
    }
}

struct LeagueSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let season: Int
    let scoring: Scoring
    let teamCount: Int
    let createdAt: Date
    let joinCode: String
    let creatorID: String
    let isTest: Bool
}

struct Profile: Identifiable, Hashable {
    let id: String
    let username: String
}

struct Session: Hashable {
    let userID: String
    let profile: Profile
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

enum TransactionKind: String, Codable, Hashable {
    case add, drop
    case addDrop = "add_drop"
    case waiverClaim = "waiver_claim"
    case trade

    var label: String {
        switch self {
        case .add:         return "Added"
        case .drop:        return "Dropped"
        case .addDrop:     return "Add / Drop"
        case .waiverClaim: return "Waiver claim"
        case .trade:       return "Trade"
        }
    }
}

enum TransactionStatus: String, Codable, Hashable {
    case completed
    case pendingApproval = "pending_approval"
    case rejected
    case failed

    var label: String {
        switch self {
        case .completed:       return "Completed"
        case .pendingApproval: return "Pending approval"
        case .rejected:        return "Rejected"
        case .failed:          return "Failed"
        }
    }
}

enum WaiverClaimStatus: String, Codable, Hashable {
    case pending, processed, failed, cancelled
}

struct LeagueTransaction: Identifiable, Hashable {
    let id: String
    let leagueID: String
    let teamID: String
    let teamName: String
    let kind: TransactionKind
    let addPlayerID: String?
    let dropPlayerID: String?
    let status: TransactionStatus
    let note: String?
    let createdAt: Date
    let resolvedAt: Date?
}

struct WaiverClaim: Identifiable, Hashable {
    let id: String
    let leagueID: String
    let teamID: String
    let teamName: String
    let addPlayerID: String
    let dropPlayerID: String?
    let teamPriority: Int           // ordering within this team's stack of claims
    let status: WaiverClaimStatus
    let failureReason: String?
    let createdAt: Date
    let processedAt: Date?
}

struct DroppedPlayer: Identifiable, Hashable {
    let leagueID: String
    let playerID: String
    let droppedAt: Date
    let waiverUntil: Date

    var id: String { "\(leagueID)-\(playerID)" }
    var isOnWaivers: Bool { waiverUntil > Date() }
}

enum TradeApprovalMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case none
    case commissioner
    case leagueVote = "league_vote"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:         return "None (instant)"
        case .commissioner: return "Commissioner approval"
        case .leagueVote:   return "League vote (veto)"
        }
    }
}

enum TradeStatus: String, Codable, Hashable {
    case pending
    case accepted
    case pendingApproval   = "pending_approval"
    case voting
    case pendingExecution  = "pending_execution"
    case executed
    case rejected
    case cancelled
    case countered
    case vetoed

    var label: String {
        switch self {
        case .pending:           return "Pending"
        case .accepted:          return "Accepted"
        case .pendingApproval:   return "Awaiting commissioner"
        case .voting:            return "In league vote"
        case .pendingExecution:  return "Pending execution"
        case .executed:          return "Executed"
        case .rejected:          return "Rejected"
        case .cancelled:         return "Cancelled"
        case .countered:         return "Countered"
        case .vetoed:            return "Vetoed"
        }
    }

    var isOpen: Bool {
        switch self {
        case .pending, .accepted, .pendingApproval, .voting, .pendingExecution: return true
        default: return false
        }
    }
}

struct Trade: Identifiable, Hashable {
    let id: String
    let leagueID: String
    let proposerTeamID: String
    let recipientTeamID: String
    let proposerPlayerIDs: [String]
    let recipientPlayerIDs: [String]
    let note: String?
    let parentTradeID: String?
    let status: TradeStatus
    let votingEndsAt: Date?
    let acceptedAt: Date?
    let executedAt: Date?
    let resolvedAt: Date?
    let failureReason: String?
    let createdAt: Date
}

struct TradeVote: Hashable {
    let tradeID: String
    let teamID: String
    let vote: String     // "approve" | "veto"
    let votedAt: Date
}

enum DraftFormat: String, Codable, CaseIterable, Identifiable, Hashable {
    case snake, linear
    var id: String { rawValue }
    var label: String { self == .snake ? "Snake" : "Linear" }
}

enum DraftStatus: String, Codable, Hashable {
    case scheduled, live, paused, complete
}

struct Draft: Identifiable, Hashable {
    let id: String
    let leagueID: String
    var format: DraftFormat
    var status: DraftStatus
    var pickSeconds: Int
    var startsAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var currentPick: Int       // 1-indexed; 0 = not started
    var totalPicks: Int
    var pickDeadline: Date?
    var pickOrder: [String]    // ordered team-id strings (round 1)
    var pausedRemaining: Int?
    var autoPickTeamIDs: [String]  // teams whose picks fire automatically

    func isOnAutoPick(teamID: String) -> Bool {
        // Why: pick_order stores team IDs in Swift's UUID.uuidString format
        // (uppercase) but auto_pick_team_ids is populated server-side via
        // `p_team_id::text` which Postgres lowercases. Compare case-insensitively
        // so the two conventions interoperate.
        autoPickTeamIDs.contains { $0.caseInsensitiveCompare(teamID) == .orderedSame }
    }

    // Which team is on the clock for the given 1-indexed pick number, given
    // the round-1 pick_order. Mirrors the Postgres team_on_clock() helper.
    func teamOnClock(forPick pick: Int) -> String? {
        let teamCount = pickOrder.count
        guard teamCount > 0, pick >= 1, pick <= totalPicks else { return nil }
        let roundIdx    = (pick - 1) / teamCount
        var posInRound  = (pick - 1) % teamCount
        if format == .snake && roundIdx.isMultiple(of: 2) == false {
            posInRound = teamCount - 1 - posInRound
        }
        return pickOrder[posInRound]
    }

    var currentRound: Int {
        let teamCount = max(pickOrder.count, 1)
        return ((currentPick - 1) / teamCount) + 1
    }
}

struct DraftPick: Identifiable, Hashable {
    let id: String
    let draftID: String
    let pickNumber: Int
    let teamID: String
    let playerID: String
    let autoPick: Bool
    let pickedAt: Date
}

// MARK: - NFL data (stats overhaul Phase 1)

enum NFLGameStatus: String, Codable, Hashable {
    case scheduled, inProgress = "in_progress", final
}

struct NFLGame: Identifiable, Hashable {
    let gameID: String
    let season: Int
    let week: Int
    let home: String
    let away: String
    let kickoff: Date?
    let homeScore: Int?
    let awayScore: Int?
    let status: NFLGameStatus
    // MFL convention: negative when home is favored. e.g. -7.5 means home
    // team favored by 7.5. Nil when no betting line is published yet.
    let homeSpread: Double?
    // Vegas O/U total points. Nil for historical games where we haven't
    // backfilled this column.
    let total: Double?
    // Game-time conditions, from nflverse schedules (historical only).
    let tempF: Int?
    let windMph: Int?
    let precipitation: String?    // "rain", "snow", "clear"
    let roof: String?             // "outdoors", "dome", "closed", "open"
    let surface: String?

    var id: String { gameID }

    func opponent(of team: String) -> String? {
        if team == home { return away }
        if team == away { return home }
        return nil
    }
    func isHome(team: String) -> Bool { team == home }

    // Spread normalized to a specific team's perspective. Negative = favored.
    func spread(for team: String) -> Double? {
        guard let s = homeSpread else { return nil }
        if team == home { return s }
        if team == away { return -s }
        return nil
    }

    // Implied team total = O/U +/- spread. Useful as a game-script proxy.
    func impliedTotal(for team: String) -> Double? {
        guard let t = total, let s = spread(for: team) else { return nil }
        return (t / 2) - (s / 2)
    }

    // Stadium is indoors / closed roof — weather irrelevant.
    var isIndoor: Bool {
        guard let r = roof?.lowercased() else { return false }
        return r == "dome" || r == "closed"
    }
}

// Per-team rolling offense/defense ranks from MFL (1 = best, 32 = worst).
// Nil for individual columns when MFL hasn't ranked yet (off-season).
struct TeamRanks: Hashable {
    let team: String
    let passOffense: Int?
    let rushOffense: Int?
    let passDefense: Int?
    let rushDefense: Int?
}

struct NFLTeamMeta: Identifiable, Hashable {
    let abbr: String
    let fullName: String
    let conference: String
    let division: String
    let primaryColor: String?
    let secondaryColor: String?
    let logoURL: String?

    var id: String { abbr }
}

struct SnapCount: Hashable {
    let playerID: String
    let season: Int
    let week: Int
    let team: String
    let offenseSnaps: Int
    let offensePct: Double   // 0-100
}

enum Trend: String, Hashable {
    case up, flat, down

    var systemImage: String {
        switch self {
        case .up:   return "arrow.up.right"
        case .flat: return "arrow.right"
        case .down: return "arrow.down.right"
        }
    }
}

struct DvPEntry: Hashable {
    let team: String
    let pointsAllowed: Double
    let rank: Int            // 1 = worst defense (most points allowed)
}

enum MatchupRating: String, Hashable {
    case green, yellow, red, unknown

    static func from(rank: Int?, teamCount: Int = 32) -> MatchupRating {
        guard let rank else { return .unknown }
        if rank <= 8 { return .green }
        if rank > 22 { return .red }
        return .yellow
    }

    var label: String {
        switch self {
        case .green:   return "GOOD"
        case .yellow:  return "AVG"
        case .red:     return "TOUGH"
        case .unknown: return "—"
        }
    }
}

struct TrendingPlayer: Identifiable, Hashable {
    let playerID: String
    // Percent of MFL leagues that added / dropped this player in the last
    // ~24h. e.g. 23.4 means 23.4% of leagues. Used to be Int counts from our
    // own users' transactions; swapped to MFL market-wide percentages.
    let adds: Double
    let drops: Double
    var id: String { playerID }

    var net: Double { adds - drops }
}

// Current injury, mirrored from MFL's injuries endpoint into public.injuries.
// Healthy players have no Injury (no row in the table).
struct Injury: Hashable {
    let playerID: String
    let status: String         // "Out", "Questionable", "Doubtful", "IR", "PUP", etc.
    let details: String?       // e.g. "Knee - ACL"
    let expectedReturn: Date?

    // Short label for compact badges (Q/D/O/IR/PUP/SUSP, etc).
    var badge: String {
        let s = status.uppercased()
        switch s {
        case "QUESTIONABLE":          return "Q"
        case "DOUBTFUL":              return "D"
        case "OUT":                   return "O"
        case "IR", "INJURED RESERVE": return "IR"
        case "PUP":                   return "PUP"
        case "SUSPENDED":             return "SUSP"
        default:                      return String(s.prefix(3))
        }
    }
}

// Depth chart entry at a specific (season, week, team). depth = 1 is the
// starter, 2 is the immediate backup, etc.
struct DepthChartEntry: Hashable {
    let playerID: String
    let team: String
    let position: String
    let depth: Int
}

// Player marked inactive for a specific (season, week). status codes come
// from nflverse weekly_rosters: RES, IR, PUP, SUS, EXE, etc.
struct InactiveEntry: Hashable {
    let playerID: String
    let status: String
    let reason: String?
}

struct PositionRank: Hashable {
    let position: String
    let rank: Int
    let totalAtPosition: Int
    let seasonPoints: Double

    var label: String { "\(position.uppercased())\(rank)" }
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
