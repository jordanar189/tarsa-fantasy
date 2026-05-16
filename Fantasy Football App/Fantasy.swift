import Foundation

// Pure data-layer functions. Ported from src/main.py and unit-tested-equivalent
// behavior. No I/O, no Apple frameworks beyond Foundation.
enum Fantasy {

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
        limit: Int = 150
    ) -> [PlayerSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var rows: [PlayerSummary] = []
        rows.reserveCapacity(players.count)
        for (_, p) in players {
            if position != .all, p.position.uppercased() != position.rawValue { continue }
            if !q.isEmpty {
                let hay = "\(p.name) \(p.team) \(p.position)".lowercased()
                if !hay.contains(q) { continue }
            }
            rows.append(summary(p, scoring: scoring))
        }
        rows.sort { $0.points > $1.points }
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

    static func generateSchedule(teamIDs: [String]) -> [ScheduleWeek] {
        var teams = teamIDs
        let byeMarker = "__bye__"
        if teams.count % 2 == 1 { teams.append(byeMarker) }
        let count = teams.count
        guard count >= 2 else { return [] }
        var rotation = teams
        var schedule: [ScheduleWeek] = []
        for week in 1..<count {
            var matchups: [[String]] = []
            var byes: [String] = []
            for i in 0..<(count / 2) {
                let a = rotation[i]
                let b = rotation[count - 1 - i]
                if a == byeMarker      { byes.append(b) }
                else if b == byeMarker { byes.append(a) }
                else                   { matchups.append([a, b]) }
            }
            schedule.append(ScheduleWeek(week: week, matchups: matchups, byes: byes))
            let first = rotation[0]
            let last  = rotation[count - 1]
            let mid   = Array(rotation[1..<(count - 1)])
            rotation = [first, last] + mid
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
        scoring: Scoring
    ) -> [String] {
        let ranked = roster
            .compactMap { pid -> (id: String, position: String, points: Double)? in
                guard let p = players[pid] else { return nil }
                let pts = seasonTotals(p.games).points(scoring: scoring)
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

    // Returns the team's lineup as (starters, bench) player IDs. If the stored
    // starters are missing or stale (e.g. old leagues, roster edited without
    // re-saving lineup), it auto-fills on the fly.
    static func resolveLineup(
        team: FantasyTeam,
        players: [String: Player],
        config: RosterConfig,
        scoring: Scoring
    ) -> (starters: [String], bench: [String]) {
        let starters: [String]
        if team.starters.count == config.starterCount
            && team.starters.contains(where: { !$0.isEmpty }) {
            // Drop starter IDs no longer on the roster.
            let onRoster = Set(team.roster)
            starters = team.starters.map { onRoster.contains($0) ? $0 : "" }
        } else {
            starters = autoFillLineup(
                roster: team.roster, players: players,
                config: config, scoring: scoring
            )
        }
        let startingSet = Set(starters.filter { !$0.isEmpty })
        let bench = team.roster.filter { !startingSet.contains($0) }
        return (starters, bench)
    }

    static func teamWeekScore(
        players: [String: Player],
        team: FantasyTeam,
        config: RosterConfig,
        week: Int,
        scoring: Scoring
    ) -> TeamWeekScore {
        let (starters, bench) = resolveLineup(
            team: team, players: players, config: config, scoring: scoring
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
            let pts = game?.points(scoring: scoring) ?? 0
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
            let pts = game?.points(scoring: scoring) ?? 0
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
        var matchups: [LeagueMatchup] = []
        for pair in plan.matchups {
            guard pair.count == 2,
                  let home = teamsByID[pair[0]],
                  let away = teamsByID[pair[1]] else { continue }
            let h = teamWeekScore(players: players, team: home, config: league.rosterConfig, week: week, scoring: league.scoring)
            let a = teamWeekScore(players: players, team: away, config: league.rosterConfig, week: week, scoring: league.scoring)
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

    static func standings(league: League, players: [String: Player]) -> [StandingsRow] {
        struct Acc { var w = 0; var l = 0; var t = 0; var pf = 0.0; var pa = 0.0; var name = "" }
        var rows: [String: Acc] = [:]
        for team in league.teams {
            rows[team.id] = Acc(name: team.name)
        }
        let teamsByID = Dictionary(uniqueKeysWithValues: league.teams.map { ($0.id, $0) })
        for plan in league.schedule {
            for pair in plan.matchups {
                guard pair.count == 2,
                      let home = teamsByID[pair[0]],
                      let away = teamsByID[pair[1]] else { continue }
                let h = teamWeekScore(players: players, team: home, config: league.rosterConfig, week: plan.week, scoring: league.scoring)
                let a = teamWeekScore(players: players, team: away, config: league.rosterConfig, week: plan.week, scoring: league.scoring)
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
        let sorted = rows.map { (id: $0.key, acc: $0.value) }
            .sorted { ($0.acc.w, $0.acc.pf) > ($1.acc.w, $1.acc.pf) }
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
                rank: i + 1
            )
        }
    }
}
