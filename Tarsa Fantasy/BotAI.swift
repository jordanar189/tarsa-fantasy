import Foundation

// Decision logic for "bot" teams in a Testing Environment league. Pure
// functions — they decide what should happen; the caller (AppState) is
// responsible for executing the moves via the real RemoteService RPCs.
//
// Bots aren't smart: they make random reasonable-looking moves so the
// Activity / Trades / Waivers UIs have something to render. Deterministic
// when given a seeded RNG, otherwise reasonably random per call.

enum BotMove: Hashable {
    case addDrop(teamID: String, addPlayerID: String, dropPlayerID: String)
    case waiverClaim(teamID: String, addPlayerID: String, dropPlayerID: String)
    case proposeTrade(fromTeamID: String, toTeamID: String,
                      sendPlayerIDs: [String], requestPlayerIDs: [String])
}

enum BotAI {

    // Probability tunables. Per-bot, per-advance.
    private static let pAddDrop: Double = 0.30
    private static let pTrade:   Double = 0.10

    // Generate this advance's set of moves for every bot in the league.
    // `adminTeamID` is excluded — that's the admin's team, not a bot.
    // `onWaivers` is the set of player IDs currently on the waiver wire.
    // `trendingAdds` is an optional [playerID: adds_pct] signal — in a
    // simulation this comes from trending_history for the simulated week,
    // so bots react to the same breakout adds a real manager would have seen.
    // `inactives` is the set of player IDs we should not consider for adds
    // (suspended, on IR, etc. — historically inactive in the source week).
    static func weeklyMoves(
        league: League,
        adminTeamID: String,
        players: [String: Player],
        onWaivers: Set<String>,
        upToWeek: Int,
        trendingAdds: [String: Double] = [:],
        inactives: Set<String> = [],
        rng: inout SystemRandomNumberGenerator
    ) -> [BotMove] {
        var moves: [BotMove] = []
        let scoring = league.scoring

        // Pre-compute global free agents + ranked lists once per call.
        // Score = recent-week points + trending boost (real managers add
        // hot waiver pickups, not just season-aggregate leaders).
        let rostered = Set(league.teams.flatMap(\.roster))
        let recentWindow: Set<Int> = upToWeek > 0
            ? Set(max(1, upToWeek - 3)...upToWeek)
            : []
        let freeAgents = players.values
            .filter { !rostered.contains($0.id) && !inactives.contains($0.id) }
            .sorted {
                score($0, scoring: scoring, weeks: recentWindow, trending: trendingAdds)
                    > score($1, scoring: scoring, weeks: recentWindow, trending: trendingAdds)
            }
        let freeAgentPool = Array(freeAgents.prefix(60))
        if freeAgentPool.isEmpty { return [] }

        let bots = league.teams.filter { $0.id != adminTeamID && !$0.roster.isEmpty }

        for bot in bots {
            // ---- Add / drop or waiver claim ----
            if Double.random(in: 0..<1, using: &rng) < pAddDrop {
                if let move = decideAddOrClaim(
                    team: bot, scoring: scoring, players: players,
                    pool: freeAgentPool, onWaivers: onWaivers,
                    weeks: recentWindow, trending: trendingAdds, rng: &rng
                ) {
                    moves.append(move)
                }
            }

            // ---- Trade proposal ----
            if Double.random(in: 0..<1, using: &rng) < pTrade,
               let move = decideTrade(
                from: bot, league: league, adminTeamID: adminTeamID,
                scoring: scoring, players: players, rng: &rng
               ) {
                moves.append(move)
            }
        }
        return moves
    }

    private static func decideAddOrClaim(
        team: FantasyTeam, scoring: Scoring,
        players: [String: Player],
        pool: [Player], onWaivers: Set<String>,
        weeks: Set<Int>, trending: [String: Double],
        rng: inout SystemRandomNumberGenerator
    ) -> BotMove? {
        // Drop the bot's lowest-scoring rostered player (uses recent-window
        // points, falls back to season points when no weeks given).
        let ranked = team.roster
            .compactMap { players[$0] }
            .sorted {
                score($0, scoring: scoring, weeks: weeks, trending: [:])
                    < score($1, scoring: scoring, weeks: weeks, trending: [:])
            }
        guard let drop = ranked.first else { return nil }

        let dropScore = score(drop, scoring: scoring, weeks: weeks, trending: [:])
        let candidates = pool.filter {
            score($0, scoring: scoring, weeks: weeks, trending: trending) > dropScore
        }
        let topSlice = Array(candidates.prefix(20))
        guard let add = topSlice.randomElement(using: &rng) else { return nil }

        if onWaivers.contains(add.id) {
            return .waiverClaim(teamID: team.id, addPlayerID: add.id, dropPlayerID: drop.id)
        }
        return .addDrop(teamID: team.id, addPlayerID: add.id, dropPlayerID: drop.id)
    }

