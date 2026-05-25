import Foundation

// Pure data-layer functions. Ported from src/main.py and unit-tested-equivalent
// behavior. No I/O, no Apple frameworks beyond Foundation.
enum Fantasy {

    // Fantasy-relevant positions for UI surfacing. nflverse data also includes
    // IDP rows (LB/DB/DL/CB/S/etc); the data layer keeps them for stats use
    // but no browseable list should expose them until we add IDP support. DEF is
    // the synthetic per-team defense (DEF_<TEAM>), surfaced now that team-defense
    // scoring exists.
    static let fantasyPositions: Set<String> = ["QB", "RB", "WR", "TE", "K", "DEF"]
    static func isFantasyPosition(_ position: String) -> Bool {
        fantasyPositions.contains(position.uppercased())
    }

    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    static func seasonTotals(_ games: [Game]) -> SeasonTotals {
        var t = SeasonTotals()
        t.gamesPlayed = games.count
        for g in games {
            t.completions          += g.completions
            t.attempts             += g.attempts
            t.passingYards         += g.passingYards
            t.passingTDs           += g.passingTDs
            t.passingInterceptions += g.passingInterceptions
            t.carries              += g.carries
            t.rushingYards         += g.rushingYards
            t.rushingTDs           += g.rushingTDs
            t.receptions           += g.receptions
            t.targets              += g.targets
            t.receivingYards       += g.receivingYards
            t.receivingTDs         += g.receivingTDs
            t.fumblesLost          += g.fumblesLost
            t.fantasyPoints        += g.fantasyPoints
            t.fantasyPointsPPR     += g.fantasyPointsPPR
            t.fantasyPointsHalfPPR += g.fantasyPointsHalfPPR
            t.specialPoints        += g.specialPoints
        }
        return t
    }

    static func summary(_ player: Player, scoring: Scoring) -> PlayerSummary {
        let totals = seasonTotals(player.games)
        let pts = totals.points(scoring: scoring)
        let games = max(totals.gamesPlayed, 1)
        return PlayerSummary(
            id: player.id,
            name: player.name,
            position: player.position,
            team: player.team,
            headshotURL: player.headshotURL,
            gamesPlayed: totals.gamesPlayed,
            points: round2(pts),
            pointsPerGame: round2(pts / Double(games))
        )
    }

    static func search(
        players: [String: Player],
        query: String = "",
        position: Position = .all,
        scoring: Scoring = .ppr,
        limit: Int = 150,
        // When provided, results are sorted by ADP ascending; players without
        // an ADP entry sink below those with one, ordered by points descending.
        // The draft room passes this so the player list mirrors a real draft
        // board; other callers omit it and get the historical points sort.
        adp: [String: Double]? = nil
    ) -> [PlayerSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var rows: [PlayerSummary] = []
        rows.reserveCapacity(players.count)
        for (_, p) in players {
            if !isFantasyPosition(p.position) { continue }
            if position != .all, p.position.uppercased() != position.rawValue { continue }
            if !q.isEmpty {
                let hay = "\(p.name) \(p.team) \(p.position)".lowercased()
                if !hay.contains(q) { continue }
            }
            rows.append(summary(p, scoring: scoring))
        }
        if let adp {
            rows.sort { lhs, rhs in
                switch (adp[lhs.id], adp[rhs.id]) {
                case let (l?, r?):  return l < r
                case (_?, nil):     return true
                case (nil, _?):     return false
                case (nil, nil):    return lhs.points > rhs.points
                }
            }
        } else {
            rows.sort { $0.points > $1.points }
        }
        if limit > 0 && rows.count > limit { rows = Array(rows.prefix(limit)) }
        return rows
    }

    static func rank(
        players: [String: Player],
        scope: RankScope,
        week: Int? = nil,
        position: Position = .all,
        scoring: Scoring = .ppr,
        limit: Int = 100
    ) -> [Rank] {
        var rows: [Rank] = []
        for (_, p) in players {
            if !isFantasyPosition(p.position) { continue }
            if position != .all, p.position.uppercased() != position.rawValue { continue }
            switch scope {
            case .week:
                guard let w = week, let g = p.games.first(where: { $0.week == w }) else { continue }
                rows.append(Rank(
                    id: p.id, rank: 0, name: p.name, position: p.position,
                    team: p.team, headshotURL: p.headshotURL,
                    opponent: g.opponent, week: w, gamesPlayed: nil,
                    points: round2(g.points(scoring: scoring)),
                    pointsPerGame: nil
                ))
            case .season:
                let totals = seasonTotals(p.games)
                if totals.gamesPlayed == 0 { continue }
                let pts = totals.points(scoring: scoring)
                rows.append(Rank(
                    id: p.id, rank: 0, name: p.name, position: p.position,
                    team: p.team, headshotURL: p.headshotURL,
                    opponent: nil, week: nil, gamesPlayed: totals.gamesPlayed,
                    points: round2(pts),
                    pointsPerGame: round2(pts / Double(totals.gamesPlayed))
                ))
            }
        }
        rows.sort { $0.points > $1.points }
        if limit > 0 && rows.count > limit { rows = Array(rows.prefix(limit)) }
        for i in rows.indices { rows[i].rank = i + 1 }
        return rows
    }

    enum RankScope: String, CaseIterable, Identifiable, Hashable {
        case season, week
        var id: String { rawValue }
        var label: String { self == .season ? "Season" : "By week" }
    }

    // Snake-draft `players` across `teamCount` teams, filling each team's
    // roster to `config.totalSize`. Within each round, picks alternate
    // direction (round 1: teams 1→N, round 2: N→1, etc). Position-specific
    // rounds run first (QB/RB/WR/TE → FLEX → K), then bench fills with the
    // best remaining player regardless of position.
    // Snake-drafts full rosters across teams. Each team applies the same
    // auto-pick loop strategy that's used on the live clock, so pre-drafted
    // simulation rosters look like they came out of a real draft room.
    // Pick order alternates per round (round 1: team 1→N, round 2: N→1, …).
    static func draftRosters(
        players: [String: Player],
        teamCount: Int,
        config: RosterConfig,
        scoring: Scoring,
        adp: [String: Double] = [:]
    ) -> [[String]] {
        var rosters: [[String]] = Array(repeating: [], count: teamCount)
        var taken: Set<String> = []
        let totalRounds = config.totalSize

        for round in 1...totalRounds {
            let order: [Int] = round.isMultiple(of: 2)
                ? Array((0..<teamCount).reversed())
                : Array(0..<teamCount)
            for t in order {
                let team = FantasyTeam(id: "t\(t)", name: "", roster: rosters[t])
                if let pid = bestAutoPickPlayerID(
                    team: team, players: players, pickedPlayerIDs: taken,
                    config: config, scoring: scoring, adp: adp
                ) {
                    rosters[t].append(pid)
                    taken.insert(pid)
                }
            }
        }
        return rosters
    }

    // ============================================================
    // Auto-pick strategy
    //
    // Bots draft in 7-round loops with a fixed position template,
    // breaking out for K/DEF in the final two rounds:
    //   R1 RB/WR/TE   R2 RB/WR/TE   R3 RB/WR/TE/QB
    //   R4 RB/WR/TE/QB R5 RB/WR/TE/QB R6 RB/WR/TE   R7 RB/WR/TE
    // Within each 7-round loop the position budget is exactly:
    //   2 RB, 2 WR, 1 TE, 1 QB, 1 flex (RB/WR/TE).
    // The flex consumes the first "extra" RB/WR/TE pick after a position
    // hits its dedicated cap. Once a position is exhausted in the loop it
    // cannot be picked again that loop — even if the per-round template
    // still permits it.
    //
    // Final two rounds (rounds totalRounds-1 and totalRounds) are the K/DEF
    // phase.
    //
    // If no allowed-pool candidate is available we fall back to the
    // highest-ADP player overall.
    // ============================================================

    // Per-loop position budgets. Increase any number to widen what the bot
    // is willing to draft within a single 7-round loop.
    static let loopRoundCount = 7
    private static let loopBudgetRB:   Int = 2
    private static let loopBudgetWR:   Int = 2
    private static let loopBudgetTE:   Int = 1
    private static let loopBudgetQB:   Int = 1
    private static let loopBudgetFlex: Int = 1   // one of RB/WR/TE

    // Per-round position template (0-indexed offsets within a loop of 7).
    private static func roundTemplate(loopOffset: Int) -> Set<String> {
        switch loopOffset {
        case 0, 1:       return ["RB", "WR", "TE"]
        case 2, 3, 4:    return ["RB", "WR", "TE", "QB"]
        case 5, 6:       return ["RB", "WR", "TE"]
        default:         return ["RB", "WR", "TE"]
        }
    }

    // Positions the bot is allowed to pick at a given round, given the
    // positions it has already taken in the current loop. Returns nil
    // when the caller should fall back to the overall best-available
    // ADP player (e.g. partial-loop or exhausted positions).
    static func autoPickAllowedPositions(
        round: Int,
        totalRounds: Int,
        currentLoopPicks: [String]
    ) -> Set<String> {
        // Final two rounds = K / DEF phase.
        if totalRounds >= 2 && round >= totalRounds - 1 {
            return ["K", "DEF"]
        }
        let loopOffset = (round - 1) % loopRoundCount
        let template = roundTemplate(loopOffset: loopOffset)

        // Tally what's been picked in the current loop and how much flex
        // capacity is left. Flex consumes the FIRST overflow of any of
        // RB/WR/TE past its dedicated budget.
        var counts: [String: Int] = [:]
        for pos in currentLoopPicks {
            counts[pos, default: 0] += 1
        }
        let rbOver = max(0, (counts["RB"] ?? 0) - loopBudgetRB)
        let wrOver = max(0, (counts["WR"] ?? 0) - loopBudgetWR)
        let teOver = max(0, (counts["TE"] ?? 0) - loopBudgetTE)
        let flexUsed = rbOver + wrOver + teOver
        let flexLeft = max(0, loopBudgetFlex - flexUsed)

        func hasCapacity(_ pos: String) -> Bool {
            switch pos {
            case "RB": return (counts["RB"] ?? 0) < loopBudgetRB || flexLeft > 0
            case "WR": return (counts["WR"] ?? 0) < loopBudgetWR || flexLeft > 0
            case "TE": return (counts["TE"] ?? 0) < loopBudgetTE || flexLeft > 0
            case "QB": return (counts["QB"] ?? 0) < loopBudgetQB
            default:   return true
            }
        }
        return template.filter(hasCapacity)
    }

