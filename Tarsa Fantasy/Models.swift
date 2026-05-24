import Foundation

enum AppTab: String, Hashable { case league, lineup, matchup, players }

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
    case qb = "QB", rb = "RB", wr = "WR", te = "TE", flex = "FLEX", k = "K", def = "DEF", bench = "BN", ir = "IR"
    var id: String { rawValue }
    var label: String { rawValue }
    // Only lineup slots that contribute points each week. Bench and IR sit out.
    var isStarter: Bool { self != .bench && self != .ir }

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
        case .ir:    return true
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
    // Injured-reserve slots. Extra capacity beyond the active roster that only
    // accepts injured (OUT/IR/PUP/etc.) players. IR players never score and
    // aren't drafted into; membership is tracked on FantasyTeam.ir.
    var ir: Int

    static let `default` = RosterConfig(qb: 1, rb: 2, wr: 2, te: 1, flex: 1, k: 1, def: 1, bench: 6, ir: 0)

    var starterCount: Int { qb + rb + wr + te + flex + k + def }
    // Active roster size (starters + bench). Drives drafting and roster limits.
    // IR is deliberately excluded — IR players sit outside the active roster.
    var totalSize: Int { starterCount + bench }
    // Active roster plus IR — the maximum number of players a team can hold.
    var fullSize: Int { totalSize + ir }

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
         flex: Int = 1, k: Int = 1, def: Int = 1, bench: Int = 6, ir: Int = 0) {
        self.qb = qb; self.rb = rb; self.wr = wr; self.te = te
        self.flex = flex; self.k = k; self.def = def; self.bench = bench; self.ir = ir
    }

    private enum CodingKeys: String, CodingKey { case qb, rb, wr, te, flex, k, def, bench, ir }

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
        ir    = try c.decodeIfPresent(Int.self, forKey: .ir)    ?? 0
    }
}

// Per-stat fantasy scoring. The three named presets reproduce nflverse's
// standard formula (PPR adds 1/reception, Half-PPR 0.5). A league with a
// non-nil `scoringSettings` computes points from each Game's raw stat line
// instead of the precomputed fantasyPoints fields, which is what makes fully
// custom scoring possible. `Scoring` (the preset enum) is still the carrier
// everywhere; settings refine it when present.
struct ScoringSettings: Codable, Hashable {
    var passingYardsPerPoint: Double    // yards needed for 1 point (e.g. 25 → 0.04/yd)
    var passingTD: Double
    var interception: Double
    var rushingYardsPerPoint: Double    // yards per point (e.g. 10 → 0.1/yd)
    var rushingTD: Double
    var receivingYardsPerPoint: Double  // yards per point
    var receivingTD: Double
    var reception: Double               // PPR knob
    var fumbleLost: Double
    // Kicking. Field goals score by distance; PATs and misses are flat.
    var fgUnder40: Double               // FG 0–39 yds
    var fg40to49: Double
    var fg50plus: Double
    var patMade: Double
    var fgMissed: Double                // penalty per missed FG (negative)
    var patMissed: Double               // penalty per missed PAT (negative)
    // Team defense (DST). Event values are per-occurrence; the points-allowed
    // tier bonus is standard (Game.pointsAllowedBonus).
    var defSack: Double
    var defInterception: Double
    var defFumbleRecovery: Double
    var defTouchdown: Double
    var defSafety: Double

    static let standard = ScoringSettings(
        passingYardsPerPoint: 25, passingTD: 4, interception: -2,
        rushingYardsPerPoint: 10, rushingTD: 6,
        receivingYardsPerPoint: 10, receivingTD: 6,
        reception: 0, fumbleLost: -2
    )
    static var ppr: ScoringSettings  { var s = standard; s.reception = 1.0; return s }
    static var half: ScoringSettings { var s = standard; s.reception = 0.5; return s }

    static func preset(_ scoring: Scoring) -> ScoringSettings {
        switch scoring {
        case .standard: return .standard
        case .ppr:      return .ppr
        case .half:     return .half
        }
    }

    private func perYard(_ divisor: Double) -> Double { divisor > 0 ? 1.0 / divisor : 0 }