    private static func decideTrade(
        from bot: FantasyTeam, league: League, adminTeamID: String,
        scoring: Scoring, players: [String: Player],
        rng: inout SystemRandomNumberGenerator
    ) -> BotMove? {
        // Other team to trade with (any team, including the admin).
        let others = league.teams.filter { $0.id != bot.id && !$0.roster.isEmpty }
        guard let target = others.randomElement(using: &rng) else { return nil }

        let myRanked = bot.roster
            .compactMap { players[$0] }
            .sorted { points($0, scoring: scoring) > points($1, scoring: scoring) }
        let theirRanked = target.roster
            .compactMap { players[$0] }
            .sorted { points($0, scoring: scoring) > points($1, scoring: scoring) }
        // Offer my middle, ask for their top — slightly favorable to "us"
        // so the admin sees a mix of accept/reject when reviewing.
        guard myRanked.count >= 3, theirRanked.count >= 2 else { return nil }
        let mySendIdx = Int.random(in: 2..<min(myRanked.count, 8), using: &rng)
        let theirIdx  = Int.random(in: 0..<min(theirRanked.count, 4), using: &rng)
        let send    = myRanked[mySendIdx]
        let request = theirRanked[theirIdx]
        return .proposeTrade(
            fromTeamID: bot.id, toTeamID: target.id,
            sendPlayerIDs: [send.id], requestPlayerIDs: [request.id]
        )
    }

    private static func points(_ p: Player, scoring: Scoring) -> Double {
        Fantasy.seasonTotals(p.games).points(scoring: scoring)
    }

    // Composite score the bot uses to rank players. Real managers don't
    // pick the season-long leader from waivers — they react to recent
    // form and the wider league's adds. We approximate that:
    //   • base = average points/game over the last 1..3 weeks (or season
    //            average when the recent window is empty)
    //   • bonus = trending adds % / 4 (capped at +10) — a player added by
    //            40% of leagues this week gets +10 to their score.
    private static func score(
        _ p: Player, scoring: Scoring,
        weeks: Set<Int>, trending: [String: Double]
    ) -> Double {
        let base: Double
        if weeks.isEmpty {
            base = Fantasy.seasonTotals(p.games).points(scoring: scoring)
        } else {
            let games = p.games.filter { weeks.contains($0.week) }
            if games.isEmpty {
                base = 0
            } else {
                let total = games.reduce(0.0) { $0 + $1.points(scoring: scoring) }
                base = total / Double(games.count)
            }
        }
        let bonus = min(10, (trending[p.id] ?? 0) / 4.0)
        return base + bonus
    }
}

// MARK: - Auction drafting

extension BotAI {

    // Deterministic per-(bot, player) valuation noise in [-0.20, +0.20] so
    // bots disagree about prices. Session-stable (hashValue) is enough — an
    // auction lives inside one app run.
    private static func valuationNoise(_ teamID: String, _ playerID: String) -> Double {
        // Mask rather than abs — abs(Int.min) traps.
        let h = (teamID + playerID).hashValue & Int.max
        return Double(h % 41 - 20) / 100.0
    }

    // A bot's private price for a player, from the league-wide dollar value.
    static func botPrice(teamID: String, playerID: String, dollarValue: Int) -> Int {
        max(1, Int((Double(dollarValue) * (1.0 + valuationNoise(teamID, playerID))).rounded()))
    }

    // One bidding tick: pick a bot willing to top the current bid — not
    // already leading, budget room, and private price at or above the raise.
    // Raises jump $1–$5 (capped by price and max) so contested lots resolve
    // in seconds rather than a $1-at-a-time crawl. Returns nil when every
    // bot is out and the lot should ride its clock.
    static func auctionBid(
        playerID: String,
        currentBid: Int,
        leaderTeamID: String,
        bots: [(teamID: String, maxBid: Int)],
        dollarValue: Int,
        rng: inout SystemRandomNumberGenerator
    ) -> (teamID: String, amount: Int)? {
        let willing = bots.filter { bot in
            guard bot.teamID != leaderTeamID, bot.maxBid > currentBid else { return false }
            return botPrice(teamID: bot.teamID, playerID: playerID, dollarValue: dollarValue) > currentBid
        }
        guard !willing.isEmpty else { return nil }
        let bot = willing[Int.random(in: 0..<willing.count, using: &rng)]
        let price = botPrice(teamID: bot.teamID, playerID: playerID, dollarValue: dollarValue)
        let jump = [1, 1, 2, 3, 5][Int.random(in: 0..<5, using: &rng)]
        let amount = min(currentBid + jump, price, bot.maxBid)
        guard amount > currentBid else { return nil }
        return (bot.teamID, amount)
    }

    // Nomination choice: one of the bot's top targets, with spread so every
    // bot doesn't nominate the same player. `available` is best-first.
    static func auctionNomination(
        available: [String],
        rng: inout SystemRandomNumberGenerator
    ) -> String? {
        guard !available.isEmpty else { return nil }
        let window = min(5, available.count)
        return available[Int.random(in: 0..<window, using: &rng)]
    }
}