    // Returns the positions of the picks the team made within the loop
    // containing `round`. K-phase picks (final two rounds) are excluded.
    static func positionsInCurrentLoop(
        team: FantasyTeam,
        players: [String: Player],
        round: Int,
        totalRounds: Int
    ) -> [String] {
        let kPhaseStart = totalRounds - 1   // 1-indexed round number
        // Loop the upcoming pick belongs to (0-indexed). Out-of-K picks only.
        let upcomingIsKPhase = totalRounds >= 2 && round >= kPhaseStart
        if upcomingIsKPhase { return [] }
        let upcomingLoop = (round - 1) / loopRoundCount
        var out: [String] = []
        for (idx, pid) in team.roster.enumerated() {
            let pickRound = idx + 1
            if totalRounds >= 2 && pickRound >= kPhaseStart { continue }
            let pickLoop = (pickRound - 1) / loopRoundCount
            if pickLoop != upcomingLoop { continue }
            if let p = players[pid] {
                out.append(p.position.uppercased())
            }
        }
        return out
    }

    // Picks one player for a team that's on the clock. ADP is the primary
    // ranking; players without an ADP entry fall to the bottom (ranked by
    // season points as a tiebreak so we still fill rosters when ADP data
    // is sparse). See the comment block above for the strategy.
    static func bestAutoPickPlayerID(
        team: FantasyTeam,
        players: [String: Player],
        pickedPlayerIDs: Set<String>,
        config: RosterConfig,
        scoring: Scoring,
        adp: [String: Double] = [:]
    ) -> String? {
        let available = players.values.filter { !pickedPlayerIDs.contains($0.id) }
        if available.isEmpty { return nil }

        // Rank by ADP first, season points as a safety net for players
        // without an ADP entry (sparse historical data, deep rookies).
        let ranked = available.sorted { a, b in
            switch (adp[a.id], adp[b.id]) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:
                return seasonTotals(a.games).points(scoring: scoring)
                    > seasonTotals(b.games).points(scoring: scoring)
            }
        }