    func points(passingYards: Double, passingTDs: Double, interceptions: Double,
                rushingYards: Double, rushingTDs: Double,
                receivingYards: Double, receivingTDs: Double,
                receptions: Double, fumblesLost: Double) -> Double {
        var total = passingYards * perYard(passingYardsPerPoint)
        total += passingTDs * passingTD
        total += interceptions * interception
        total += rushingYards * perYard(rushingYardsPerPoint)
        total += rushingTDs * rushingTD
        total += receivingYards * perYard(receivingYardsPerPoint)
        total += receivingTDs * receivingTD
        total += receptions * reception
        total += fumblesLost * fumbleLost
        return total
    }

    // Whether these settings match the named preset exactly. When they do, the
    // league can keep using the precomputed nflverse fields (which also include
    // 2-pt conversions / return TDs that the raw Game line omits).
    func matchesPreset(_ scoring: Scoring) -> Bool { self == ScoringSettings.preset(scoring) }

    private enum CodingKeys: String, CodingKey {
        case passingYardsPerPoint, passingTD, interception,
             rushingYardsPerPoint, rushingTD, receivingYardsPerPoint,
             receivingTD, reception, fumbleLost,
             fgUnder40, fg40to49, fg50plus, patMade, fgMissed, patMissed,
             defSack, defInterception, defFumbleRecovery, defTouchdown, defSafety
    }

    // New params default to standard K/DST so existing call sites (the offense
    // presets) and decoded leagues pick up the defensive/kicking weights for free.
    init(passingYardsPerPoint: Double, passingTD: Double, interception: Double,
         rushingYardsPerPoint: Double, rushingTD: Double,
         receivingYardsPerPoint: Double, receivingTD: Double,
         reception: Double, fumbleLost: Double,
         fgUnder40: Double = 3, fg40to49: Double = 4, fg50plus: Double = 5,
         patMade: Double = 1, fgMissed: Double = -1, patMissed: Double = -1,
         defSack: Double = 1, defInterception: Double = 2, defFumbleRecovery: Double = 2,
         defTouchdown: Double = 6, defSafety: Double = 2) {
        self.passingYardsPerPoint = passingYardsPerPoint
        self.passingTD = passingTD
        self.interception = interception
        self.rushingYardsPerPoint = rushingYardsPerPoint
        self.rushingTD = rushingTD
        self.receivingYardsPerPoint = receivingYardsPerPoint
        self.receivingTD = receivingTD
        self.reception = reception
        self.fumbleLost = fumbleLost
        self.fgUnder40 = fgUnder40
        self.fg40to49 = fg40to49
        self.fg50plus = fg50plus
        self.patMade = patMade
        self.fgMissed = fgMissed
        self.patMissed = patMissed
        self.defSack = defSack
        self.defInterception = defInterception
        self.defFumbleRecovery = defFumbleRecovery
        self.defTouchdown = defTouchdown
        self.defSafety = defSafety
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScoringSettings.standard
        passingYardsPerPoint   = try c.decodeIfPresent(Double.self, forKey: .passingYardsPerPoint)   ?? d.passingYardsPerPoint
        passingTD              = try c.decodeIfPresent(Double.self, forKey: .passingTD)               ?? d.passingTD
        interception           = try c.decodeIfPresent(Double.self, forKey: .interception)           ?? d.interception
        rushingYardsPerPoint   = try c.decodeIfPresent(Double.self, forKey: .rushingYardsPerPoint)   ?? d.rushingYardsPerPoint
        rushingTD              = try c.decodeIfPresent(Double.self, forKey: .rushingTD)               ?? d.rushingTD
        receivingYardsPerPoint = try c.decodeIfPresent(Double.self, forKey: .receivingYardsPerPoint) ?? d.receivingYardsPerPoint
        receivingTD            = try c.decodeIfPresent(Double.self, forKey: .receivingTD)            ?? d.receivingTD
        reception              = try c.decodeIfPresent(Double.self, forKey: .reception)              ?? d.reception
        fumbleLost             = try c.decodeIfPresent(Double.self, forKey: .fumbleLost)             ?? d.fumbleLost
        fgUnder40         = try c.decodeIfPresent(Double.self, forKey: .fgUnder40)         ?? d.fgUnder40
        fg40to49          = try c.decodeIfPresent(Double.self, forKey: .fg40to49)          ?? d.fg40to49
        fg50plus          = try c.decodeIfPresent(Double.self, forKey: .fg50plus)          ?? d.fg50plus
        patMade           = try c.decodeIfPresent(Double.self, forKey: .patMade)           ?? d.patMade
        fgMissed          = try c.decodeIfPresent(Double.self, forKey: .fgMissed)          ?? d.fgMissed
        patMissed         = try c.decodeIfPresent(Double.self, forKey: .patMissed)         ?? d.patMissed
        defSack           = try c.decodeIfPresent(Double.self, forKey: .defSack)           ?? d.defSack
        defInterception   = try c.decodeIfPresent(Double.self, forKey: .defInterception)   ?? d.defInterception
        defFumbleRecovery = try c.decodeIfPresent(Double.self, forKey: .defFumbleRecovery) ?? d.defFumbleRecovery
        defTouchdown      = try c.decodeIfPresent(Double.self, forKey: .defTouchdown)      ?? d.defTouchdown
        defSafety         = try c.decodeIfPresent(Double.self, forKey: .defSafety)         ?? d.defSafety
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
    // Kicking inputs (made FGs bucketed by distance + PATs + misses). Non-zero
    // only on kicker rows; nflverse's fantasy_points is offense-only, so kicker
    // points are computed here from these instead.
    var fieldGoals0_19: Double = 0
    var fieldGoals20_29: Double = 0
    var fieldGoals30_39: Double = 0
    var fieldGoals40_49: Double = 0
    var fieldGoals50_59: Double = 0
    var fieldGoals60Plus: Double = 0
    var fieldGoalsMissed: Double = 0
    var extraPointsMade: Double = 0
    var extraPointsMissed: Double = 0
    // Team-defense (DST) inputs, aggregated per team-week onto the DEF_<TEAM>
    // row. `pointsAllowed` is non-nil only on those rows — it both feeds the
    // points-allowed tier and flags the row as a team defense.
    var defSacks: Double = 0
    var defInterceptions: Double = 0
    var defFumbleRecoveries: Double = 0
    var defTouchdowns: Double = 0
    var defSafeties: Double = 0
    var pointsAllowed: Double? = nil

    var id: String { "\(season)-\(week)-\(team)" }

    // Offensive points from nflverse's precomputed field for the named preset.
    private func presetBase(_ scoring: Scoring) -> Double {
        switch scoring {
        case .standard: return fantasyPoints
        case .ppr:      return fantasyPointsPPR
        case .half:     return fantasyPointsHalfPPR
        }
    }

    func points(scoring: Scoring) -> Double {
        presetBase(scoring) + specialPoints
    }

    func points(settings: ScoringSettings) -> Double {
        settings.points(
            passingYards: passingYards, passingTDs: passingTDs,
            interceptions: passingInterceptions,
            rushingYards: rushingYards, rushingTDs: rushingTDs,
            receivingYards: receivingYards, receivingTDs: receivingTDs,
            receptions: receptions, fumblesLost: fumblesLost
        ) + specialPoints(settings)
    }

    // Single funnel for league scoring: when custom settings are present and
    // they differ from the named preset, compute from the raw stat line;
    // otherwise fall back to nflverse's precomputed field for the preset.
    func points(scoring: Scoring, settings: ScoringSettings?) -> Double {
        if let settings, !settings.matchesPreset(scoring) {
            return points(settings: settings)
        }
        return points(scoring: scoring)
    }

    // Kicker + team-defense points from the raw stat line, position-independent:
    // any player credited with the action scores it (a kicker who runs scores
    // rushing via the offensive path; a TE who kicks scores the FG here). Each
    // game row carries stats for one role, so at most one term is non-zero.
    func specialPoints(_ s: ScoringSettings) -> Double { kickerPoints(s) + defensePoints(s) }

    // Default (standard-weight) special points — used by season aggregation,
    // which is league-agnostic. Per-game league scoring threads real settings.
    var specialPoints: Double { specialPoints(.standard) }

    // Distance-tiered kicker scoring driven by the league's settings.
    func kickerPoints(_ s: ScoringSettings) -> Double {
        (fieldGoals0_19 + fieldGoals20_29 + fieldGoals30_39) * s.fgUnder40
            + fieldGoals40_49 * s.fg40to49
            + (fieldGoals50_59 + fieldGoals60Plus) * s.fg50plus
            + extraPointsMade * s.patMade
            + fieldGoalsMissed * s.fgMissed
            + extraPointsMissed * s.patMissed
    }

    // Team-defense scoring. Only DST rows (non-nil pointsAllowed) score; event
    // values come from the league settings, plus the points-allowed tier bonus.
    func defensePoints(_ s: ScoringSettings) -> Double {
        guard let pa = pointsAllowed else { return 0 }
        return defSacks * s.defSack
            + defInterceptions * s.defInterception
            + defFumbleRecoveries * s.defFumbleRecovery
            + defTouchdowns * s.defTouchdown
            + defSafeties * s.defSafety
            + Game.pointsAllowedBonus(pa)
    }

    static func pointsAllowedBonus(_ pointsAllowed: Double) -> Double {
        switch pointsAllowed {
        case ..<1:   return 10   // shutout
        case ..<7:   return 7
        case ..<14:  return 4
        case ..<21:  return 1
        case ..<28:  return 0
        case ..<35:  return -1
        default:     return -4
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

// One entry in a player's nickname history — the nickname a fantasy team gave
// them, the team/league it came from, and whether it's still active (the
// player is still on that roster) or was archived when they were dropped.
struct NicknameHistoryEntry: Identifiable, Hashable, Sendable {
    let nickname: String
    let teamName: String
    let leagueName: String
    let createdAt: Date
    let clearedAt: Date?

    var isActive: Bool { clearedAt == nil }
    var id: String { "\(teamName)|\(nickname)|\(createdAt.timeIntervalSince1970)" }
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
    // Summed per-game kicker/DST points. Kept as a running sum (not recomputed
    // from totaled raw stats) because the DST points-allowed tier is per-game,
    // not additive — summing 30 points allowed across a season ≠ one tier.
    var specialPoints: Double = 0

    func points(scoring: Scoring) -> Double {
        let base: Double
        switch scoring {
        case .standard: base = fantasyPoints
        case .ppr:      base = fantasyPointsPPR
        case .half:     base = fantasyPointsHalfPPR
        }
        return base + specialPoints
    }

    func points(settings: ScoringSettings) -> Double {
        settings.points(
            passingYards: passingYards, passingTDs: passingTDs,
            interceptions: passingInterceptions,
            rushingYards: rushingYards, rushingTDs: rushingTDs,
            receivingYards: receivingYards, receivingTDs: receivingTDs,
            receptions: receptions, fumblesLost: fumblesLost
        ) + specialPoints
    }

    func points(scoring: Scoring, settings: ScoringSettings?) -> Double {
        if let settings, !settings.matchesPreset(scoring) {
            return points(settings: settings)
        }
        return points(scoring: scoring)
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
    // Player IDs parked on injured reserve. A subset of `roster`; these never
    // score and don't count against the active roster size.
    var ir: [String]
    // Per-week frozen lineups, keyed by fantasy week. When a week has an entry,
    // that week is scored from it (the lineup the manager locked in for that
    // week); weeks without an entry fall back to the live `starters`. This is
    // what keeps editing next week's lineup from rewriting past results.
    var weeklyLineups: [Int: [String]]
    // Division index into League.divisionNames, or nil when the league has no
    // divisions configured.
    var division: Int?
    // Team branding. logoURL points at an uploaded image; colorHex is a
    // "#RRGGBB" accent used for the team's chrome. abbreviation is a short
    // (≤4 char) tag for compact contexts. All nil = use defaults.
    var logoURL: String?
    var colorHex: String?
    var abbreviation: String?

    init(id: String, name: String, roster: [String] = [],
         starters: [String] = [], ownerID: String? = nil,
         ir: [String] = [], weeklyLineups: [Int: [String]] = [:],
         division: Int? = nil,
         logoURL: String? = nil, colorHex: String? = nil,
         abbreviation: String? = nil) {
        self.id = id; self.name = name; self.roster = roster
        self.starters = starters; self.ownerID = ownerID
        self.ir = ir; self.weeklyLineups = weeklyLineups; self.division = division
        self.logoURL = logoURL; self.colorHex = colorHex
        self.abbreviation = abbreviation
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, roster, starters, ownerID, ir, weeklyLineups, division, logoURL, colorHex, abbreviation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(String.self, forKey: .id)
        name     = try c.decode(String.self, forKey: .name)
        roster   = try c.decodeIfPresent([String].self, forKey: .roster)   ?? []
        starters = try c.decodeIfPresent([String].self, forKey: .starters) ?? []
        ownerID  = try c.decodeIfPresent(String.self, forKey: .ownerID)
        ir       = try c.decodeIfPresent([String].self, forKey: .ir)       ?? []
        weeklyLineups = try c.decodeIfPresent([Int: [String]].self, forKey: .weeklyLineups) ?? [:]
        division = try c.decodeIfPresent(Int.self, forKey: .division)
        logoURL  = try c.decodeIfPresent(String.self, forKey: .logoURL)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        abbreviation = try c.decodeIfPresent(String.self, forKey: .abbreviation)
    }

    // The short tag for compact contexts (scoreboard, bracket), or nil when
    // the owner hasn't set one. Trimmed; empty is treated as unset.
    var displayAbbreviation: String? {
        guard let a = abbreviation?.trimmingCharacters(in: .whitespacesAndNewlines),
              !a.isEmpty else { return nil }
        return a
    }

    // What to show in tight spaces: the abbreviation if set, else the name.
    var shortLabel: String { displayAbbreviation ?? name }
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
    // Number of head-to-head weeks before the postseason. The stored `schedule`
    // covers exactly these weeks; playoff weeks are derived, not stored.
    var regularSeasonWeeks: Int
    // How many top teams make the playoffs (0 = no postseason). Bracket math
    // (byes, rounds, start week) lives in Fantasy.playoffBracket.
    var playoffTeams: Int
    // Re-seed each round (higher seed always faces lowest remaining) vs. a
    // fixed bracket.
    var playoffReseed: Bool
    // Custom per-stat scoring. Nil = use the `scoring` preset's precomputed
    // fields. Non-nil overrides scoring league-wide.
    var scoringSettings: ScoringSettings?
    // Division names (empty = single division / no divisions). Teams reference
    // these by index via FantasyTeam.division.
    var divisionNames: [String]
    // Frozen champion once the postseason completes (set by completeLeagueSeason).
    var championTeamID: String?
    var championTeamName: String?

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
         seasonCompletedAt: Date? = nil,
         regularSeasonWeeks: Int? = nil,
         playoffTeams: Int = 6,
         playoffReseed: Bool = true,
         scoringSettings: ScoringSettings? = nil,
         divisionNames: [String] = [],
         championTeamID: String? = nil,
         championTeamName: String? = nil) {
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
        // Fall back to the stored schedule length so legacy leagues (created
        // before configurable seasons) keep their original regular-season span.
        self.regularSeasonWeeks = regularSeasonWeeks ?? schedule.count
        self.playoffTeams = playoffTeams
        self.playoffReseed = playoffReseed
        self.scoringSettings = scoringSettings
        self.divisionNames = divisionNames
        self.championTeamID = championTeamID
        self.championTeamName = championTeamName
    }

    // Effective scoring used by league computations: custom settings if set,
    // otherwise the named preset mapped to its weights.
    var effectiveScoringSettings: ScoringSettings {
        scoringSettings ?? ScoringSettings.preset(scoring)
    }

    var hasDivisions: Bool { divisionNames.count >= 2 }

    // First postseason week (one past the regular season). Only meaningful
    // when playoffTeams > 0.
    var playoffStartWeek: Int { regularSeasonWeeks + 1 }
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
    let championTeamID: String?
    let championTeamName: String?
    let archivedAt: Date

    init(id: String, leagueID: String, season: Int, standings: [StandingsRow],
         scoringLeaderTeamID: String?, scoringLeaderTeamName: String?,
         championTeamID: String? = nil, championTeamName: String? = nil,
         archivedAt: Date) {
        self.id = id; self.leagueID = leagueID; self.season = season
        self.standings = standings
        self.scoringLeaderTeamID = scoringLeaderTeamID
        self.scoringLeaderTeamName = scoringLeaderTeamName
        self.championTeamID = championTeamID
        self.championTeamName = championTeamName
        self.archivedAt = archivedAt
    }
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

// The kind of a chat message. `text` is a normal text/image post; the rest
// are structured cards whose data lives in `LeagueMessage.payload`.
enum MessageKind: String, Codable, Hashable, Sendable {
    case text, poll, pickem, tradeblock
}

// One NFL game offered in a pick'em card, captured from the real schedule at
// creation time so the card renders without re-fetching. The two pickable
// outcomes are the away team (option 0) and the home team (option 1). Kickoff
// is epoch seconds so it round-trips through every JSON decoder without
// depending on a date-decoding strategy.
struct PickGame: Codable, Hashable, Sendable, Identifiable {
    var id: String          // NFL game id
    var week: Int
    var away: String        // away team abbreviation
    var home: String        // home team abbreviation
    var awayName: String?   // full team name for display (falls back to abbr)
    var homeName: String?
    var kickoff: Double?    // epoch seconds; nil if unscheduled

    init(id: String, week: Int, away: String, home: String,
         awayName: String? = nil, homeName: String? = nil, kickoff: Double? = nil) {
        self.id = id; self.week = week
        self.away = away; self.home = home
        self.awayName = awayName; self.homeName = homeName
        self.kickoff = kickoff
    }
}

// Type-specific data for a structured chat message, stored as jsonb. All
// fields are optional — which ones are populated depends on MessageKind:
//   poll       : question + options (+ allowMultiple / allowAddOptions / closesAt)
//   pickem     : question (title) + games (+ closesAt)
//   tradeblock : players (offering, display names) + seeking + note + teamName
struct ChatPayload: Codable, Hashable, Sendable {
    var question: String?
    var options: [String]?
    var players: [String]?
    var seeking: [String]?
    var note: String?
    var teamName: String?
    var games: [PickGame]?
    var allowMultiple: Bool?     // poll: voters may pick more than one option
    var allowAddOptions: Bool?   // poll: any member may append an option
    var closesAt: Double?        // epoch seconds; voting locks after — nil = open

    init(question: String? = nil, options: [String]? = nil,
         players: [String]? = nil, seeking: [String]? = nil,
         note: String? = nil, teamName: String? = nil,
         games: [PickGame]? = nil, allowMultiple: Bool? = nil,
         allowAddOptions: Bool? = nil, closesAt: Double? = nil) {
        self.question = question
        self.options = options
        self.players = players
        self.seeking = seeking
        self.note = note
        self.teamName = teamName
        self.games = games
        self.allowMultiple = allowMultiple
        self.allowAddOptions = allowAddOptions
        self.closesAt = closesAt
    }
}

// One posted message in a league's chat. Username is joined in at fetch
// time; nil for messages whose author's profile has been deleted.
// imageURL is set when the user attached a photo; content may be empty in
// that case (image-only post). `kind`/`payload` describe structured cards
// (polls, pick'ems, trade blocks); for plain messages kind is .text.
struct LeagueMessage: Identifiable, Hashable, Sendable {
    let id: String
    let leagueID: String
    let userID: String
    let username: String?
    let content: String
    let imageURL: String?
    let createdAt: Date
    let kind: MessageKind
    let payload: ChatPayload?

    init(id: String, leagueID: String, userID: String, username: String?,
         content: String, imageURL: String?, createdAt: Date,
         kind: MessageKind = .text, payload: ChatPayload? = nil) {
        self.id = id
        self.leagueID = leagueID
        self.userID = userID
        self.username = username
        self.content = content
        self.imageURL = imageURL
        self.createdAt = createdAt
        self.kind = kind
        self.payload = payload
    }
}

// One user's selection inside a structured message. `slot` distinguishes
// sub-questions within a single card so one user can hold several responses:
//   poll (single)  : slot 0,            choice = chosen option index
//   poll (multi)   : slot = option idx, choice = chosen option index
//   pickem         : slot = game index, choice = winner (0 away / 1 home)
// Composite identity (message, user, slot); re-voting a slot updates `choice`.
struct MessageResponse: Identifiable, Hashable, Sendable {
    let messageID: String
    let userID: String
    let slot: Int
    let choice: Int
    var id: String { "\(messageID)|\(userID)|\(slot)" }

    init(messageID: String, userID: String, slot: Int = 0, choice: Int) {
        self.messageID = messageID
        self.userID = userID
        self.slot = slot
        self.choice = choice
    }
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

// Combined chat transcript: messages plus all their reactions and structured
// responses (poll/pick'em votes), fetched in a single round-trip so the chat
// opens with full state.
struct LeagueChatLoad: Sendable {
    let messages: [LeagueMessage]
    let reactions: [String: [LeagueMessageReaction]]
    let responses: [String: [MessageResponse]]

    init(messages: [LeagueMessage],
         reactions: [String: [LeagueMessageReaction]],
         responses: [String: [MessageResponse]] = [:]) {
        self.messages = messages
        self.reactions = reactions
        self.responses = responses
    }
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

struct Profile: Identifiable, Hashable, Sendable {
    let id: String
    let username: String
    // Server-driven role flags. Default false so the many lightweight
    // `Profile(id:username:)` call sites (search results, DM inbox joins)
    // stay valid — those projections don't carry role info.
    let isAdmin: Bool
    let isTester: Bool

    init(id: String, username: String, isAdmin: Bool = false, isTester: Bool = false) {
        self.id = id
        self.username = username
        self.isAdmin = isAdmin
        self.isTester = isTester
    }
}

// In-app feedback filed by testers/admins and triaged by admins.
enum FeedbackStatus: String, Hashable, Sendable {
    case open, resolved
}

struct FeedbackItem: Identifiable, Hashable, Sendable {
    let id: String
    let userID: String
    let username: String      // joined from profiles for the review list
    let content: String
    let imageURLs: [String]
    let status: FeedbackStatus
    let createdAt: Date
}

// One message in a feedback item's discussion thread. Visible to the feedback
// author and admins; posted by either side.
struct FeedbackComment: Identifiable, Hashable, Sendable {
    let id: String
    let feedbackID: String
    let userID: String
    let username: String
    let content: String
    let createdAt: Date
}

// One row of the friendships table. Stored canonically (user_a < user_b),
// but the FriendshipStatus helpers below project it into "the other user"
// from the caller's perspective.
enum FriendshipState: String, Hashable, Sendable {
    case pending, accepted
}

struct Friendship: Hashable, Identifiable, Sendable {
    let userA: String
    let userB: String
    let requestedBy: String
    let state: FriendshipState
    let createdAt: Date
    let acceptedAt: Date?

    var id: String { "\(userA)|\(userB)" }

    func otherUserID(me: String) -> String {
        userA == me ? userB : userA
    }
}

// What the current user sees when looking at someone else's profile —
// the relevant action depends on the friendship state.
enum FriendshipStatus: Hashable, Sendable {
    case none                // no row exists
    case requestSent         // pending, current user requested
    case requestReceived     // pending, other user requested
    case friends             // accepted
}

// A DM thread (1:1 conversation). user_a < user_b by canonical ordering;
// `other(me:)` projects to the friend's userID.
struct DMThread: Identifiable, Hashable, Sendable {
    let id: String
    let userA: String
    let userB: String
    let createdAt: Date
    let lastMessageAt: Date?

    func otherUserID(me: String) -> String {
        userA == me ? userB : userA
    }
}

// One posted DM. Mirrors LeagueMessage shape — image-only allowed when
// content is empty.
struct DMMessage: Identifiable, Hashable, Sendable {
    let id: String
    let threadID: String
    let senderID: String
    let content: String
    let imageURL: String?
    let createdAt: Date
}

// One entry in the user's DM inbox: a thread plus the cached profile of
// the other participant so the conversation list can render names without
// per-row fetches.
struct DMInboxEntry: Identifiable, Hashable, Sendable {
    let thread: DMThread
    let other: Profile
    var id: String { thread.id }
}

// Aggregated "inbox" view shown in the Chat tab — leagues and DM threads
// surfaced together, sorted by recency.
enum Conversation: Identifiable, Hashable, Sendable {
    case league(LeagueSummary)
    case dm(DMInboxEntry)

    var id: String {
        switch self {
        case .league(let lg):       return "league:\(lg.id)"
        case .dm(let entry):        return "dm:\(entry.thread.id)"
        }
    }

    var sortDate: Date {
        switch self {
        case .league(let lg):       return lg.createdAt
        case .dm(let entry):        return entry.thread.lastMessageAt ?? entry.thread.createdAt
        }
    }
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
    // Division index this team belongs to (nil = league has no divisions).
    let division: Int?
    // Rank within the team's division (1-based), nil when no divisions.
    let divisionRank: Int?
    // Playoff seed (1-based) when this team currently occupies a postseason
    // slot, otherwise nil. Division winners are seeded ahead of wildcards.
    let playoffSeed: Int?

    init(id: String, name: String, wins: Int, losses: Int, ties: Int,
         pointsFor: Double, pointsAgainst: Double, games: Int, rank: Int,
         division: Int? = nil, divisionRank: Int? = nil, playoffSeed: Int? = nil) {
        self.id = id; self.name = name
        self.wins = wins; self.losses = losses; self.ties = ties
        self.pointsFor = pointsFor; self.pointsAgainst = pointsAgainst
        self.games = games; self.rank = rank
        self.division = division; self.divisionRank = divisionRank
        self.playoffSeed = playoffSeed
    }

    var record: String {
        ties > 0 ? "\(wins)-\(losses)-\(ties)" : "\(wins)-\(losses)"
    }
}

// MARK: - Playoffs (postseason bracket)

// One side of a bracket game. Either a known team, a bye, or a
// "winner of an earlier game" placeholder until that game decides.
struct PlayoffSide: Hashable {
    let teamID: String?
    let teamName: String?
    let seed: Int?
    let placeholder: String?    // "BYE", "Winner of …" — shown when teamID is nil
    let points: Double?         // weekly score once the round's games begin
    let won: Bool

    static let bye = PlayoffSide(teamID: nil, teamName: nil, seed: nil,
                                 placeholder: "BYE", points: nil, won: false)
}

struct PlayoffGame: Identifiable, Hashable {
    let id: String
    let round: Int              // 1-based
    let week: Int              // fantasy week this round is contested
    let top: PlayoffSide
    let bottom: PlayoffSide
    let played: Bool
    let winnerTeamID: String?
}

struct PlayoffRound: Identifiable, Hashable {
    let round: Int
    let week: Int
    let name: String           // "Wild Card", "Semifinals", "Championship"
    let games: [PlayoffGame]
    var id: Int { round }
}

struct PlayoffBracket: Hashable {
    let rounds: [PlayoffRound]
    let seeds: [PlayoffSeedEntry]
    let championTeamID: String?
    let championTeamName: String?
    let runnerUpTeamID: String?
    let started: Bool          // has the postseason begun (first round's week reached)?

    static let empty = PlayoffBracket(rounds: [], seeds: [], championTeamID: nil,
                                      championTeamName: nil, runnerUpTeamID: nil,
                                      started: false)
}

struct PlayoffSeedEntry: Identifiable, Hashable {
    let seed: Int
    let teamID: String
    let teamName: String
    let division: Int?
    let isDivisionWinner: Bool
    var id: String { teamID }
}

// MARK: - Player projections (baseline model)

// Tunable knobs for the projection model. Each signal can be toggled off so
// the backtest can measure its individual contribution (ablation). Defaults
// are a reasonable starting point; the admin backtest screen tunes them.
struct ProjectionConfig: Hashable {
    // Exponential weight applied per week of recency: weight = decay^(weeksAgo).
    // 1.0 = flat season average; lower = lean harder on recent games.
    var recencyDecay: Double
    // Pseudo-games of the position mean blended in (Bayesian shrinkage). Higher
    // = pull thin samples harder toward the positional baseline.
    var shrinkageGames: Double
    // Max +/- swing from the opponent defense-vs-position matchup (e.g. 0.15 →
    // best matchup ×1.15, worst ×0.85).
    var matchupRange: Double
    // League-average implied team total used as the game-script pivot.
    var scriptPivot: Double
    // Sensitivity of the game-script multiplier to implied-total deviation.
    var scriptStrength: Double
    var enableMatchup: Bool
    var enableScript: Bool
    var enableAvailability: Bool

    static let `default` = ProjectionConfig(
        recencyDecay: 0.90,
        shrinkageGames: 1.0,
        matchupRange: 0.15,
        scriptPivot: 22.5,
        scriptStrength: 0.5,
        enableMatchup: true,
        enableScript: true,
        enableAvailability: true
    )
}

// A single projected stat line for one player in one upcoming game. The
// component multipliers are surfaced so the figure is explainable, not a
// black box.
struct PlayerProjection: Identifiable, Hashable {
    let playerID: String
    let season: Int
    let week: Int
    let opponent: String
    let isHome: Bool
    let points: Double         // final projected fantasy points (chosen scoring)
    let base: Double           // recency-weighted, shrunk points/game
    let matchupMult: Double
    let scriptMult: Double
    let availability: Double   // 1 healthy, 0 out, fractional for Q/D
    let low: Double            // floor (base − recent stdev)
    let high: Double           // ceiling (base + recent stdev)
    var id: String { "\(season)-\(week)-\(playerID)" }
}

// Accuracy metrics for one position (or "ALL") from a backtest run. naiveMAE
// is the same metric for a season-average-to-date baseline, so the model only
// earns trust when mae < naiveMAE.
struct PositionAccuracy: Identifiable, Hashable {
    let position: String
    let n: Int
    let mae: Double
    let rmse: Double
    let bias: Double               // mean(projected − actual); >0 = over-projects
    let rankCorrelation: Double    // mean within-week Spearman ρ
    let naiveMAE: Double
    var id: String { position }
    // Positive = model beats the naive season-average baseline.
    var improvement: Double { Fantasy.round2(naiveMAE - mae) }
}

struct BacktestReport: Hashable {
    let overall: PositionAccuracy
    let byPosition: [PositionAccuracy]
    let weeksTested: [Int]
}