        let round = team.roster.count + 1
        let totalRounds = config.totalSize
        let loopPicks = positionsInCurrentLoop(
            team: team, players: players,
            round: round, totalRounds: totalRounds
        )
        let allowed = autoPickAllowedPositions(
            round: round, totalRounds: totalRounds,
            currentLoopPicks: loopPicks
        )
        if let pick = ranked.first(where: { allowed.contains($0.position.uppercased()) }) {
            return pick.id
        }
        // Allowed pool exhausted — fall back to overall best available.
        return ranked.first?.id
    }

    // Round-robin schedule. When `weeks` is nil, produces a single full
    // round-robin (count-1 weeks) for backward compatibility. When `weeks` is
    // given, cycles the round-robin rounds to fill exactly that many weeks —
    // so a real-length regular season (e.g. 14 weeks) can be built from any
    // team count. Rematches flip home/away on each subsequent cycle.
    static func generateSchedule(teamIDs: [String], weeks: Int? = nil) -> [ScheduleWeek] {
        var teams = teamIDs
        let byeMarker = "__bye__"
        if teams.count % 2 == 1 { teams.append(byeMarker) }
        let count = teams.count
        guard count >= 2 else { return [] }

        // Build the base set of round-robin rounds.
        var rotation = teams
        var baseRounds: [(matchups: [[String]], byes: [String])] = []
        for _ in 1..<count {
            var matchups: [[String]] = []
            var byes: [String] = []
            for i in 0..<(count / 2) {
                let a = rotation[i]
                let b = rotation[count - 1 - i]
                if a == byeMarker      { byes.append(b) }
                else if b == byeMarker { byes.append(a) }
                else                   { matchups.append([a, b]) }
            }
            baseRounds.append((matchups, byes))
            let first = rotation[0]
            let last  = rotation[count - 1]
            let mid   = Array(rotation[1..<(count - 1)])
            rotation = [first, last] + mid
        }
        guard !baseRounds.isEmpty else { return [] }

        let target = weeks ?? baseRounds.count
        var schedule: [ScheduleWeek] = []
        for i in 0..<max(0, target) {
            let base = baseRounds[i % baseRounds.count]
            let cycle = i / baseRounds.count
            // Flip home/away every other cycle so repeat matchups alternate.
            let matchups = cycle.isMultiple(of: 2)
                ? base.matchups
                : base.matchups.map { [$0[1], $0[0]] }
            schedule.append(ScheduleWeek(week: i + 1, matchups: matchups, byes: base.byes))
        }
        return schedule
    }

    struct TeamWeekScore {
        let total: Double
        // Ordered: starters first (by slot order), then bench. Empty starter
        // slots are present as entries with playerID == "".
        let roster: [LeagueRosterEntry]
    }

    // Fills starter slots from `roster` greedily, picking the highest-scoring
    // unassigned player whose position matches each slot. FLEX is filled after
    // the position-specific slots so a FLEX-eligible player isn't stolen from
    // a dedicated WR/RB/TE slot. Returns an array of length config.starterCount
    // where "" indicates an unfilled slot.
    static func autoFillLineup(
        roster: [String],
        players: [String: Player],
        config: RosterConfig,
        scoring: Scoring,
        settings: ScoringSettings? = nil,
        ir: Set<String> = []
    ) -> [String] {
        let ranked = roster
            .filter { !ir.contains($0) }
            .compactMap { pid -> (id: String, position: String, points: Double)? in
                guard let p = players[pid] else { return nil }
                let pts = seasonTotals(p.games).points(scoring: scoring, settings: settings)
                return (pid, p.position, pts)
            }
            .sorted { $0.points > $1.points }

        let slots = config.starterSlots
        var assignment = Array(repeating: "", count: slots.count)
        var used: Set<String> = []
        // Order slots so FLEX (and any other catch-all slots) are filled last.
        let slotOrder = slots.indices.sorted { i, j in
            let a = slots[i], b = slots[j]
            if a == .flex && b != .flex { return false }
            if b == .flex && a != .flex { return true }
            return i < j
        }
        for slotIdx in slotOrder {
            let slot = slots[slotIdx]
            if let pick = ranked.first(where: { !used.contains($0.id) && slot.accepts(position: $0.position) }) {
                assignment[slotIdx] = pick.id
                used.insert(pick.id)
            }
        }
        return assignment
    }

    // Positions still required to complete the STARTING lineup (bench/IR
    // excluded) given the players already on `roster`. An unfilled FLEX slot
    // expands to RB/WR/TE since any of them can start there. Returns the set of
    // draftable position strings plus the count of unfilled starter slots —
    // used late in a draft to steer a team toward positions it can still start
    // once it has only as many picks left as empty starting slots.
    static func starterNeeds(
        roster: [String],
        players: [String: Player],
        config: RosterConfig,
        scoring: Scoring,
        settings: ScoringSettings? = nil
    ) -> (positions: Set<String>, unfilledCount: Int) {
        let slots = config.starterSlots
        let assignment = autoFillLineup(
            roster: roster, players: players, config: config,
            scoring: scoring, settings: settings
        )
        var positions: Set<String> = []
        var unfilled = 0
        for (i, slot) in slots.enumerated() where assignment[i].isEmpty {
            unfilled += 1
            switch slot {
            case .qb:   positions.insert("QB")
            case .rb:   positions.insert("RB")
            case .wr:   positions.insert("WR")
            case .te:   positions.insert("TE")
            case .k:    positions.insert("K")
            case .def:  positions.insert("DEF")
            case .flex: positions.formUnion(["RB", "WR", "TE"])
            case .bench, .ir: break
            }
        }
        return (positions, unfilled)
    }

    // Whether a player qualifies for the taxi (practice) squad: at most
    // `maxExperience` years of NFL experience (0 = rookies only). Unknown
    // experience is treated as ineligible so veterans — and team defenses,
    // which have no experience value — can't be stashed by accident.
    static func taxiEligible(_ player: Player?, maxExperience: Int) -> Bool {
        guard let years = player?.profile?.yearsExp else { return false }
        return years <= maxExperience
    }

    // Returns the team's lineup as (starters, bench) player IDs. If the stored
    // starters are missing or stale (e.g. old leagues, roster edited without
    // re-saving lineup), it auto-fills on the fly.
    static func resolveLineup(
        team: FantasyTeam,
        players: [String: Player],
        config: RosterConfig,
        scoring: Scoring,
        settings: ScoringSettings? = nil,
        week: Int? = nil
    ) -> (starters: [String], bench: [String]) {
        // Reserves (IR + taxi) sit outside the active lineup: never start, never
        // appear on the bench, never score.
        let reservedSet = Set(team.ir).union(team.taxi)
        // Prefer the frozen lineup for the requested week, then the live
        // lineup, then an auto-fill.
        let chosen: [String]? = {
            if let week, let frozen = team.weeklyLineups[week],
               frozen.count == config.starterCount,
               frozen.contains(where: { !$0.isEmpty }) {
                return frozen
            }
            return nil
        }()
        let starters: [String]
        if let chosen {
            let onRoster = Set(team.roster)
            starters = chosen.map { onRoster.contains($0) ? $0 : "" }
        } else if team.starters.count == config.starterCount
            && team.starters.contains(where: { !$0.isEmpty }) {
            // Drop starter IDs no longer on the roster (or moved to IR/taxi).
            let onRoster = Set(team.roster)
            starters = team.starters.map {
                (onRoster.contains($0) && !reservedSet.contains($0)) ? $0 : ""
            }
        } else {
            starters = autoFillLineup(
                roster: team.roster, players: players,
                config: config, scoring: scoring, settings: settings, ir: reservedSet
            )
        }
        let startingSet = Set(starters.filter { !$0.isEmpty })
        // Bench excludes starters and reserves (IR + taxi).
        let bench = team.roster.filter { !startingSet.contains($0) && !reservedSet.contains($0) }
        return (starters, bench)
    }

    static func teamWeekScore(
        players: [String: Player],
        team: FantasyTeam,
        config: RosterConfig,
        week: Int,
        scoring: Scoring,
        settings: ScoringSettings? = nil
    ) -> TeamWeekScore {
        let (starters, bench) = resolveLineup(
            team: team, players: players, config: config, scoring: scoring, settings: settings, week: week
        )
        var total: Double = 0
        var rows: [LeagueRosterEntry] = []
        let slots = config.starterSlots
        for (i, pid) in starters.enumerated() {
            let slot = slots[i]
            if pid.isEmpty {
                rows.append(LeagueRosterEntry(
                    id: "s\(i)-empty",
                    playerID: "",
                    name: "Empty",
                    position: slot.label,
                    team: "",
                    headshotURL: "",
                    points: 0,
                    played: false,
                    slot: slot
                ))
                continue
            }
            let player = players[pid]
            let game = player?.games.first { $0.week == week }
            let pts = game?.points(scoring: scoring, settings: settings) ?? 0
            total += pts
            rows.append(LeagueRosterEntry(
                id: "s\(i)-\(pid)",
                playerID: pid,
                name: player?.name ?? pid,
                position: player?.position ?? slot.label,
                team: player?.team ?? "",
                headshotURL: player?.headshotURL ?? "",
                points: round2(pts),
                played: game != nil,
                slot: slot
            ))
        }
        for (i, pid) in bench.enumerated() {
            let player = players[pid]
            let game = player?.games.first { $0.week == week }
            let pts = game?.points(scoring: scoring, settings: settings) ?? 0
            rows.append(LeagueRosterEntry(
                id: "b\(i)-\(pid)",
                playerID: pid,
                name: player?.name ?? pid,
                position: player?.position ?? "",
                team: player?.team ?? "",
                headshotURL: player?.headshotURL ?? "",
                points: round2(pts),
                played: game != nil,
                slot: .bench
            ))
        }
        return TeamWeekScore(total: round2(total), roster: rows)
    }

    static func scoreboard(
        league: League,
        players: [String: Player],
        week: Int
    ) -> (matchups: [LeagueMatchup], byes: [LeagueBye]) {
        let teamsByID = Dictionary(uniqueKeysWithValues: league.teams.map { ($0.id, $0) })
        guard let plan = league.schedule.first(where: { $0.week == week }) else {
            return ([], [])
        }
        let settings = league.scoringSettings
        var matchups: [LeagueMatchup] = []
        for pair in plan.matchups {
            guard pair.count == 2,
                  let home = teamsByID[pair[0]],
                  let away = teamsByID[pair[1]] else { continue }
            let h = teamWeekScore(players: players, team: home, config: league.rosterConfig, week: week, scoring: league.scoring, settings: settings)
            let a = teamWeekScore(players: players, team: away, config: league.rosterConfig, week: week, scoring: league.scoring, settings: settings)
            let played = h.roster.contains { $0.played } || a.roster.contains { $0.played }
            matchups.append(LeagueMatchup(
                id: "\(week)-\(home.id)-\(away.id)",
                home: LeagueSide(teamID: home.id, name: home.name, points: h.total, roster: h.roster),
                away: LeagueSide(teamID: away.id, name: away.name, points: a.total, roster: a.roster),
                played: played
            ))
        }
        let byes: [LeagueBye] = plan.byes.compactMap { tid in
            guard let t = teamsByID[tid] else { return nil }
            return LeagueBye(id: tid, name: t.name)
        }
        return (matchups, byes)
    }

    // The most recent week with any stat row, or 1 if the season hasn't begun.
    // Used by the waiver flow to decide which week's games to check when
    // determining whether a player is locked.
    static func currentWeek(players: [String: Player]) -> Int {
        var maxWeek = 0
        for (_, p) in players {
            for g in p.games where g.week > maxWeek { maxWeek = g.week }
        }
        return max(maxWeek, 1)
    }

    // A player is "locked" for the current week once their game has any stat
    // line — i.e., the game has kicked off. Stats arrive from player_games
    // (final) or live_scores (in-progress, merged in by NFLDataService), so
    // either presence indicates the game has started.
    static func isPlayerLocked(playerID: String, week: Int, players: [String: Player]) -> Bool {
        guard let p = players[playerID] else { return false }
        return p.games.contains { $0.week == week }
    }

    // MARK: - Matchup ratings (Phase 3)

    // For each NFL team, the next scheduled (unplayed) game and what
    // opponent that game is against. Built once from a season schedule.
    static func nextOpponentByTeam(schedules: [NFLGame], asOf now: Date = Date()) -> [String: (opp: String, isHome: Bool)] {
        var firstByTeam: [String: NFLGame] = [:]
        let upcoming = schedules
            .filter { $0.kickoff.map { $0 > now } ?? false }
            .sorted { ($0.kickoff ?? .distantFuture) < ($1.kickoff ?? .distantFuture) }
        for g in upcoming {
            if firstByTeam[g.home] == nil { firstByTeam[g.home] = g }
            if firstByTeam[g.away] == nil { firstByTeam[g.away] = g }
        }
        var out: [String: (opp: String, isHome: Bool)] = [:]
        for (team, g) in firstByTeam {
            if team == g.home { out[team] = (g.away, true) }
            else if team == g.away { out[team] = (g.home, false) }
        }
        return out
    }

    // Build a [playerID: MatchupRating] map given the players, the
    // team→next-opponent lookup, and a [position: [team: DvPEntry]] dvp
    // lookup. Players whose team has no scheduled opponent (bye week, end
    // of season) get .unknown.
    static func matchupRatingsByPlayer(
        players: [String: Player],
        nextOppByTeam: [String: (opp: String, isHome: Bool)],
        dvpByPosition: [String: [String: DvPEntry]]
    ) -> [String: (rating: MatchupRating, opponent: String, isHome: Bool)] {
        var out: [String: (MatchupRating, String, Bool)] = [:]
        for (_, p) in players {
            guard let next = nextOppByTeam[p.team] else { continue }
            let positionKey = p.position.uppercased()
            let dvp = dvpByPosition[positionKey]?[next.opp]
            let rating = MatchupRating.from(rank: dvp?.rank)
            out[p.id] = (rating, next.opp, next.isHome)
        }
        return out
    }

    // MARK: - Advanced metrics (Phase 3)

    // Per-team weekly target counts across the whole player snapshot. Lookup
    // table keyed [team: [week: totalTargets]] so per-player target-share
    // calculations are O(1).
    static func teamTargetsPerWeek(players: [String: Player]) -> [String: [Int: Double]] {
        var out: [String: [Int: Double]] = [:]
        for (_, p) in players {
            for g in p.games where g.targets > 0 {
                out[g.team, default: [:]][g.week, default: 0] += g.targets
            }
        }
        return out
    }

    // Similar to above, but team rushing TDs + passing TDs + receiving TDs
    // for TD share calculations.
    static func teamTouchdownsPerWeek(players: [String: Player]) -> [String: [Int: Double]] {
        var out: [String: [Int: Double]] = [:]
        for (_, p) in players {
            for g in p.games {
                let tds = g.passingTDs + g.rushingTDs + g.receivingTDs
                if tds > 0 {
                    out[g.team, default: [:]][g.week, default: 0] += tds
                }
            }
        }
        return out
    }

    struct WeeklyAdvanced {
        let week: Int
        let snapPct: Double?
        let targets: Double
        let targetShare: Double?    // 0..1
        let yardsPerTarget: Double?
        let yardsPerCatch: Double?
        let carries: Double
        let yardsPerCarry: Double?
        let tds: Double
        let tdShare: Double?        // 0..1
    }

    // Builds the per-week advanced derived row for a single player. snapMap
    // is the [week: SnapCount] slice from snapCounts(season:)[playerID].
    static func weeklyAdvanced(
        player: Player,
        snapMap: [Int: SnapCount]?,
        teamTargets: [String: [Int: Double]],
        teamTouchdowns: [String: [Int: Double]]
    ) -> [WeeklyAdvanced] {
        player.games.sorted { $0.week < $1.week }.map { g in
            let totalTeamTargets = teamTargets[g.team]?[g.week] ?? 0
            let totalTeamTDs     = teamTouchdowns[g.team]?[g.week] ?? 0
            let snap = snapMap?[g.week]?.offensePct
            let tShare: Double?  = totalTeamTargets > 0 ? round2(g.targets / totalTeamTargets) : nil
            let ypTarget: Double? = g.targets > 0 ? round2(g.receivingYards / g.targets) : nil
            let ypCatch:  Double? = g.receptions > 0 ? round2(g.receivingYards / g.receptions) : nil
            let ypCarry:  Double? = g.carries > 0 ? round2(g.rushingYards / g.carries) : nil
            let tds = g.passingTDs + g.rushingTDs + g.receivingTDs
            let tdShare: Double? = totalTeamTDs > 0 ? round2(tds / totalTeamTDs) : nil
            return WeeklyAdvanced(
                week: g.week,
                snapPct: snap,
                targets: g.targets,
                targetShare: tShare,
                yardsPerTarget: ypTarget,
                yardsPerCatch: ypCatch,
                carries: g.carries,
                yardsPerCarry: ypCarry,
                tds: tds,
                tdShare: tdShare
            )
        }
    }

    // MARK: - Score breakdown (game-log detail)

    // One line in a single game's fantasy-score breakdown: a stat category,
    // a short description of the rate that scored it, and the points it
    // contributed under the chosen scoring.
    struct ScoreComponent: Identifiable, Hashable {
        let label: String
        let detail: String
        let points: Double
        var id: String { label }
    }

    // Breaks a single game's fantasy points into per-stat contributions. Uses
    // the league's custom per-stat weights when given, otherwise the named
    // preset. Components are built from the raw box-score line; any gap between
    // their sum and the displayed score (2-pt conversions, return TDs, etc. the
    // line doesn't carry — only relevant for preset scoring, which reads
    // nflverse's precomputed field) is folded into a trailing "Other" row so
    // the parts always reconcile to the total shown in the game log.
    static func scoreBreakdown(game g: Game, scoring: Scoring, settings: ScoringSettings? = nil) -> (components: [ScoreComponent], total: Double) {
        let s = settings ?? ScoringSettings.preset(scoring)
        var components: [ScoreComponent] = []

        func yardLine(_ label: String, yards: Double, divisor: Double) {
            guard yards != 0, divisor > 0 else { return }
            components.append(ScoreComponent(
                label: label,
                detail: "\(yards.statString) yds · 1 pt/\(divisor.statString)",
                points: round2(yards / divisor)
            ))
        }
        func eventLine(_ label: String, count: Double, weight: Double) {
            guard count != 0, weight != 0 else { return }
            components.append(ScoreComponent(
                label: label,
                detail: "\(count.statString) × \(weight.statString) pts",
                points: round2(count * weight)
            ))
        }

        yardLine("Passing Yards", yards: g.passingYards, divisor: s.passingYardsPerPoint)
        eventLine("Passing TDs", count: g.passingTDs, weight: s.passingTD)
        eventLine("Interceptions", count: g.passingInterceptions, weight: s.interception)
        yardLine("Rushing Yards", yards: g.rushingYards, divisor: s.rushingYardsPerPoint)
        eventLine("Rushing TDs", count: g.rushingTDs, weight: s.rushingTD)
        eventLine("Receptions", count: g.receptions, weight: s.reception)
        yardLine("Receiving Yards", yards: g.receivingYards, divisor: s.receivingYardsPerPoint)
        eventLine("Receiving TDs", count: g.receivingTDs, weight: s.receivingTD)
        eventLine("Fumbles Lost", count: g.fumblesLost, weight: s.fumbleLost)

        // Kicker (distance-tiered FGs + PATs). Reads straight off the raw stat
        // line with the league's kicking weights — credited to whoever kicked,
        // regardless of listed position.
        eventLine("FG 0-39", count: g.fieldGoals0_19 + g.fieldGoals20_29 + g.fieldGoals30_39, weight: s.fgUnder40)
        eventLine("FG 40-49", count: g.fieldGoals40_49, weight: s.fg40to49)
        eventLine("FG 50+", count: g.fieldGoals50_59 + g.fieldGoals60Plus, weight: s.fg50plus)
        eventLine("Extra Points", count: g.extraPointsMade, weight: s.patMade)
        eventLine("Missed FG", count: g.fieldGoalsMissed, weight: s.fgMissed)
        eventLine("Missed PAT", count: g.extraPointsMissed, weight: s.patMissed)

        // Team defense (only DST rows carry a points-allowed figure).
        if let pa = g.pointsAllowed {
            eventLine("Sacks", count: g.defSacks, weight: s.defSack)
            eventLine("DEF Interceptions", count: g.defInterceptions, weight: s.defInterception)
            eventLine("Fumble Recoveries", count: g.defFumbleRecoveries, weight: s.defFumbleRecovery)
            eventLine("Defensive TDs", count: g.defTouchdowns, weight: s.defTouchdown)
            eventLine("Safeties", count: g.defSafeties, weight: s.defSafety)
            components.append(ScoreComponent(
                label: "Points Allowed",
                detail: "\(pa.statString) allowed",
                points: Game.pointsAllowedBonus(pa)
            ))
        }

        // Reconcile to the score the game log actually shows. Anything the raw
        // line can't explain lands in "Other" so the components always sum to
        // the displayed total. (With custom settings the displayed score is
        // itself computed from the raw line, so the residual is zero.)
        let total = round2(g.points(scoring: scoring, settings: settings))
        let explained = round2(components.reduce(0) { $0 + $1.points })
        let residual = round2(total - explained)
        if abs(residual) >= 0.05 {
            components.append(ScoreComponent(
                label: "Other",
                detail: "2-pt, return TDs, etc.",
                points: residual
            ))
        }

        return (components, total)
    }

    // MARK: - Stats overhaul helpers (Phase 1)

    // Returns season fantasy rank within each player's position. WR12 etc.
    // Players with no games this season are excluded (no signal to rank).
    static func positionRanks(
        players: [String: Player], scoring: Scoring, settings: ScoringSettings? = nil
    ) -> [String: PositionRank] {
        // Group players by position with their season total.
        var byPosition: [String: [(id: String, points: Double)]] = [:]
        for (_, p) in players {
            let totals = seasonTotals(p.games)
            if totals.gamesPlayed == 0 { continue }
            let pos = p.position.uppercased()
            if pos.isEmpty { continue }
            byPosition[pos, default: []].append((p.id, totals.points(scoring: scoring, settings: settings)))
        }
        var out: [String: PositionRank] = [:]
        for (pos, list) in byPosition {
            let sorted = list.sorted { $0.points > $1.points }
            let total = sorted.count
            for (i, entry) in sorted.enumerated() {
                out[entry.id] = PositionRank(
                    position: pos, rank: i + 1,
                    totalAtPosition: total,
                    seasonPoints: round2(entry.points)
                )
            }
        }
        return out
    }

    // MARK: - Career (multi-season history)

    // One season's line in a player's career table: that season's counting
    // totals, fantasy points, and fantasy position rank (computed within the
    // season's own field) under the chosen scoring preset.
    struct CareerSeasonLine: Identifiable, Hashable {
        let season: Int
        // Teams the player logged a game for that season, in order of first
        // appearance (handles mid-season trades — usually a single team).
        let teams: [String]
        let position: String
        let gamesPlayed: Int
        let totals: SeasonTotals
        let points: Double
        let pointsPerGame: Double
        let positionRank: PositionRank?
        var id: Int { season }
        var teamLabel: String { teams.isEmpty ? "—" : teams.joined(separator: "/") }
    }

    // Builds one career line for a player from a single season's snapshot.
    // Returns nil when the player logged no games that season. Team(s) are
    // derived from the games (the per-season snapshot's `team` field is the
    // player's *current* team, not that season's). Pure; the caller supplies
    // one season snapshot at a time so peak memory stays at one season.
    static func careerSeasonLine(
        playerID: String,
        season: Int,
        snapshot: [String: Player],
        scoring: Scoring,
        settings: ScoringSettings? = nil
    ) -> CareerSeasonLine? {
        guard let p = snapshot[playerID] else { return nil }
        let totals = seasonTotals(p.games)
        guard totals.gamesPlayed > 0 else { return nil }
        var teams: [String] = []
        for g in p.games.sorted(by: { $0.week < $1.week }) where !g.team.isEmpty {
            if !teams.contains(g.team) { teams.append(g.team) }
        }
        let pts = totals.points(scoring: scoring, settings: settings)
        let rank = positionRanks(players: snapshot, scoring: scoring, settings: settings)[playerID]
        return CareerSeasonLine(
            season: season,
            teams: teams,
            position: p.position.uppercased(),
            gamesPlayed: totals.gamesPlayed,
            totals: totals,
            points: round2(pts),
            pointsPerGame: round2(pts / Double(max(totals.gamesPlayed, 1))),
            positionRank: rank
        )
    }

    // Sum a set of per-season totals into one career aggregate.
    static func combinedTotals(_ totals: [SeasonTotals]) -> SeasonTotals {
        var t = SeasonTotals()
        for s in totals {
            t.gamesPlayed          += s.gamesPlayed
            t.completions          += s.completions
            t.attempts             += s.attempts
            t.passingYards         += s.passingYards
            t.passingTDs           += s.passingTDs
            t.passingInterceptions += s.passingInterceptions
            t.carries              += s.carries
            t.rushingYards         += s.rushingYards
            t.rushingTDs           += s.rushingTDs
            t.receptions           += s.receptions
            t.targets              += s.targets
            t.receivingYards       += s.receivingYards
            t.receivingTDs         += s.receivingTDs
            t.fumblesLost          += s.fumblesLost
            t.fantasyPoints        += s.fantasyPoints
            t.fantasyPointsPPR     += s.fantasyPointsPPR
            t.fantasyPointsHalfPPR += s.fantasyPointsHalfPPR
            t.specialPoints        += s.specialPoints
        }
        return t
    }

    // MARK: - Trade value (VOR)

    // Per-player trade value on a 0–100 scale via Value Over Replacement: a
    // player is worth his season (or projected, depending on the snapshot the
    // caller passes) points above a replacement-level player at the same
    // position. Replacement level is the last weekly starter the league rosters
    // at that position — starters × teams, with FLEX split across RB/WR/TE — so
    // positional scarcity is baked in (an elite RB outranks an equal-scoring QB
    // in a 1-QB league). Scaled so the league's most valuable player ≈ 100.
    // Pure: K and team DEF are valued alongside the offensive positions.
    static func tradeValues(
        players: [String: Player],
        scoring: Scoring,
        settings: ScoringSettings? = nil,
        config: RosterConfig,
        teamCount: Int
    ) -> [String: Double] {
        let teams = max(teamCount, 1)
        var pointsByID: [String: Double] = [:]
        var byPosition: [String: [Double]] = [:]
        for (_, p) in players {
            let pos = p.position.uppercased()
            guard isFantasyPosition(pos) else { continue }
            let pts = seasonTotals(p.games).points(scoring: scoring, settings: settings)
            pointsByID[p.id] = pts
            byPosition[pos, default: []].append(pts)
        }
        // Replacement-level points per position (FLEX spread over RB/WR/TE).
        let flexShare = Double(config.flex) / 3.0
        let startersByPos: [String: Double] = [
            "QB": Double(config.qb),
            "RB": Double(config.rb) + flexShare,
            "WR": Double(config.wr) + flexShare,
            "TE": Double(config.te) + flexShare,
            "K":  Double(config.k),
            "DEF": Double(config.def),
        ]
        var replacement: [String: Double] = [:]
        for (pos, pts) in byPosition {
            let sorted = pts.sorted(by: >)
            let starters = startersByPos[pos] ?? 0
            guard starters > 0, !sorted.isEmpty else { replacement[pos] = 0; continue }
            let idx = max(0, min(sorted.count - 1, Int((Double(teams) * starters).rounded()) - 1))
            replacement[pos] = sorted[idx]
        }
        var raw: [String: Double] = [:]
        var maxRaw = 0.0
        for (id, pts) in pointsByID {
            let pos = players[id]?.position.uppercased() ?? ""
            let vor = max(0, pts - (replacement[pos] ?? 0))
            raw[id] = vor
            if vor > maxRaw { maxRaw = vor }
        }
        guard maxRaw > 0 else { return raw.mapValues { _ in 0.0 } }
        return raw.mapValues { round2($0 / maxRaw * 100) }
    }

    // MARK: - Wins Above Replacement (WAR)

    // How many regular-season wins a player adds over a replacement-level
    // starter at his position. Model: an average team scores ~μ each week with
    // SD σ; swapping the position's *average* starter for this player shifts the
    // team's expected score by (points − avgStarter), so its win probability vs
    // an average opponent is Φ((points − avgStarter)/σ). A player's weekly WAR is
    // that win prob minus a replacement starter's, summed over the games he
    // actually played — so availability is rewarded and byes/misses add nothing.
    //
    // Baselines are derived from the supplied snapshot (so they track the
    // league's scoring): the starter pool at a position is its top
    // (teams × starters) players by per-game average, with FLEX split across
    // RB/WR/TE; replacement is the next man up. σ is the team weekly-score SD,
    // estimated from the average within-player weekly variance at each starter
    // slot. Pure. Caller picks the snapshot (real in-season, projected before).
    static func warByPlayer(
        players: [String: Player],
        scoring: Scoring,
        settings: ScoringSettings? = nil,
        config: RosterConfig,
        teamCount: Int
    ) -> [String: Double] {
        let teams = max(teamCount, 1)
        // Per-position: each player's weekly point series.
        var byPos: [String: [(id: String, gamePts: [Double])]] = [:]
        for (_, p) in players {
            let pos = p.position.uppercased()
            guard isFantasyPosition(pos) else { continue }
            let pts = p.games.map { $0.points(scoring: scoring, settings: settings) }
            guard !pts.isEmpty else { continue }
            byPos[pos, default: []].append((p.id, pts))
        }
        let flexShare = Double(config.flex) / 3.0
        let startersByPos: [String: Double] = [
            "QB": Double(config.qb),
            "RB": Double(config.rb) + flexShare,
            "WR": Double(config.wr) + flexShare,
            "TE": Double(config.te) + flexShare,
            "K":  Double(config.k),
            "DEF": Double(config.def),
        ]
        var avgStarter: [String: Double] = [:]
        var replacement: [String: Double] = [:]
        var withinVar: [String: Double] = [:]   // mean within-player weekly variance among starters
        for (pos, list) in byPos {
            let ranked = list
                .map { (id: $0.id, avg: $0.gamePts.reduce(0, +) / Double($0.gamePts.count), gp: $0.gamePts) }
                .sorted { $0.avg > $1.avg }
            let starterCount = max(1, Int((Double(teams) * (startersByPos[pos] ?? 0)).rounded()))
            let starters = Array(ranked.prefix(min(starterCount, ranked.count)))
            avgStarter[pos] = starters.map { $0.avg }.reduce(0, +) / Double(max(starters.count, 1))
            let replIdx = min(starterCount, ranked.count - 1)
            replacement[pos] = ranked[max(0, replIdx)].avg
            // Average week-to-week variance of a starter at this position.
            let vars: [Double] = starters.compactMap { s in
                guard s.gp.count >= 2 else { return nil }
                let m = s.gp.reduce(0, +) / Double(s.gp.count)
                return s.gp.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(s.gp.count)
            }
            withinVar[pos] = vars.isEmpty ? 0 : vars.reduce(0, +) / Double(vars.count)
        }
        // Team weekly-score SD ≈ sqrt(Σ over starter slots of positional variance).
        var teamVar = 0.0
        for (pos, n) in [("QB", config.qb), ("RB", config.rb), ("WR", config.wr),
                         ("TE", config.te), ("K", config.k), ("DEF", config.def)] {
            teamVar += Double(n) * (withinVar[pos] ?? 0)
        }
        if config.flex > 0 {
            let flexVar = ["RB", "WR", "TE"].map { withinVar[$0] ?? 0 }.reduce(0, +) / 3.0
            teamVar += Double(config.flex) * flexVar
        }
        let sigma = max(1.0, teamVar.squareRoot())
        func phi(_ x: Double) -> Double { 0.5 * (1 + erf(x / 2.0.squareRoot())) }

        var out: [String: Double] = [:]
        for (pos, list) in byPos {
            guard let aS = avgStarter[pos], let rep = replacement[pos] else { continue }
            let replWin = phi((rep - aS) / sigma)
            for entry in list {
                let war = entry.gamePts.reduce(0.0) { $0 + phi(($1 - aS) / sigma) - replWin }
                out[entry.id] = round2(war)
            }
        }
        return out
    }

    // Trend arrow based on average of last N games vs full-season average.
    // .flat when within 10% of season average; .up/.down when meaningfully
    // above/below.
    static func trendDirection(
        games: [Game], scoring: Scoring, settings: ScoringSettings? = nil, lookback: Int = 3
    ) -> Trend {
        guard games.count >= 2 else { return .flat }
        let sorted = games.sorted { $0.week < $1.week }
        let recent = Array(sorted.suffix(lookback))
        let recentAvg  = recent.reduce(0.0) { $0 + $1.points(scoring: scoring, settings: settings) } / Double(recent.count)
        let seasonAvg  = sorted.reduce(0.0) { $0 + $1.points(scoring: scoring, settings: settings) } / Double(sorted.count)
        if seasonAvg == 0 { return .flat }
        let delta = (recentAvg - seasonAvg) / seasonAvg
        if delta > 0.10  { return .up }
        if delta < -0.10 { return .down }
        return .flat
    }

    // Chronological per-week points — for the inline sparkline. Skips weeks
    // without games (so the line shape reflects appearances only).
    static func sparklineSeries(games: [Game], scoring: Scoring) -> [Double] {
        games.sorted { $0.week < $1.week }
             .map { $0.points(scoring: scoring) }
    }

    // Convenience for view code: return the clamped snapshot if the league
    // is in a Testing Environment with a pinned week, otherwise the raw
    // dict pass-through. One call site instead of conditionals everywhere.
    static func playersFor(
        league: League, snapshot: [String: Player]
    ) -> [String: Player] {
        if league.isTest, let week = league.simulatedWeek {
            return clamped(snapshot, upTo: week)
        }
        return snapshot
    }

    // Returns a clamped copy of the season's player dict where each player's
    // games are restricted to weeks <= upTo. Used by Testing Environment
    // league views so standings/scoreboard/lock detection reflect only the
    // simulated portion of the season. Non-test leagues never need this.
    static func clamped(_ players: [String: Player], upTo week: Int) -> [String: Player] {
        var out: [String: Player] = [:]
        out.reserveCapacity(players.count)
        for (id, p) in players {
            var copy = p
            copy.games = p.games.filter { $0.week <= week }
            out[id] = copy
        }
        return out
    }

    static func standings(league: League, players: [String: Player]) -> [StandingsRow] {
        struct Acc { var w = 0; var l = 0; var t = 0; var pf = 0.0; var pa = 0.0; var name = ""; var division: Int? }
        var rows: [String: Acc] = [:]
        for team in league.teams {
            rows[team.id] = Acc(name: team.name, division: team.division)
        }
        let teamsByID = Dictionary(uniqueKeysWithValues: league.teams.map { ($0.id, $0) })
        let settings = league.scoringSettings
        // Only head-to-head regular-season weeks count toward the standings.
        for plan in league.schedule where plan.week <= league.regularSeasonWeeks {
            for pair in plan.matchups {
                guard pair.count == 2,
                      let home = teamsByID[pair[0]],
                      let away = teamsByID[pair[1]] else { continue }
                let h = teamWeekScore(players: players, team: home, config: league.rosterConfig, week: plan.week, scoring: league.scoring, settings: settings)
                let a = teamWeekScore(players: players, team: away, config: league.rosterConfig, week: plan.week, scoring: league.scoring, settings: settings)
                if !(h.roster.contains { $0.played } || a.roster.contains { $0.played }) { continue }
                rows[home.id]!.pf += h.total
                rows[home.id]!.pa += a.total
                rows[away.id]!.pf += a.total
                rows[away.id]!.pa += h.total
                if h.total > a.total {
                    rows[home.id]!.w += 1
                    rows[away.id]!.l += 1
                } else if a.total > h.total {
                    rows[away.id]!.w += 1
                    rows[home.id]!.l += 1
                } else {
                    rows[home.id]!.t += 1
                    rows[away.id]!.t += 1
                }
            }
        }
        // Overall order: win% then points-for. (Ties in record broken by PF.)
        let sorted = rows.map { (id: $0.key, acc: $0.value) }
            .sorted { lhs, rhs in
                if lhs.acc.w != rhs.acc.w { return lhs.acc.w > rhs.acc.w }
                return lhs.acc.pf > rhs.acc.pf
            }
        let orderedIDs = sorted.map(\.id)

        // Division rank: position within the team's own division, in overall order.
        var divisionRank: [String: Int] = [:]
        if league.hasDivisions {
            var perDivCount: [Int: Int] = [:]
            for id in orderedIDs {
                guard let d = sorted.first(where: { $0.id == id })?.acc.division else { continue }
                perDivCount[d, default: 0] += 1
                divisionRank[id] = perDivCount[d]
            }
        }

        // Playoff seeds (division winners first when divisions are on).
        let teamDivision = Dictionary(uniqueKeysWithValues: league.teams.map { ($0.id, $0.division) })
        let seededIDs = playoffSeededTeamIDs(
            orderedTeamIDs: orderedIDs,
            teamDivision: teamDivision,
            divisionCount: league.divisionNames.count,
            playoffTeams: league.playoffTeams
        )
        var seedByTeam: [String: Int] = [:]
        for (i, id) in seededIDs.enumerated() { seedByTeam[id] = i + 1 }

        return sorted.enumerated().map { (i, item) in
            StandingsRow(
                id: item.id,
                name: item.acc.name,
                wins: item.acc.w,
                losses: item.acc.l,
                ties: item.acc.t,
                pointsFor: round2(item.acc.pf),
                pointsAgainst: round2(item.acc.pa),
                games: item.acc.w + item.acc.l + item.acc.t,
                rank: i + 1,
                division: item.acc.division,
                divisionRank: divisionRank[item.id],
                playoffSeed: seedByTeam[item.id]
            )
        }
    }

    // Ordered team IDs that make the playoffs, seed 1..N. Division winners are
    // seeded ahead of wildcards (each division's best team by overall order),
    // then the best remaining teams fill the rest.
    static func playoffSeededTeamIDs(
        orderedTeamIDs: [String],
        teamDivision: [String: Int?],
        divisionCount: Int,
        playoffTeams: Int
    ) -> [String] {
        let n = min(max(playoffTeams, 0), orderedTeamIDs.count)
        guard n > 0 else { return [] }
        guard divisionCount >= 2 else { return Array(orderedTeamIDs.prefix(n)) }

        var winners: [String] = []
        var seenDiv = Set<Int>()
        for tid in orderedTeamIDs {
            if let d = teamDivision[tid] ?? nil, !seenDiv.contains(d) {
                seenDiv.insert(d)
                winners.append(tid)
            }
        }
        var seeds = Array(winners.prefix(n))
        if seeds.count < n {
            let winnerSet = Set(winners)
            for tid in orderedTeamIDs where !winnerSet.contains(tid) {
                seeds.append(tid)
                if seeds.count == n { break }
            }
        }
        return seeds
    }

    // MARK: - Team season stats

    // The best lineup score a team could have started in `week`, using that
    // week's actual results. The candidate pool is the current roster plus
    // anyone actually started that week (so a since-dropped starter still
    // counts — this keeps Max PF ≥ actual PF, i.e. efficiency ≤ 100%). Reserves
    // (IR/taxi) can't be started unless they were the frozen starter that week.
    static func optimalWeekPoints(
        team: FantasyTeam,
        players: [String: Player],
        config: RosterConfig,
        week: Int,
        scoring: Scoring,
        settings: ScoringSettings? = nil
    ) -> Double {
        let frozen = Set((team.weeklyLineups[week] ?? []).filter { !$0.isEmpty })
        let reserves = Set(team.ir).union(team.taxi).subtracting(frozen)
        let pool = Set(team.roster).union(frozen)
        let ranked = pool
            .filter { !reserves.contains($0) }
            .compactMap { pid -> (id: String, position: String, points: Double)? in
                guard let p = players[pid],
                      let g = p.games.first(where: { $0.week == week }) else { return nil }
                return (pid, p.position, g.points(scoring: scoring, settings: settings))
            }
            .sorted { $0.points > $1.points }
        let slots = config.starterSlots
        var used: Set<String> = []
        var total = 0.0
        // Fill FLEX last so a flex-eligible player isn't pulled from a dedicated slot.
        let order = slots.indices.sorted { i, j in
            let a = slots[i], b = slots[j]
            if a == .flex && b != .flex { return false }
            if b == .flex && a != .flex { return true }
            return i < j
        }
        for i in order {
            let slot = slots[i]
            if let pick = ranked.first(where: { !used.contains($0.id) && slot.accepts(position: $0.position) }) {
                total += pick.points
                used.insert(pick.id)
            }
        }
        return round2(total)
    }

    // Richer per-team season stats over the same regular-season, games-started
    // weeks the standings count: PF, PA, Max PF (optimal), best/worst week, and
    // a schedule-independent all-play record. Sorted by PF descending.
    static func teamSeasonStats(league: League, players: [String: Player]) -> [TeamSeasonStats] {
        struct Acc {
            var name = ""
            var games = 0
            var pf = 0.0
            var pa = 0.0
            var maxPF = 0.0
            var high = 0.0
            var low = Double.greatestFiniteMagnitude
            var apW = 0, apL = 0, apT = 0
        }
        var acc: [String: Acc] = [:]
        for team in league.teams { acc[team.id] = Acc(name: team.name) }
        let teamsByID = Dictionary(uniqueKeysWithValues: league.teams.map { ($0.id, $0) })
        let settings = league.scoringSettings

        func add(_ id: String, score: Double, against: Double, maxPF: Double) {
            guard var a = acc[id] else { return }
            a.games += 1
            a.pf += score
            a.pa += against
            a.maxPF += maxPF
            a.high = max(a.high, score)
            a.low = min(a.low, score)
            acc[id] = a
        }

        for plan in league.schedule where plan.week <= league.regularSeasonWeeks {
            // Actual scores for the teams whose matchup has started this week.
            var weekScores: [(id: String, score: Double)] = []
            for pair in plan.matchups {
                guard pair.count == 2,
                      let home = teamsByID[pair[0]],
                      let away = teamsByID[pair[1]] else { continue }
                let h = teamWeekScore(players: players, team: home, config: league.rosterConfig, week: plan.week, scoring: league.scoring, settings: settings)
                let a = teamWeekScore(players: players, team: away, config: league.rosterConfig, week: plan.week, scoring: league.scoring, settings: settings)
                guard h.roster.contains(where: { $0.played }) || a.roster.contains(where: { $0.played }) else { continue }
                let hMax = optimalWeekPoints(team: home, players: players, config: league.rosterConfig, week: plan.week, scoring: league.scoring, settings: settings)
                let aMax = optimalWeekPoints(team: away, players: players, config: league.rosterConfig, week: plan.week, scoring: league.scoring, settings: settings)
                add(home.id, score: h.total, against: a.total, maxPF: hMax)
                add(away.id, score: a.total, against: h.total, maxPF: aMax)
                weekScores.append((home.id, h.total))
                weekScores.append((away.id, a.total))
            }
            // All-play: compare every team to every other team that played this week.
            for x in weekScores {
                for y in weekScores where y.id != x.id {
                    if x.score > y.score { acc[x.id]!.apW += 1 }
                    else if x.score < y.score { acc[x.id]!.apL += 1 }
                    else { acc[x.id]!.apT += 1 }
                }
            }
        }

        return league.teams.map { team -> TeamSeasonStats in
            let a = acc[team.id] ?? Acc(name: team.name)
            return TeamSeasonStats(
                id: team.id, name: a.name, games: a.games,
                pointsFor: round2(a.pf), pointsAgainst: round2(a.pa),
                maxPointsFor: round2(a.maxPF),
                high: round2(a.games > 0 ? a.high : 0),
                low: round2(a.games > 0 ? a.low : 0),
                allPlayWins: a.apW, allPlayLosses: a.apL, allPlayTies: a.apT
            )
        }
        .sorted { $0.pointsFor > $1.pointsFor }
    }

    // MARK: - Playoffs

    // Standard single-elimination seeding order for a bracket of `size`
    // (a power of two). e.g. size 8 → [1,8,4,5,2,7,3,6] so the top seed only
    // meets the 2-seed in the final.
    static func seedSlots(_ size: Int) -> [Int] {
        var slots = [1, 2]
        while slots.count < size {
            let n = slots.count * 2
            var next: [Int] = []
            for s in slots { next.append(s); next.append(n + 1 - s) }
            slots = next
        }
        return Array(slots.prefix(max(size, 1)))
    }

    // Builds the postseason bracket from the current standings. Stateless: each
    // round maps to a real fantasy week (playoffStartWeek onward) and winners
    // advance by their actual weekly score, exactly like the regular season is
    // scored. Top seeds receive first-round byes when the field isn't a power
    // of two. Returns .empty when the league has no postseason configured.
    static func playoffBracket(league: League, players: [String: Player]) -> PlayoffBracket {
        guard league.playoffTeams >= 2 else { return .empty }
        let rows = standings(league: league, players: players)
        let seeded = rows
            .compactMap { row -> (seed: Int, row: StandingsRow)? in
                row.playoffSeed.map { (seed: $0, row: row) }
            }
            .sorted { $0.seed < $1.seed }
        let p = seeded.count
        guard p >= 2 else { return .empty }

        let teamsByID = Dictionary(uniqueKeysWithValues: league.teams.map { ($0.id, $0) })
        let nameByID  = Dictionary(uniqueKeysWithValues: league.teams.map { ($0.id, $0.name) })
        let settings  = league.scoringSettings

        var teamForSeed: [Int: String] = [:]
        var seedForTeam: [String: Int] = [:]
        var seedEntries: [PlayoffSeedEntry] = []
        for (seed, row) in seeded {
            teamForSeed[seed] = row.id
            seedForTeam[row.id] = seed
            seedEntries.append(PlayoffSeedEntry(
                seed: seed, teamID: row.id, teamName: row.name,
                division: row.division,
                isDivisionWinner: league.hasDivisions && row.divisionRank == 1
            ))
        }

        let rounds = max(1, Int(ceil(log2(Double(p)))))
        let bracketSize = 1 << rounds
        let byesCount = bracketSize - p
        let startWeek = league.playoffStartWeek
        let weeksPerRound = max(1, league.weeksPerRound)
        let asOfWeek = currentWeek(players: players)

        // An entrant flowing into a round: a concrete team (by seed), a bye, or
        // an undecided "winner of the feeding game".
        struct Entrant { var teamID: String?; var seed: Int?; var isBye: Bool }

        // A round's score is the combined score over its weeks (1 or 2). Played
        // is true once any of those weeks has results.
        func score(_ teamID: String, weeks: ClosedRange<Int>) -> (pts: Double, played: Bool) {
            guard let t = teamsByID[teamID] else { return (0, false) }
            var total = 0.0
            var played = false
            for w in weeks {
                let s = teamWeekScore(
                    players: players, team: t, config: league.rosterConfig,
                    week: w, scoring: league.scoring, settings: settings
                )
                total += s.total
                if s.roster.contains(where: { $0.played }) { played = true }
            }
            return (round2(total), played)
        }

        func roundName(_ r: Int) -> String {
            if r == rounds { return "Championship" }
            if r == 1 && byesCount > 0 { return "Wild Card" }
            switch rounds - r {
            case 1:  return "Semifinals"
            case 2:  return "Quarterfinals"
            default: return "Round \(r)"
            }
        }

        var entrants: [Entrant] = seedSlots(bracketSize).map { seed in
            seed > p
                ? Entrant(teamID: nil, seed: nil, isBye: true)
                : Entrant(teamID: teamForSeed[seed], seed: seed, isBye: false)
        }

        var roundsOut: [PlayoffRound] = []
        var championID: String? = nil
        var runnerUpID: String? = nil

        for r in 1...rounds {
            let week = startWeek + (r - 1) * weeksPerRound
            let endWeek = week + weeksPerRound - 1
            let roundWeeks = week...endWeek
            let weekReached = asOfWeek >= week
            var games: [PlayoffGame] = []
            var next: [Entrant] = []

            for k in 0..<(entrants.count / 2) {
                let a = entrants[2 * k]
                let b = entrants[2 * k + 1]

                // Resolve a bye: the real team advances without playing.
                if a.isBye != b.isBye {
                    let real = a.isBye ? b : a
                    let realSide = PlayoffSide(
                        teamID: real.teamID,
                        teamName: real.teamID.flatMap { nameByID[$0] },
                        seed: real.seed, placeholder: nil, points: nil, won: true
                    )
                    games.append(PlayoffGame(
                        id: "r\(r)-g\(k)", round: r, week: week,
                        top: realSide, bottom: .bye,
                        played: false, winnerTeamID: real.teamID
                    ))
                    next.append(Entrant(teamID: real.teamID, seed: real.seed, isBye: false))
                    continue
                }

                // Build each side; undecided when the feeding team is unknown.
                func makeSide(_ e: Entrant) -> (side: PlayoffSide, decided: Bool, pts: Double, played: Bool) {
                    guard let tid = e.teamID else {
                        return (PlayoffSide(teamID: nil, teamName: nil, seed: nil,
                                            placeholder: "TBD", points: nil, won: false),
                                false, 0, false)
                    }
                    let s = weekReached ? score(tid, weeks: roundWeeks) : (pts: 0.0, played: false)
                    return (PlayoffSide(teamID: tid, teamName: nameByID[tid], seed: e.seed,
                                        placeholder: nil,
                                        points: s.played ? round2(s.pts) : nil, won: false),
                            true, s.pts, s.played)
                }

                let top = makeSide(a)
                let bottom = makeSide(b)
                let bothKnown = top.decided && bottom.decided
                let anyPlayed = top.played || bottom.played
                // Decided once the round's games are in (or the round has fully
                // passed — for a 2-week round that means past its second week).
                let resolved = bothKnown && anyPlayed && (top.pts != bottom.pts || asOfWeek > endWeek)

                var winnerID: String? = nil
                var topSide = top.side
                var bottomSide = bottom.side
                if resolved {
                    let topWins: Bool
                    if top.pts != bottom.pts {
                        topWins = top.pts > bottom.pts
                    } else {
                        // Exact tie at week's end → higher seed advances.
                        topWins = (a.seed ?? Int.max) <= (b.seed ?? Int.max)
                    }
                    winnerID = topWins ? a.teamID : b.teamID
                    topSide = PlayoffSide(teamID: top.side.teamID, teamName: top.side.teamName,
                                          seed: top.side.seed, placeholder: top.side.placeholder,
                                          points: top.side.points, won: topWins)
                    bottomSide = PlayoffSide(teamID: bottom.side.teamID, teamName: bottom.side.teamName,
                                             seed: bottom.side.seed, placeholder: bottom.side.placeholder,
                                             points: bottom.side.points, won: !topWins)
                }

                games.append(PlayoffGame(
                    id: "r\(r)-g\(k)", round: r, week: week,
                    top: topSide, bottom: bottomSide,
                    played: anyPlayed, winnerTeamID: winnerID
                ))
                let winnerSeed = winnerID.flatMap { seedForTeam[$0] }
                next.append(Entrant(teamID: winnerID, seed: winnerSeed, isBye: false))

                if r == rounds {
                    championID = winnerID
                    if let win = winnerID {
                        runnerUpID = (win == a.teamID) ? b.teamID : a.teamID
                    }
                }
            }

            roundsOut.append(PlayoffRound(round: r, week: week, endWeek: endWeek, name: roundName(r), games: games))

            // Re-seed the field for the next round when configured: the highest
            // remaining seed faces the lowest. Only possible once every advancing
            // team is known — while games are undecided we keep bracket order and
            // the next round shows TBD placeholders (the bracket is recomputed as
            // results come in). Round 1 pairings already match best-vs-worst, so
            // re-seeding only diverges from round 2 onward.
            if league.playoffReseed, next.count >= 2, next.allSatisfy({ $0.teamID != nil }) {
                let ordered = next.sorted { ($0.seed ?? Int.max) < ($1.seed ?? Int.max) }
                var reseeded: [Entrant] = []
                var lo = 0, hi = ordered.count - 1
                while lo < hi {
                    reseeded.append(ordered[lo]); reseeded.append(ordered[hi])
                    lo += 1; hi -= 1
                }
                if lo == hi { reseeded.append(ordered[lo]) }
                entrants = reseeded
            } else {
                entrants = next
            }
        }

        return PlayoffBracket(
            rounds: roundsOut, seeds: seedEntries,
            championTeamID: championID,
            championTeamName: championID.flatMap { nameByID[$0] },
            runnerUpTeamID: runnerUpID,
            started: asOfWeek >= startWeek
        )
    }

    // MARK: - Player projections (baseline model)

    // Everything project() needs, passed in so the function stays pure and
    // synchronous. `players` is the history snapshot — its games must already
    // be restricted to weeks < `week` (use Fantasy.clamped). DvP must likewise
    // be computed as of week-1 to avoid look-ahead bias in backtests.
    struct ProjectionContext {
        let season: Int
        let week: Int
        let scoring: Scoring
        let players: [String: Player]
        let schedule: [NFLGame]
        let dvpByPosition: [String: [String: DvPEntry]]
        let injuries: [String: Injury]
        let inactives: Set<String>
        let config: ProjectionConfig
    }

    // Projects one player for context.week. Returns nil when the player is
    // unknown, not a fantasy position, or their team has no game that week
    // (bye / end of season). Pass `positionMeans` to reuse a precomputed table
    // across many players (projectAll / backtest do this).
    static func project(
        playerID: String,
        context: ProjectionContext,
        positionMeans means: [String: Double]? = nil
    ) -> PlayerProjection? {
        guard let p = context.players[playerID] else { return nil }
        let pos = p.position.uppercased()
        guard isFantasyPosition(pos), !p.team.isEmpty else { return nil }
        guard let game = context.schedule.first(where: {
            $0.week == context.week && ($0.home == p.team || $0.away == p.team)
        }), let opp = game.opponent(of: p.team) else { return nil }
        let isHome = game.isHome(team: p.team)

        let posMean = (means ?? positionMeans(players: context.players, scoring: context.scoring))[pos] ?? 0
        let history = p.games.filter { $0.week < context.week }
        let base = recencyWeightedBase(
            games: history, scoring: context.scoring, posMean: posMean, config: context.config
        )

        var matchupMult = 1.0
        if context.config.enableMatchup, let rank = context.dvpByPosition[pos]?[opp]?.rank {
            matchupMult = matchupMultiplier(rank: rank, range: context.config.matchupRange)
        }

        var scriptMult = 1.0
        if context.config.enableScript, let implied = game.impliedTotal(for: p.team) {
            scriptMult = scriptMultiplier(impliedTotal: implied, config: context.config)
        }

        var availability = 1.0
        if context.config.enableAvailability {
            availability = availabilityFactor(playerID: playerID, context: context)
        }

        let points = max(0, base * matchupMult * scriptMult * availability)
        let sd = pointsStdev(games: history, scoring: context.scoring)
        return PlayerProjection(
            playerID: playerID, season: context.season, week: context.week,
            opponent: opp, isHome: isHome,
            points: round2(points), base: round2(base),
            matchupMult: round2(matchupMult), scriptMult: round2(scriptMult),
            availability: round2(availability),
            low: round2(max(0, points - sd)), high: round2(points + sd)
        )
    }

    // Projects every fantasy-position player who has a game in context.week.
    static func projectAll(context: ProjectionContext) -> [String: PlayerProjection] {
        let means = positionMeans(players: context.players, scoring: context.scoring)
        var out: [String: PlayerProjection] = [:]
        for (id, p) in context.players where isFantasyPosition(p.position) {
            if let proj = project(playerID: id, context: context, positionMeans: means) {
                out[id] = proj
            }
        }
        return out
    }

    // Lifts precomputed projections out of a preseason projected snapshot for
    // one week: each player's synthetic game for `week` becomes a
    // PlayerProjection. The raw preseason snapshot has no games to project from,
    // so the live projectAll pass returns nothing there — this lets the league
    // Lineup/Matchup screens show the same numbers the browse surfaces already
    // render off the projected snapshot. Only `points`/`opponent` are meaningful;
    // the band/multiplier fields aren't surfaced for preseason rows.
    static func projectionsFromSnapshot(
        _ snapshot: [String: Player], season: Int, week: Int, scoring: Scoring
    ) -> [String: PlayerProjection] {
        var out: [String: PlayerProjection] = [:]
        for (id, p) in snapshot where isFantasyPosition(p.position) {
            guard let g = p.games.first(where: { $0.week == week }) else { continue }
            let pts = round2(g.points(scoring: scoring))
            out[id] = PlayerProjection(
                playerID: id, season: season, week: week,
                opponent: g.opponent, isHome: false,
                points: pts, base: pts,
                matchupMult: 1, scriptMult: 1, availability: 1,
                low: pts, high: pts
            )
        }
        return out
    }

    // Builds a display-only snapshot for a not-yet-started season: each player's
    // `games` are replaced with synthetic per-week projections (points only, in
    // all three scoring fields) seeded from prior-season data. Feeding this into
    // the existing stat surfaces makes totals, rankings, sparklines and the game
    // log render projections for a preseason feel — without touching league
    // scoring, which always runs on the real snapshot.
    //
    // Projections vary by week via the (best-available) prior-season DvP for the
    // scheduled opponent and any published Vegas line; players with no prior-
    // season games fall back to the position mean (e.g. rookies).
    static func preseasonProjectedSnapshot(
        season: Int,
        players currentPlayers: [String: Player],
        priorPlayers: [String: Player],
        schedule: [NFLGame],
        dvpByPosition: [String: [String: DvPEntry]],
        injuries: [String: Injury],
        config: ProjectionConfig = .default
    ) -> [String: Player] {
        let meanStd  = positionMeans(players: priorPlayers, scoring: .standard)
        let meanPpr  = positionMeans(players: priorPlayers, scoring: .ppr)
        let meanHalf = positionMeans(players: priorPlayers, scoring: .half)

        var gamesByTeam: [String: [NFLGame]] = [:]
        for g in schedule {
            gamesByTeam[g.home, default: []].append(g)
            gamesByTeam[g.away, default: []].append(g)
        }
        for k in gamesByTeam.keys { gamesByTeam[k]?.sort { $0.week < $1.week } }

        var out: [String: Player] = [:]
        out.reserveCapacity(currentPlayers.count)
        for (id, p) in currentPlayers {
            let pos = p.position.uppercased()
            guard isFantasyPosition(pos), !p.team.isEmpty, let teamGames = gamesByTeam[p.team] else {
                out[id] = p
                continue
            }
            let prior = priorPlayers[id]?.games ?? []
            let baseStd  = recencyWeightedBase(games: prior, scoring: .standard, posMean: meanStd[pos]  ?? 0, config: config)
            let basePpr  = recencyWeightedBase(games: prior, scoring: .ppr,      posMean: meanPpr[pos]  ?? 0, config: config)
            let baseHalf = recencyWeightedBase(games: prior, scoring: .half,     posMean: meanHalf[pos] ?? 0, config: config)
            let avail = config.enableAvailability
                ? availabilityFactor(playerID: id, injuries: injuries, inactives: [])
                : 1.0

            var projected: [Game] = []
            projected.reserveCapacity(teamGames.count)
            for ng in teamGames {
                guard let opp = ng.opponent(of: p.team) else { continue }
                var matchup = 1.0
                if config.enableMatchup, let rank = dvpByPosition[pos]?[opp]?.rank {
                    matchup = matchupMultiplier(rank: rank, range: config.matchupRange)
                }
                var script = 1.0
                if config.enableScript, let implied = ng.impliedTotal(for: p.team) {
                    script = scriptMultiplier(impliedTotal: implied, config: config)
                }
                let mult = matchup * script * avail
                var game = Game()
                game.season = season
                game.week = ng.week
                game.team = p.team
                game.opponent = opp
                game.fantasyPoints        = round2(max(0, baseStd  * mult))
                game.fantasyPointsPPR     = round2(max(0, basePpr  * mult))
                game.fantasyPointsHalfPPR = round2(max(0, baseHalf * mult))
                projected.append(game)
            }
            var copy = p
            copy.games = projected
            out[id] = copy
        }
        return out
    }

    // Game-weighted points/game per position across the snapshot — the
    // shrinkage target for thin samples.
    static func positionMeans(players: [String: Player], scoring: Scoring) -> [String: Double] {
        var sum: [String: Double] = [:]
        var cnt: [String: Double] = [:]
        for (_, p) in players where isFantasyPosition(p.position) {
            let pos = p.position.uppercased()
            for g in p.games {
                sum[pos, default: 0] += g.points(scoring: scoring)
                cnt[pos, default: 0] += 1
            }
        }
        var out: [String: Double] = [:]
        for (pos, c) in cnt where c > 0 { out[pos] = sum[pos]! / c }
        return out
    }

    // Exponentially recency-weighted points/game, shrunk toward the position
    // mean by `shrinkageGames` pseudo-observations. With no history the player
    // is the position mean.
    private static func recencyWeightedBase(
        games: [Game], scoring: Scoring, posMean: Double, config: ProjectionConfig
    ) -> Double {
        guard let maxWeek = games.map(\.week).max() else { return posMean }
        var weightedSum = 0.0
        var weightTotal = 0.0
        for g in games {
            let w = pow(config.recencyDecay, Double(maxWeek - g.week))
            weightedSum += w * g.points(scoring: scoring)
            weightTotal += w
        }
        let k = max(0, config.shrinkageGames)
        return (weightedSum + k * posMean) / (weightTotal + k)
    }

    // rank 1 = worst defense (most points allowed) → boost; 32 = best → suppress.
    private static func matchupMultiplier(rank: Int, range: Double) -> Double {
        let r = Double(min(max(rank, 1), 32))
        let t = (r - 1) / 31                  // 0 at worst D, 1 at best D
        return 1 + range - 2 * range * t
    }

    private static func scriptMultiplier(impliedTotal: Double, config: ProjectionConfig) -> Double {
        guard config.scriptPivot > 0 else { return 1 }
        let rel = (impliedTotal - config.scriptPivot) / config.scriptPivot
        return min(max(1 + config.scriptStrength * rel, 0.80), 1.20)
    }

    private static func availabilityFactor(playerID: String, context: ProjectionContext) -> Double {
        availabilityFactor(playerID: playerID, injuries: context.injuries, inactives: context.inactives)
    }

    private static func availabilityFactor(
        playerID: String, injuries: [String: Injury], inactives: Set<String>
    ) -> Double {
        if inactives.contains(playerID) { return 0 }
        guard let injury = injuries[playerID] else { return 1 }
        switch injury.status.uppercased() {
        case "OUT", "IR", "INJURED RESERVE", "PUP", "SUSPENDED", "SUS", "NFI", "DNR":
            return 0
        case "DOUBTFUL":
            return 0.25
        case "QUESTIONABLE":
            return 0.9
        default:
            return 1
        }
    }

    private static func pointsStdev(games: [Game], scoring: Scoring) -> Double {
        guard games.count >= 2 else { return 0 }
        let pts = games.map { $0.points(scoring: scoring) }
        let mean = pts.reduce(0, +) / Double(pts.count)
        let variance = pts.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(pts.count)
        return variance.squareRoot()
    }

    // MARK: - Backtesting

    // Replays projections over already-assembled per-week contexts and scores
    // them against the full-season `actuals` snapshot. Each context must carry
    // history < its week and as-of-week-1 DvP (the caller in AppState assembles
    // these so this stays pure). Compares against a naive season-average-to-date
    // baseline so the model's value is measurable.
    static func backtest(weeks: [ProjectionContext], actuals: [String: Player]) -> BacktestReport {
        struct Acc { var n = 0; var absErr = 0.0; var sqErr = 0.0; var bias = 0.0; var naiveAbsErr = 0.0 }
        var byPos: [String: Acc] = [:]
        var rhoSum: [String: Double] = [:]
        var rhoWeight: [String: Double] = [:]

        for ctx in weeks {
            let means = positionMeans(players: ctx.players, scoring: ctx.scoring)
            var weekPairs: [String: [(proj: Double, actual: Double)]] = [:]
            for (id, p) in ctx.players where isFantasyPosition(p.position) {
                let pos = p.position.uppercased()
                let history = p.games.filter { $0.week < ctx.week }
                guard !history.isEmpty else { continue }
                guard let actualGame = actuals[id]?.games.first(where: { $0.week == ctx.week }) else { continue }
                guard let proj = project(playerID: id, context: ctx, positionMeans: means) else { continue }
                let actual = actualGame.points(scoring: ctx.scoring)
                let naive = history.reduce(0.0) { $0 + $1.points(scoring: ctx.scoring) } / Double(history.count)
                let err = proj.points - actual
                var a = byPos[pos] ?? Acc()
                a.n += 1
                a.absErr += abs(err)
                a.sqErr += err * err
                a.bias += err
                a.naiveAbsErr += abs(naive - actual)
                byPos[pos] = a
                weekPairs[pos, default: []].append((proj.points, actual))
            }
            // Within-week, within-position rank correlation.
            for (pos, pairs) in weekPairs where pairs.count >= 3 {
                let rho = spearman(pairs.map { $0.proj }, pairs.map { $0.actual })
                rhoSum[pos, default: 0] += rho * Double(pairs.count)
                rhoWeight[pos, default: 0] += Double(pairs.count)
            }
        }

        func accuracy(_ pos: String, _ acc: Acc) -> PositionAccuracy {
            let n = Double(max(acc.n, 1))
            let rho = (rhoWeight[pos] ?? 0) > 0 ? rhoSum[pos]! / rhoWeight[pos]! : 0
            return PositionAccuracy(
                position: pos, n: acc.n,
                mae: round2(acc.absErr / n),
                rmse: round2((acc.sqErr / n).squareRoot()),
                bias: round2(acc.bias / n),
                rankCorrelation: round2(rho),
                naiveMAE: round2(acc.naiveAbsErr / n)
            )
        }

        let order = ["QB", "RB", "WR", "TE", "K"]
        let byPosition = order.compactMap { pos in byPos[pos].map { accuracy(pos, $0) } }

        var all = Acc()
        for (_, a) in byPos {
            all.n += a.n; all.absErr += a.absErr; all.sqErr += a.sqErr
            all.bias += a.bias; all.naiveAbsErr += a.naiveAbsErr
        }
        var rhoNum = 0.0, rhoDen = 0.0
        for pa in byPosition { rhoNum += pa.rankCorrelation * Double(pa.n); rhoDen += Double(pa.n) }
        let n = Double(max(all.n, 1))
        let overall = PositionAccuracy(
            position: "ALL", n: all.n,
            mae: round2(all.absErr / n),
            rmse: round2((all.sqErr / n).squareRoot()),
            bias: round2(all.bias / n),
            rankCorrelation: round2(rhoDen > 0 ? rhoNum / rhoDen : 0),
            naiveMAE: round2(all.naiveAbsErr / n)
        )
        return BacktestReport(overall: overall, byPosition: byPosition, weeksTested: weeks.map(\.week).sorted())
    }

    // Spearman's ρ via the rank-difference formula (tie-tolerant via average
    // ranks). Adequate for a debug accuracy metric.
    private static func spearman(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        guard n > 1 else { return 0 }
        let ra = averageRanks(a), rb = averageRanks(b)
        var d2 = 0.0
        for i in a.indices { let d = ra[i] - rb[i]; d2 += d * d }
        return 1 - (6 * d2) / (n * (n * n - 1))
    }

    private static func averageRanks(_ xs: [Double]) -> [Double] {
        let idx = xs.indices.sorted { xs[$0] < xs[$1] }
        var out = Array(repeating: 0.0, count: xs.count)
        var i = 0
        while i < idx.count {
            var j = i
            while j + 1 < idx.count && xs[idx[j + 1]] == xs[idx[i]] { j += 1 }
            let avgRank = Double(i + j) / 2 + 1
            for k in i...j { out[idx[k]] = avgRank }
            i = j + 1
        }
        return out
    }
}
